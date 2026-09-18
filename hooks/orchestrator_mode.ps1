#requires -Version 5.1
# PreToolUse: a once-per-session cost reminder, never a write veto.
# The 150-line counter is a heuristic, not a token estimate or automatic mode switch.
# Explicit .off wins over .on; workers and shell/read tools pass silently.
# Shared .reminded marker also deduplicates delegation_gate's PostToolUse reminder.
$Threshold = 150
try {
    $j = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace("$($j.agent_id)")) { exit 0 }
    if ("$($j.tool_name)" -notin @('Write', 'Edit', 'MultiEdit')) { exit 0 }
    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
    $safe = $sid -replace '[^A-Za-z0-9-]', '_'
    $dir = Join-Path $env:TEMP 'claude_orchestrator'
    if (Test-Path -LiteralPath (Join-Path $dir "$safe.off")) { exit 0 }
    $marker = Join-Path $dir "$safe.reminded"
    if (Test-Path -LiteralPath $marker) { exit 0 }
    $on = Test-Path -LiteralPath (Join-Path $dir "$safe.on")
    $count = 0
    $counter = Join-Path (Join-Path $env:TEMP 'claude_delegation_gate') "$safe.count"
    if (Test-Path -LiteralPath $counter) {
        [void][int]::TryParse((Get-Content -LiteralPath $counter -Raw).Trim(), [ref]$count)
    }
    if (-not $on -and $count -lt $Threshold) { exit 0 }
    [void][IO.Directory]::CreateDirectory($dir)
    # Atomic claim: concurrent hooks share one reminder budget.
    $claim = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $claim.Dispose()
    $msg = '[agent-ladder] Routing cost check: compare the remaining whole ask, then each bounded package, against total handoff cost (briefing, worker context, execution, review, integration, and rework). Keep small work inline; delegate only when total cost is lower, and reuse a suitable existing worker. Line counts are only a heuristic; orchestration preference never forbids inline edits.'
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 4
    exit 0
} catch { exit 0 }
