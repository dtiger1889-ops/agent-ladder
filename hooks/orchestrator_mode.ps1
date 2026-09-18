#requires -Version 5.1
# orchestrator_mode.ps1 -- PreToolUse (matcher Write|Edit|MultiEdit|Bash|PowerShell): when "orchestrator
# mode" is ON, refuse a code write from the MAIN session and redirect to a delegated worker.
# Motivation: HISTORY.md (2026-09-18 audit) -- sessions that opened with the phrase
# "orchestrate" still drifted back to writing code inline; a phrase alone isn't durable state.
# Per docs.claude.com/en/docs/claude-code/hooks, `agent_id` is present in the hook's stdin JSON ONLY
# when the call originates inside a subagent -- so its presence is how this hook tells "a worker is
# doing this" from "the main/orchestrating session is doing this" and exits 0 (never gates workers).
#
# ON/OFF state (spec agent-ladder-enforcement.md, package P4, decision D1 = option B):
#   ON  if %TEMP%\claude_orchestrator\<sid>.on exists (written by another hook when the owner says
#       "orchestrate" / runs the orchestrate skill; its content is the "HH:mm UTC" it was set), OR
#   ON  (auto) if the delegation-gate counter file for this session
#       (%TEMP%\claude_delegation_gate\<sid>.count) holds an integer >= 150 AND no
#       %TEMP%\claude_orchestrator\<sid>.off marker exists for this session -- in which case this
#       hook ALSO writes the .on flag (content: "auto, 150 inline code lines reached") so the state
#       is visible to the flag hook and future calls skip the counter re-check.
#   OFF otherwise.
#
# CONTRACT for orchestrate_flag.ps1 (owned by another worker): "go inline" / /orchestrate off must
# delete the .on flag file AND create the .off marker file
# (%TEMP%\claude_orchestrator\<sid>.off, any content) for that session_id. The .off marker is what
# stops the auto-on from immediately re-firing off the same counter value the next call -- it only
# re-engages if the counter keeps growing (the owner keeps writing inline) past 150 again; this hook does
# not delete .off itself, and does not re-check .off once .on exists.
#
# Session id is sanitized the same way as delegation_gate.ps1: [^A-Za-z0-9-] -> '_'.
# Escape hatch: say "go inline" (clears .on via orchestrate_flag.ps1) or run /orchestrate off.
# Fails open on any parse error or missing session_id.

$CodeExt = '\.(py|ts|tsx|js|jsx|mjs|cjs|ps1|psm1|sh|bash|cmd|bat|rs|go|java|kt|cs|c|cpp|h|hpp|rb|php|lua|sql|toml|yaml|yml|json|css|scss|html|svelte|vue)$'
$Threshold = 150

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'agent_id' -and -not [string]::IsNullOrWhiteSpace("$($j.agent_id)")) { exit 0 }

    $tool = "$($j.tool_name)"
    if ($tool -notin @('Write', 'Edit', 'MultiEdit', 'Bash', 'PowerShell')) { exit 0 }

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')

    $orchDir = Join-Path $env:TEMP 'claude_orchestrator'
    $onFile = Join-Path $orchDir "$safe.on"
    $offFile = Join-Path $orchDir "$safe.off"
    $gateDir = Join-Path $env:TEMP 'claude_delegation_gate'
    $counterFile = Join-Path $gateDir "$safe.count"

    $modeOn = $false
    $sinceText = ''

    if (Test-Path -LiteralPath $onFile) {
        $modeOn = $true
        $sinceText = (Get-Content -LiteralPath $onFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($sinceText)) { $sinceText = 'unknown time' }
    } elseif (-not (Test-Path -LiteralPath $offFile)) {
        $count = 0
        if (Test-Path -LiteralPath $counterFile) {
            $count = [int](Get-Content -LiteralPath $counterFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($count -ge $Threshold) {
            $modeOn = $true
            $sinceText = 'auto, 150 inline code lines reached'
            if (-not (Test-Path -LiteralPath $orchDir)) { New-Item -ItemType Directory -Path $orchDir -Force | Out-Null }
            Set-Content -LiteralPath $onFile -Value $sinceText -Encoding ASCII
        }
    }

    if (-not $modeOn) { exit 0 }

    $isCodeWrite = $false
    $head = ''

    if ($tool -in @('Write', 'Edit', 'MultiEdit')) {
        $fp = [string]$j.tool_input.file_path
        if (-not [string]::IsNullOrWhiteSpace($fp) -and $fp -match "(?i)$CodeExt") {
            $isCodeWrite = $true
            $head = $fp
        }
    } else {
        $cmd = [string]$j.tool_input.command
        if (-not [string]::IsNullOrWhiteSpace($cmd)) {
            $hasCodeTarget = $false
            foreach ($tok in ($cmd -split '\s+')) {
                $tok2 = $tok.Trim([char[]]@("'", '"'))
                if ($tok2 -match "(?i)$CodeExt") { $hasCodeTarget = $true; break }
            }
            if ($cmd -match '<<' -and $hasCodeTarget) { $isCodeWrite = $true }
            elseif ($cmd -match '(?i)\b(Set-Content|Out-File|Add-Content)\b' -and $hasCodeTarget) { $isCodeWrite = $true }
            elseif ($cmd -match '(>>?)' -and $hasCodeTarget) { $isCodeWrite = $true }
            elseif ($cmd -match '\bsed\s+-i\b') { $isCodeWrite = $true }
            elseif ($cmd -match '\bperl\s+-p?i\b') { $isCodeWrite = $true }
            elseif ($cmd -match '(?i)\bpython3?\s+-\s*<<' -and $hasCodeTarget) { $isCodeWrite = $true }

            if ($isCodeWrite) {
                $head = $cmd.Substring(0, [Math]::Min(60, $cmd.Length))
            }
        }
    }

    if (-not $isCodeWrite) { exit 0 }

    $target = if ($head) { $head } else { '(unknown)' }
    $msg = "[orchestrator] refused: mode ON since $sinceText and this is a code write from the main session ($target). " +
    "Hand it to a worker: Agent with model named (sonnet for mechanical, opus for anything that ships), brief = the exact change plus the acceptance command. " +
    "Small enough to skip? say 'go inline' first."
    [Console]::Error.WriteLine($msg)
    exit 2
} catch {
    exit 0
}
