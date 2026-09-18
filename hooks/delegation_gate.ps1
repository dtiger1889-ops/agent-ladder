#requires -Version 5.1
# PostToolUse (Write|Edit|MultiEdit, and Bash|PowerShell): the cost gate for delegation, made mechanical.
# the workspace instructions "Sub-agent & model routing": the trigger for handing work to a sub-agent is
# TOKEN WEIGHT ("would inline cost more than ~30-40k tokens?"), not the task noun. That rule was
# prose only; on 2026-09-02 a build session wrote a multi-thousand-line build inline
# until the owner said "offload segmented work to sub agents" (private lapse ledger row 27). This hook
# counts code lines the session has written and, ONCE, past the threshold, exits 2 with a reminder.
# It never blocks the edit that fired it. Fails open. Threshold: 600 lines of code across the session.
#
# Part A diagnosis (2026-09-18, package P5): the audit (HISTORY.md (2026-09-18 audit)
# section 3) found sessions the other audited session (3,084 lines) and that session (2,691 lines) with no firing recorded
# in their transcripts. Hand-run tests confirmed the hook itself is NOT the cause: a 700-line Write
# fires (exit 2, correct message) both with a plain JSON payload and with the exact Desktop-app shape
# (transcript_path under ~/.claude/projects, permission_mode "auto", tool_use_id, tool_response), and
# $env:TEMP resolves identically under MSYS bash and a Windows
# native powershell.exe -- ruling out a per-launcher TEMP split. One audited session's own on-disk state
# (%TEMP%\claude_delegation_gate\<session-id>.fired, created 2026-09-14 23:10;
# .count reached 5378 by 2026-09-16) proves the hook DID run to completion and DID exit 2 in that exact
# session -- so counting, extension matching, and MultiEdit shape were never broken there. But that
# session's transcript records zero hook_blocking_error entries mentioning
# "delegation-gate": its only 10 hook_blocking_error entries are all from skill_sync.ps1, which is
# registered ahead of delegation_gate.ps1 in the SAME settings.json PostToolUse "Write|Edit|MultiEdit"
# matcher array (order: skill_sync.ps1, checkpoint_finisher_guard.ps1, delegation_gate.ps1). The other audited session's
# transcript shows the same pattern one level up: its single hook_blocking_error entry is from
# checkpoint_finisher_guard.ps1 (2nd in the array), never delegation_gate.ps1 (3rd/last); The other audited session's own
# state files are gone because that session predates the hook's 7-day sweep window (jsonl dated 2026-09-07,
# more than 7 days before this diagnosis), not because the hook never fired. Best-evidenced conclusion:
# when more than one hook in that shared matcher array exits 2 on the same PostToolUse:Edit/Write call,
# the transcript keeps only one hook's blockingError message -- and delegation_gate, listed last, is the
# one that reliably loses that slot. The exact dedup rule inside the Claude Code hook runner was not
# directly observable from outside; this package does not edit settings.json/register_hooks.ps1 to
# reorder or split the matcher (out of scope per brief), so the loss condition remains live. Report this
# finding to the owner: reordering delegation_gate first in its matcher array, or moving it to its own
# matcher entry, is a plausible fix a future package should try.

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
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }
    $dir = Join-Path $env:TEMP 'claude_delegation_gate'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')
    $counter = Join-Path $dir "$safe.count"
    $fired = Join-Path $dir "$safe.fired"
    Get-ChildItem $dir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

    $total = 0
    if (Test-Path -LiteralPath $counter) { $total = [int](Get-Content -LiteralPath $counter -ErrorAction SilentlyContinue | Select-Object -First 1) }
    $total += $added
    Set-Content -LiteralPath $counter -Value $total -Encoding ASCII

    if ($total -lt $Threshold) { exit 0 }
    if (Test-Path -LiteralPath $fired) { exit 0 }
    New-Item -ItemType File -Path $fired -Force | Out-Null

    $msg = "[delegation-gate] This session has now written about $total lines of code inline (fires once; the edit went through -- do NOT retry it). " +
    'the workspace instructions cost gate: past ~30-40k tokens of inline work the remaining build goes to sub-agents -- ' +
    'Sonnet for mechanical/bulk, Opus/Fable for anything user-facing -- in isolated worktrees, with this session as orchestrator (seams, specs, contracts, review, merge). ' +
    'Owner, 2026-09-02: "offload segmented work to more efficient sub agents and act as an orchestrator." ' +
    'Continue inline ONLY if what is left is genuinely small; otherwise split the remaining work now and say so in the reply.'
    [Console]::Error.WriteLine($msg)
    exit 2
} catch {
    exit 0
}
