#requires -Version 5.1
# PostToolUse: fires ONCE per session on the first edit touching any CHECKPOINT.md, as an
# exit-2 reminder of the close contract (verify + finisher scripts). Never blocks the edit
# and does NOT auto-trigger /checkpoint (the maintainer's 2026-07-29 no-auto-trigger rule). Fails
# open. Record: agent-ladder/harness_tools/checkpoint.md.

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ("$($j.tool_name)" -notin @('Edit', 'Write', 'MultiEdit')) { exit 0 }
    $fp = [string]$j.tool_input.file_path
    if ([string]::IsNullOrWhiteSpace($fp)) { exit 0 }
    if ($fp -notmatch '(?i)[\\/]CHECKPOINT\.md$') { exit 0 }

    # once per session
    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }
    $flagDir = Join-Path $env:TEMP 'agent_ladder_checkpoint_guard'
    if (-not (Test-Path -LiteralPath $flagDir)) { New-Item -ItemType Directory -Path $flagDir | Out-Null }
    $flag = Join-Path $flagDir ($sid -replace '[^A-Za-z0-9-]', '_')
    if (Test-Path -LiteralPath $flag) { exit 0 }
    New-Item -ItemType File -Path $flag -Force | Out-Null

    # prune flags older than 7 days so the dir never grows unbounded
    Get-ChildItem $flagDir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

    $msg = '[checkpoint-guard] CHECKPOINT.md edited (fires once per session; the edit went through -- do NOT retry it). ' +
    'Close contract when this file is FINAL: (1) run verify_checkpoint_claims.ps1 -Checkpoint <path> until exit 0, ' +
    '(2) run finish-checkpoint.ps1 -Checkpoint <path> -- NEVER hand-type the Last updated: stamp and NEVER run separate UtcNow / line-count / byte-count calls. ' +
    'A close touching multiple projects runs BOTH scripts once per file. Scripts live in ~/.claude/skills/checkpoint/.'
    [Console]::Error.WriteLine($msg)
    exit 2
} catch {
    exit 0
}


