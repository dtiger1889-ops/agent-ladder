#requires -Version 5.1
# PostToolUse: count approximate main-session code output and offer a nonblocking cost reminder.
# 600 lines is a heuristic, not a token estimate. Shares .reminded with orchestrator_mode.
$Threshold = 600
$CodeExt = '\.(py|ts|tsx|js|jsx|mjs|cjs|ps1|psm1|sh|bash|cmd|bat|rs|go|java|kt|cs|c|cpp|h|hpp|rb|php|lua|sql|toml|yaml|yml|json|css|scss|html|svelte|vue)$'
$ScratchRe = '(?i)AppData\\Local\\Temp\\claude|msys64[\\/]tmp[\\/]claude'

function Get-Weight([string]$path) {
    if ($path -match '(?i)[\\/](tests?|fixtures?)[\\/]') { return 0.5 }
    if ($path -match $ScratchRe) { return 0.5 }
    return 1.0
}

function Count-Lines([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return 0 }
    return ($text -split "`n").Count
}

# Extracts (path, bodyLineCount) pairs from a Bash/PowerShell command string: heredocs
# (<<'EOF' / <<EOF / <<-EOF, bash- or `python - <<`-style), plus a light Set-Content /
# Out-File / Add-Content / here-string scan. Returns an array of hashtables.
function Get-ShellWriteTargets([string]$cmd) {
    $results = @()
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $results }
    $lines = $cmd -split "`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $m = [regex]::Match($line, "<<-?\s*['`"]?([A-Za-z_][A-Za-z0-9_]*)['`"]?")
        if (-not $m.Success) { continue }
        $term = $m.Groups[1].Value

        # redirect target: prefer a '> path' on the same line, outside the heredoc operator itself
        $target = $null
        $rm = [regex]::Match($line, '>\s*([^\s<>|;]+)')
        if ($rm.Success) { $target = $rm.Groups[1].Value.Trim('"', "'") }

        # collect body up to the terminator line
        $bodyLines = New-Object System.Collections.Generic.List[string]
        $j = $i + 1
        while ($j -lt $lines.Count -and $lines[$j].Trim() -ne $term) {
            $bodyLines.Add($lines[$j])
            $j++
        }
        $body = ($bodyLines -join "`n")

        if (-not $target) {
            # python -c / python - <<PY style: look for an open(...,'w'...) target inside the body
            $pm = [regex]::Match($body, "open\(\s*['`"]([^'`"]+)['`"]\s*,\s*['`"]w")
            if ($pm.Success) { $target = $pm.Groups[1].Value }
        }

        if ($target) {
            $results += @{ path = $target; lines = $bodyLines.Count }
        }
        $i = $j
    }

    # Set-Content / Out-File / Add-Content with a -Value string body (best-effort, single-line or here-string)
    foreach ($cm in [regex]::Matches($cmd, '(?is)(Set-Content|Out-File|Add-Content)\b.*?-(?:Literal)?Path\s+["'']?([^"''\s]+)["'']?.*?-Value\s+(?:@[''"](.*?)[''"]@|["''](.*?)["''])')) {
        $target = $cm.Groups[2].Value
        $valText = if ($cm.Groups[3].Success -and $cm.Groups[3].Value) { $cm.Groups[3].Value } else { $cm.Groups[4].Value }
        if ($target -and $valText) {
            $results += @{ path = $target; lines = (Count-Lines $valText) }
        }
    }

    return $results
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace("$($j.agent_id)")) { exit 0 }
    $tool = "$($j.tool_name)"
    if ($tool -notin @('Edit', 'Write', 'MultiEdit', 'Bash', 'PowerShell')) { exit 0 }

    $added = 0

    if ($tool -in @('Edit', 'Write', 'MultiEdit')) {
        $fp = [string]$j.tool_input.file_path
        if ([string]::IsNullOrWhiteSpace($fp)) { exit 0 }
        if ($fp -notmatch "(?i)$CodeExt") { exit 0 }
        $weight = Get-Weight $fp

        if ($tool -eq 'Write') {
            $text = [string]$j.tool_input.content
            if ($text) { $added = Count-Lines $text }
        } elseif ($tool -eq 'Edit') {
            $text = [string]$j.tool_input.new_string
            if ($text) { $added = Count-Lines $text }
        } else {
            foreach ($e in @($j.tool_input.edits)) {
                $text = [string]$e.new_string
                if ($text) { $added += Count-Lines $text }
            }
        }
        if ($added -le 0) { exit 0 }
        $added = [int]([math]::Ceiling($added * $weight))
    } else {
        $cmd = [string]$j.tool_input.command
        if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }
        $targets = Get-ShellWriteTargets $cmd
        $total = 0
        foreach ($t in $targets) {
            $p = [string]$t.path
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($p -notmatch "(?i)$CodeExt") { continue }
            $w = Get-Weight $p
            $total += [math]::Ceiling($t.lines * $w)
        }
        if ($total -le 0) { exit 0 }
        $added = $total
    }

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
    $dir = Join-Path $env:TEMP 'claude_delegation_gate'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')
    $counter = Join-Path $dir "$safe.count"
    $orchDir = Join-Path $env:TEMP 'claude_orchestrator'
    $fired = Join-Path $orchDir "$safe.reminded"
    Get-ChildItem $dir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

    $total = 0
    if (Test-Path -LiteralPath $counter) { $total = [int](Get-Content -LiteralPath $counter -ErrorAction SilentlyContinue | Select-Object -First 1) }
    $total += $added
    Set-Content -LiteralPath $counter -Value $total -Encoding ASCII

    if ($total -lt $Threshold) { exit 0 }
    if (Test-Path -LiteralPath (Join-Path $orchDir "$safe.off")) { exit 0 }
    if (Test-Path -LiteralPath $fired) { exit 0 }
    [void][IO.Directory]::CreateDirectory($orchDir)
    $claim = [IO.File]::Open($fired, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $claim.Dispose()
    $msg = "[agent-ladder] About $total weighted code lines recorded inline; this is a heuristic, not a token estimate. Compare the remaining whole ask, then each bounded package, against total handoff cost (briefing, worker context, execution, review, integration, and rework). Keep small work inline; delegate only when total cost is lower, and reuse a suitable existing worker. The completed tool call succeeded; do not retry it."
    @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 4
    exit 0
} catch { exit 0 }
