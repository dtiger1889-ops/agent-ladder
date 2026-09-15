#requires -Version 5.1
# PostToolUse (Write|Edit|MultiEdit): the cost gate for delegation, made mechanical.
# the project policy "Sub-agent & model routing": the trigger for handing work to a sub-agent is
# TOKEN WEIGHT ("would inline cost more than ~30-40k tokens?"), not the task noun. That rule was
# prose only; on 2026-09-02 a project_pantheon session wrote a multi-thousand-line build inline
# until the owner said "offload segmented work to sub agents" (harness_rule_lapses n=27). This hook
# counts code lines the session has written and, ONCE, past the threshold, exits 2 with a reminder.
# It never blocks the edit that fired it. Fails open. Threshold: 600 lines of code across the session.

$Threshold = 600
$CodeExt = '\.(py|ts|tsx|js|jsx|mjs|cjs|ps1|psm1|sh|bash|cmd|bat|rs|go|java|kt|cs|c|cpp|h|hpp|rb|php|lua|sql|toml|yaml|yml|json|css|scss|html|svelte|vue)$'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $tool = "$($j.tool_name)"
    if ($tool -notin @('Edit', 'Write', 'MultiEdit')) { exit 0 }
    $fp = [string]$j.tool_input.file_path
    if ([string]::IsNullOrWhiteSpace($fp)) { exit 0 }
    if ($fp -notmatch "(?i)$CodeExt") { exit 0 }
    if ($fp -match '(?i)[\\/](tests?|fixtures?)[\\/]') { $weight = 0.5 } else { $weight = 1.0 }

    $added = 0
    if ($tool -eq 'Write') {
        $text = [string]$j.tool_input.content
        if ($text) { $added = ($text -split "`n").Count }
    } elseif ($tool -eq 'Edit') {
        $text = [string]$j.tool_input.new_string
        if ($text) { $added = ($text -split "`n").Count }
    } else {
        foreach ($e in @($j.tool_input.edits)) {
            $text = [string]$e.new_string
            if ($text) { $added += ($text -split "`n").Count }
        }
    }
    if ($added -le 0) { exit 0 }
    $added = [int]([math]::Ceiling($added * $weight))

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }
    $dir = Join-Path $env:TEMP 'agent_ladder_delegation_gate'
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
    'the project policy cost gate: past ~30-40k tokens of inline work the remaining build goes to sub-agents -- ' +
    'Sonnet for mechanical/bulk, Opus/Fable for anything user-facing -- in isolated worktrees, with this session as orchestrator (seams, specs, contracts, review, merge). ' +
    'the maintainer: "offload segmented work to more efficient sub agents and act as an orchestrator." ' +
    'Continue inline ONLY if what is left is genuinely small; otherwise split the remaining work now and say so in the reply.'
    [Console]::Error.WriteLine($msg)
    exit 2
} catch {
    exit 0
}


