# Wrapper tests for ~/.claude/hooks/orchestrator_mode.ps1 -- runs the hook exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File orchestrator_mode_tests.ps1
$hook = Join-Path $PSScriptRoot '..\hooks\orchestrator_mode.ps1'
$tmp = $env:TEMP
$orchDir = Join-Path $tmp 'claude_orchestrator'
$gateDir = Join-Path $tmp 'claude_delegation_gate'
if (-not (Test-Path $orchDir)) { New-Item -ItemType Directory -Path $orchDir -Force | Out-Null }
if (-not (Test-Path $gateDir)) { New-Item -ItemType Directory -Path $gateDir -Force | Out-Null }

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

function NewSid([string]$tag) { return "omtest-$tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8) }
function Safe([string]$sid) { return ($sid -replace '[^A-Za-z0-9-]', '_') }

function WriteJson([string]$fp, [string]$s, [string]$agentId = $null) {
    $h = [ordered]@{ hook_event_name = 'PreToolUse'; tool_name = 'Write'; session_id = $s; tool_input = @{ file_path = $fp; content = "x" } }
    if ($agentId) { $h.agent_id = $agentId }
    return ($h | ConvertTo-Json -Compress -Depth 6)
}
function EditJson([string]$fp, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Edit'; session_id = $s; tool_input = @{ file_path = $fp; old_string = 'a'; new_string = 'b' } } | ConvertTo-Json -Compress)
}
function BashJson([string]$cmd, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; session_id = $s; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress)
}
function PsJson([string]$cmd, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'; session_id = $s; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress)
}

function Set-OrchOn([string]$s) { Set-Content -LiteralPath (Join-Path $orchDir "$(Safe $s).on") -Value '12:00 UTC' -Encoding ASCII }
function Set-OrchOff([string]$s) { Set-Content -LiteralPath (Join-Path $orchDir "$(Safe $s).off") -Value '1' -Encoding ASCII }
function Set-Counter([string]$s, [int]$n) { Set-Content -LiteralPath (Join-Path $gateDir "$(Safe $s).count") -Value $n -Encoding ASCII }

$script:cleanupSids = New-Object System.Collections.Generic.List[string]
function Track([string]$s) { $script:cleanupSids.Add($s) }

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}

# 1. flag off, code Write -> 0
$s1 = NewSid '1'; Track $s1
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s1)
Check '1 flag off code Write passes' ($r.code -eq 0) "code=$($r.code)"

# 2. flag on, code Write -> 2
$s2 = NewSid '2'; Track $s2; Set-OrchOn $s2
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s2)
Check '2 flag on code Write refused' ($r.code -eq 2 -and $r.err -match '\[orchestrator\] refused') "code=$($r.code) err=$($r.err)"

# 3. flag on, .md Edit -> 0
$s3 = NewSid '3'; Track $s3; Set-OrchOn $s3
$r = Invoke-Hook (EditJson 'C:\proj\notes.md' $s3)
Check '3 flag on md Edit passes' ($r.code -eq 0) "code=$($r.code)"

# 4. flag on, CHECKPOINT.md Edit -> 0
$s4 = NewSid '4'; Track $s4; Set-OrchOn $s4
$r = Invoke-Hook (EditJson 'C:\proj\CHECKPOINT.md' $s4)
Check '4 flag on CHECKPOINT.md Edit passes' ($r.code -eq 0) "code=$($r.code)"

# 5. flag on, agent_id present, code Write -> 0
$s5 = NewSid '5'; Track $s5; Set-OrchOn $s5
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s5 'agent-xyz')
Check '5 flag on with agent_id passes' ($r.code -eq 0) "code=$($r.code)"

# 6. flag on, Bash heredoc to .py -> 2
$s6 = NewSid '6'; Track $s6; Set-OrchOn $s6
$r = Invoke-Hook (BashJson "cat <<'EOF' > foo.py`nprint(1)`nEOF" $s6)
Check '6 flag on Bash heredoc to py refused' ($r.code -eq 2) "code=$($r.code)"

# 7. flag on, Bash git status -> 0
$s7 = NewSid '7'; Track $s7; Set-OrchOn $s7
$r = Invoke-Hook (BashJson 'git status' $s7)
Check '7 flag on git status passes' ($r.code -eq 0) "code=$($r.code)"

# 8. flag on, sed -i -> 2
$s8 = NewSid '8'; Track $s8; Set-OrchOn $s8
$r = Invoke-Hook (BashJson "sed -i 's/a/b/' foo.py" $s8)
Check '8 flag on sed -i refused' ($r.code -eq 2) "code=$($r.code)"

# 9. flag on, PowerShell Set-Content x.ps1 -> 2
$s9 = NewSid '9'; Track $s9; Set-OrchOn $s9
$r = Invoke-Hook (PsJson "Set-Content -LiteralPath x.ps1 -Value 'x'" $s9)
Check '9 flag on Set-Content ps1 refused' ($r.code -eq 2) "code=$($r.code)"

# 10. malformed -> 0
$r = Invoke-Hook 'not json at all'
Check '10 malformed stdin passes' ($r.code -eq 0) "code=$($r.code)"

# 11. counter file 150, no flag -> code Write refused and .on created
$s11 = NewSid '11'; Track $s11; Set-Counter $s11 150
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s11)
$onPath11 = Join-Path $orchDir "$(Safe $s11).on"
Check '11 counter 150 no flag refuses and creates .on' ($r.code -eq 2 -and (Test-Path -LiteralPath $onPath11)) "code=$($r.code) onExists=$(Test-Path -LiteralPath $onPath11)"

# 12. counter 149, no flag -> passes
$s12 = NewSid '12'; Track $s12; Set-Counter $s12 149
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s12)
Check '12 counter 149 no flag passes' ($r.code -eq 0) "code=$($r.code)"

# 13. counter 150, .off marker present -> passes
$s13 = NewSid '13'; Track $s13; Set-Counter $s13 150; Set-OrchOff $s13
$r = Invoke-Hook (WriteJson 'C:\proj\foo.py' $s13)
Check '13 counter 150 with off marker passes' ($r.code -eq 0) "code=$($r.code)"

Write-Output "---- $pass passed, $fail failed ----"

foreach ($s in $cleanupSids) {
    $sfe = Safe $s
    Remove-Item -LiteralPath (Join-Path $orchDir "$sfe.on") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $orchDir "$sfe.off") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $gateDir "$sfe.count") -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 } else { exit 0 }
