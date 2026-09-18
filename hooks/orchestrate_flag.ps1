#requires -Version 5.1
# orchestrate_flag.ps1 -- UserPromptSubmit hook. Sets/clears a per-session orchestrator-mode flag
# and, on every real prompt, prints a one-line delegation reminder ending in the mode state.
# Spec: HISTORY.md (2026-09-18 section), packages P2 and P3.
# Tests: tests/orchestrate_flag_tests.ps1.
#
# Per-prompt re-injection pattern: Jerry0022/dotclaude PR 379
# (https://github.com/Jerry0022/dotclaude/pull/379) -- a UserPromptSubmit hook re-injecting a
# delegation-policy reminder. Motivation: HISTORY.md (2026-09-18 audit)
# (the owner picked D2 = A on 2026-09-18: the reminder prints on every real prompt, not gated).
#
# State: %TEMP%\claude_orchestrator\<session_id sanitized>.on, content = UTC HH:mm the mode was
# set ON. Presence of the file = mode ON. 7-day sweep, same pattern as rigor.ps1.
#
# ON/OFF words -- OFF wins when both match in the same prompt.
# Harness turns (task-notification, Stop hook feedback, Goal check-in, system-reminder,
# agent-message) are ignored entirely -- reuses rigor.ps1's exclusion, widened for the extra forms.
# Fails open on any parse error.

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ("$($j.hook_event_name)" -ne 'UserPromptSubmit') { exit 0 }

    $prompt = "$($j.prompt)"
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

    # Harness-generated turns are not the owner -- same exclusion rigor.ps1 uses (its line 50),
    # widened for Stop-hook feedback, Goal check-ins, and agent-to-agent messages.
    $t = $prompt.Trim()
    if ($t -match '^(<system-reminder>|<task-notification>|\[SYSTEM NOTIFICATION|<local-command|<command-name>|<agent-message|Stop hook feedback|Goal check-in)') { exit 0 }
    if ($t -match '<task-notification>|<agent-message>|Stop hook feedback|Goal check-in') { exit 0 }

    $p = $prompt.ToLower()

    $onRegex = '\borchestrat|\bdelegate (the|this|it|work|out)|\bact as an? orchestrator|^/orchestrate( on)?\b|\bfarm (it|this|the .*) out\b'
    $offRegex = '\bstop orchestrating|\bdo it yourself|\bgo inline|\bwork inline|^/orchestrate off\b'

    $onMatch = $p -match $onRegex
    $offMatch = $p -match $offRegex

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }
    $dir = Join-Path $env:TEMP 'claude_orchestrator'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')
    $flag = Join-Path $dir "$safe.on"
    # .off marker: orchestrator_mode.ps1 auto-engages the mode when the delegation-gate counter is
    # >= 150 unless this marker exists, so "go inline" must leave one behind or the next tool call
    # would undo it. ON clears the marker again. (Contract documented in orchestrator_mode.ps1.)
    $offMarker = Join-Path $dir "$safe.off"
    $existed = Test-Path -LiteralPath $flag

    # OFF wins when both match.
    if ($offMatch) {
        Set-Content -LiteralPath $offMarker -Value ((Get-Date).ToUniversalTime().ToString('HH:mm')) -NoNewline
        if ($existed) {
            Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
            Write-Output '[orchestrator] mode OFF.'
        }
    }
    elseif ($onMatch) {
        Remove-Item -LiteralPath $offMarker -Force -ErrorAction SilentlyContinue
        if (-not $existed) {
            $nowUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
            Set-Content -LiteralPath $flag -Value $nowUtc -NoNewline
            Write-Output "[orchestrator] mode ON since $nowUtc UTC: main session writes docs and CHECKPOINT only; every code change goes to a named-model worker."
        }
    }

    # Per-prompt delegation reminder (P3) -- every real prompt, skipped for subagent turns.
    $agentId = "$($j.agent_id)"
    if ([string]::IsNullOrWhiteSpace($agentId)) {
        $modeState = 'OFF'
        if (Test-Path -LiteralPath $flag) {
            $setAt = Get-Content -LiteralPath $flag -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($setAt)) { $modeState = "ON since $($setAt.Trim())" }
        }
        Write-Output "[delegation] cost gate applies to the whole ask, not the next step: build-shaped work (a spec, a list, a phase) goes to named-model workers; small fixes stay inline. Mode: $modeState."
    }

    exit 0
}
catch {
    exit 0
}
