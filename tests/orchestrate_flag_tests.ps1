# Wrapper tests for ~/.claude/hooks/orchestrate_flag.ps1 -- runs the hook exactly as Claude Code
# does (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks
# exit code + stdout. P2 cases (mode on/off) plus P3 cases (per-prompt delegation reminder).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File orchestrate_flag_tests.ps1
$hook = Join-Path $PSScriptRoot '..\hooks\orchestrate_flag.ps1'
$dir  = Join-Path $env:TEMP 'claude_orchestrator'

function Invoke-Hook([string]$json) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out; err = $err }
}
function Prompt-Json([string]$prompt, [string]$s, [string]$event = 'UserPromptSubmit', [string]$agentId = $null) {
    $o = @{ hook_event_name = $event; session_id = $s; cwd = 'C:\path\to\repo'; prompt = $prompt }
    if ($agentId) { $o.agent_id = $agentId }
    return ($o | ConvertTo-Json -Compress)
}
function Flag-Path([string]$s) {
    $safe = ($s -replace '[^A-Za-z0-9-]', '_')
    return (Join-Path $dir "$safe.on")
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}

$testFlags = New-Object System.Collections.Generic.List[string]

# ---- P2: mode on/off (8 cases) ---------------------------------------------

# 1. "orchestrate mechanical work" -> flag exists, stdout has ON
$s1 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s1)
$r = Invoke-Hook (Prompt-Json 'orchestrate mechanical work for me' $s1)
Check '1 orchestrate phrase sets flag and prints ON' ($r.code -eq 0 -and $r.out -match '\[orchestrator\] mode ON' -and (Test-Path (Flag-Path $s1))) "code=$($r.code) out=$($r.out)"

# 2. "stop orchestrating" -> flag gone (start from an ON session)
$s2 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s2)
Invoke-Hook (Prompt-Json 'orchestrate the rest of this build' $s2) | Out-Null
$r = Invoke-Hook (Prompt-Json 'stop orchestrating' $s2)
Check '2 stop orchestrating clears flag' ($r.code -eq 0 -and $r.out -match '\[orchestrator\] mode OFF' -and -not (Test-Path (Flag-Path $s2))) "code=$($r.code) out=$($r.out) exists=$(Test-Path (Flag-Path $s2))"

# 3. both ON and OFF phrases in one prompt -> OFF wins
$s3 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s3)
Invoke-Hook (Prompt-Json 'orchestrate this' $s3) | Out-Null
$r = Invoke-Hook (Prompt-Json 'orchestrate this but actually stop orchestrating and go inline' $s3)
Check '3 OFF wins when both match' ($r.code -eq 0 -and $r.out -match '\[orchestrator\] mode OFF' -and -not (Test-Path (Flag-Path $s3))) "code=$($r.code) out=$($r.out)"

# 4. neither phrase -> flag unchanged, no ON/OFF line (starting from OFF)
$s4 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s4)
$r = Invoke-Hook (Prompt-Json 'what time is my appointment tomorrow' $s4)
Check '4 neutral prompt does not set/clear flag' ($r.code -eq 0 -and $r.out -notmatch '\[orchestrator\] mode' -and -not (Test-Path (Flag-Path $s4))) "code=$($r.code) out=$($r.out)"

# 5. /orchestrate on
$s5 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s5)
$r = Invoke-Hook (Prompt-Json '/orchestrate on' $s5)
Check '5 slash orchestrate on sets flag' ($r.code -eq 0 -and $r.out -match '\[orchestrator\] mode ON' -and (Test-Path (Flag-Path $s5))) "code=$($r.code) out=$($r.out)"

# 6. /orchestrate off
$s6 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s6)
Invoke-Hook (Prompt-Json '/orchestrate on' $s6) | Out-Null
$r = Invoke-Hook (Prompt-Json '/orchestrate off' $s6)
Check '6 slash orchestrate off clears flag' ($r.code -eq 0 -and $r.out -match '\[orchestrator\] mode OFF' -and -not (Test-Path (Flag-Path $s6))) "code=$($r.code) out=$($r.out)"

# 7. a <task-notification> harness turn -> ignored entirely (even with orchestrate text inside)
$s7 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s7)
$r = Invoke-Hook (Prompt-Json "<task-notification>`norchestrate the rest`n</task-notification>" $s7)
Check '7 task-notification turn ignored' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out) -and -not (Test-Path (Flag-Path $s7))) "code=$($r.code) out=$($r.out)"

# 8. malformed JSON -> exit 0, silent
$r = Invoke-Hook 'this is not json {{{'
Check '8 malformed json fails open' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "code=$($r.code) out=$($r.out)"

# ---- P3: per-prompt delegation reminder ------------------------------------

# 9. reminder present on a plain prompt (main session, mode OFF)
$s9 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s9)
$r = Invoke-Hook (Prompt-Json 'help me plan tomorrow' $s9)
Check '9 reminder present on plain prompt' ($r.code -eq 0 -and $r.out -match '\[delegation\].*Mode: OFF\.') "out=$($r.out)"

# 10. reminder present and reflects ON state with the set time
$s10 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s10)
Invoke-Hook (Prompt-Json 'orchestrate the build' $s10) | Out-Null
$r = Invoke-Hook (Prompt-Json 'continue with the next step' $s10)
Check '10 reminder reflects ON state' ($r.code -eq 0 -and $r.out -match '\[delegation\].*Mode: ON since \d{2}:\d{2}\.') "out=$($r.out)"

# 11. reminder absent when agent_id is set (a subagent/worker turn)
$s11 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s11)
$r = Invoke-Hook (Prompt-Json 'do the assigned worker task' $s11 'UserPromptSubmit' 'worker-123')
Check '11 reminder absent when agent_id present' ($r.code -eq 0 -and $r.out -notmatch '\[delegation\]') "out=$($r.out)"

# 12. reminder absent on a task-notification turn (already covered by case 7's silence, re-asserted for P3)
$s12 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s12)
$r = Invoke-Hook (Prompt-Json "<task-notification>`nworker finished`n</task-notification>" $s12)
Check '12 reminder absent on task-notification turn' ($r.code -eq 0 -and $r.out -notmatch '\[delegation\]') "out=$($r.out)"

# ---- .off marker contract (orchestrator_mode.ps1 auto-on at 150 lines respects it) ----
function Off-Path([string]$s) { $safe = ($s -replace '[^A-Za-z0-9-]', '_'); return (Join-Path $dir "$safe.off") }

# 13. OFF removes .on and creates .off
$s13 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s13)
Invoke-Hook (Prompt-Json 'orchestrate the rest' $s13) | Out-Null
$r = Invoke-Hook (Prompt-Json 'go inline' $s13)
Check '13 OFF creates .off marker and removes .on' ($r.code -eq 0 -and (Test-Path (Off-Path $s13)) -and -not (Test-Path (Flag-Path $s13))) "code=$($r.code) off=$(Test-Path (Off-Path $s13)) on=$(Test-Path (Flag-Path $s13))"

# 14. ON removes an existing .off marker
$s14 = 'orchtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testFlags.Add($s14)
Invoke-Hook (Prompt-Json 'go inline' $s14) | Out-Null
$r = Invoke-Hook (Prompt-Json '/orchestrate on' $s14)
Check '14 ON removes .off marker' ($r.code -eq 0 -and -not (Test-Path (Off-Path $s14)) -and (Test-Path (Flag-Path $s14))) "code=$($r.code) off=$(Test-Path (Off-Path $s14)) on=$(Test-Path (Flag-Path $s14))"

Write-Output "---- $pass passed, $fail failed ----"

foreach ($s in $testFlags) {
    Remove-Item -LiteralPath (Flag-Path $s) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Off-Path $s) -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 } else { exit 0 }
