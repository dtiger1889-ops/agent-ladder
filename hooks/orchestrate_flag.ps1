#requires -Version 5.1
# UserPromptSubmit: explicit routing preference and a short cost reminder on each real prompt.
# State: %TEMP%\claude_orchestrator\<sanitized session>.on / .off.
# OFF persists until an explicit ON; neither code volume nor ordinary discussion changes it.
# This hook never blocks work or requires every code edit to be delegated.
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ("$($j.hook_event_name)" -ne 'UserPromptSubmit') { exit 0 }
    # Workers must not create directories, sweep state, or change the owner's preference.
    if (-not [string]::IsNullOrWhiteSpace("$($j.agent_id)")) { exit 0 }
    $t = ("$($j.prompt)").Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { exit 0 }
    if ($t -match '^(<system-reminder>|<task-notification>|\[SYSTEM NOTIFICATION|<local-command|<command-name>|<agent-message|Stop hook feedback|Goal check-in)') { exit 0 }
    if ($t -match '<task-notification>|<agent-message>|Stop hook feedback|Goal check-in') { exit 0 }

    # Match the entire utterance. Do not infer intent from quoted text, questions,
    # negations, embedded commands, or incidental mentions of orchestration.
    # A prompt that STARTS with /orchestrate is always an explicit command: bare or "on" = ON,
    # "off"/"status" = those, and ANY other remainder = ON plus that remainder is the task to
    # delegate. (2026-09-21: "/orchestrate work through the roadmap..." was reported OFF and the
    # session worked inline; the owner had called the skill precisely to get delegation.)
    $intent = ''
    $task = ''
    if ($t -match '(?s)\A/orchestrate(?:\s+(.*))?\z') {
        $rest = "$($Matches[1])".Trim()
        if ($rest -match '\A(on|off|status)[?.!]*\z') { $intent = $Matches[1] }
        elseif (-not $rest) { $intent = 'on' }
        else { $intent = 'on'; $task = $rest }
    }
    elseif ($t -match '\A(?:orchestrate (?:this|the work)|delegate (?:this|the work))\.?\z') { $intent = 'on' }
    elseif ($t -match '\A(?:go inline|work inline|stop orchestrating|do it yourself)\.?\z') { $intent = 'off' }

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')
    $dir = Join-Path $env:TEMP 'claude_orchestrator'
    $flag = Join-Path $dir "$safe.on"
    $offMarker = Join-Path $dir "$safe.off"
    # No age sweep: an explicit OFF must survive until its owner changes it.
    if ($intent -eq 'on' -or $intent -eq 'off') {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $nowUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
        if ($intent -eq 'off') {
            Set-Content -LiteralPath $offMarker -Value $nowUtc -NoNewline
            Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
            Write-Output '[orchestrator] routing preference OFF; choose inline or delegated work by total remaining cost.'
        }
        else {
            Remove-Item -LiteralPath $offMarker -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $flag)) { Set-Content -LiteralPath $flag -Value $nowUtc -NoNewline }
            if ($task) { Write-Output '[orchestrator] routing preference ON; the text after /orchestrate IS the task: brief it into bounded packages and spawn named-model workers now; only tightly coupled slivers stay inline.' }
            else { Write-Output '[orchestrator] routing preference ON; consider named-model workers when the handoff pays for itself; small work stays inline.' }
        }
    }

    $modeState = 'OFF'
    if ((Test-Path -LiteralPath $flag) -and -not (Test-Path -LiteralPath $offMarker)) { $modeState = 'ON' }
    if ($intent -eq 'status') { Write-Output "[orchestrator] routing preference $modeState." }
    Write-Output "[delegation] Compare inline effort for the remaining whole ask AND each package against total worker startup/context + brief + execution + review/integration + rework; small work stays inline. Reuse a suitable worker; name its model. Routing preference: $modeState."
    exit 0
}
catch { exit 0 }
