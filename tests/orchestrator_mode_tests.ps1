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
function EditJson([string]$fp, [string]$s, [string]$ns = 'b') {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Edit'; session_id = $s; tool_input = @{ file_path = $fp; old_string = 'a'; new_string = $ns } } | ConvertTo-Json -Compress)
}
function MultiEditJson([string]$fp, [string]$s, [string[]]$newStrings) {
    $edits = @($newStrings | ForEach-Object { @{ old_string = 'a'; new_string = $_ } })
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'MultiEdit'; session_id = $s; tool_input = @{ file_path = $fp; edits = $edits } } | ConvertTo-Json -Compress -Depth 6)
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

function Lines([int]$n) { return (1..$n | ForEach-Object { "l$_" }) -join "`n" }

# 14. flag on, Edit on .py with 40-line new_string -> 0 (small-edit allowance boundary)
$s14 = NewSid '14'; Track $s14; Set-OrchOn $s14
$r = Invoke-Hook (EditJson 'C:\proj\foo.py' $s14 (Lines 40))
Check '14 flag on Edit py 40-line new_string passes' ($r.code -eq 0) "code=$($r.code)"

# 15. flag on, Edit on .py with 41-line new_string -> 2 (too big for allowance)
$s15 = NewSid '15'; Track $s15; Set-OrchOn $s15
$r = Invoke-Hook (EditJson 'C:\proj\foo.py' $s15 (Lines 41))
Check '15 flag on Edit py 41-line new_string refused' ($r.code -eq 2) "code=$($r.code)"

# 16. flag on, Edit on .py with empty new_string (deletion) -> 0
$s16 = NewSid '16'; Track $s16; Set-OrchOn $s16
$r = Invoke-Hook (EditJson 'C:\proj\foo.py' $s16 '')
Check '16 flag on Edit py deletion passes' ($r.code -eq 0) "code=$($r.code)"

# 17. flag on, MultiEdit on .py with two edits summing to 40 lines -> 0; summing to 41 -> 2
$s17 = NewSid '17'; Track $s17; Set-OrchOn $s17
$r = Invoke-Hook (MultiEditJson 'C:\proj\foo.py' $s17 @((Lines 20), (Lines 20)))
Check '17a flag on MultiEdit py two edits summing 40 lines passes' ($r.code -eq 0) "code=$($r.code)"
$r = Invoke-Hook (MultiEditJson 'C:\proj\foo.py' $s17 @((Lines 20), (Lines 21)))
Check '17b flag on MultiEdit py two edits summing 41 lines refused' ($r.code -eq 2) "code=$($r.code)"

# 18. flag on, & running a .ps1 script (not writing it) -> 0
$s18 = NewSid '18'; Track $s18; Set-OrchOn $s18
$r = Invoke-Hook (BashJson '& "C:\x\skill-sync.ps1"' $s18)
Check '18 flag on running ps1 script passes' ($r.code -eq 0) "code=$($r.code)"

# 19. flag on, powershell -File running a test script -> 0
$s19 = NewSid '19'; Track $s19; Set-OrchOn $s19
$r = Invoke-Hook (BashJson 'powershell -NoProfile -File tests\foo_tests.ps1' $s19)
Check '19 flag on powershell -File passes' ($r.code -eq 0) "code=$($r.code)"

# 20. flag on, git add/commit naming a code file -> 0
$s20 = NewSid '20'; Track $s20; Set-OrchOn $s20
$r = Invoke-Hook (BashJson 'git add hooks/a.ps1 && git commit -m x' $s20)
Check '20 flag on git add/commit code file passes' ($r.code -eq 0) "code=$($r.code)"

# 21. flag on, grep -c on a code file -> 0
$s21 = NewSid '21'; Track $s21; Set-OrchOn $s21
$r = Invoke-Hook (BashJson 'grep -c "abc" hooks/a.ps1' $s21)
Check '21 flag on grep -c code file passes' ($r.code -eq 0) "code=$($r.code)"

# 22. flag on, running a .py script with args -> 0
$s22 = NewSid '22'; Track $s22; Set-OrchOn $s22
$r = Invoke-Hook (BashJson 'python scan.py --certify repo' $s22)
Check '22 flag on python scan.py run passes' ($r.code -eq 0) "code=$($r.code)"

# 23. flag on, echo redirect to .py -> 2
$s23 = NewSid '23'; Track $s23; Set-OrchOn $s23
$r = Invoke-Hook (BashJson 'echo x > out.py' $s23)
Check '23 flag on echo redirect to py refused' ($r.code -eq 2) "code=$($r.code)"

# 24. flag on, heredoc redirected to .py (multi-line) -> 2
$s24 = NewSid '24'; Track $s24; Set-OrchOn $s24
$r = Invoke-Hook (BashJson "cat <<'EOF' > gen.py`nprint(1)`nEOF" $s24)
Check '24 flag on heredoc redirect to py refused' ($r.code -eq 2) "code=$($r.code)"

# 25. flag on, Set-Content -LiteralPath a.ps1 -> 2
$s25 = NewSid '25'; Track $s25; Set-OrchOn $s25
$r = Invoke-Hook (PsJson 'Set-Content -LiteralPath a.ps1 -Value x' $s25)
Check '25 flag on Set-Content -LiteralPath ps1 refused' ($r.code -eq 2) "code=$($r.code)"

# 26. flag on, sed -i on a .py target -> 2
$s26 = NewSid '26'; Track $s26; Set-OrchOn $s26
$r = Invoke-Hook (BashJson "sed -i 's/a/b/' a.py" $s26)
Check '26 flag on sed -i py target refused' ($r.code -eq 2) "code=$($r.code)"

# 27. flag on, heredoc redirected to .md (non-code) -> 0
$s27 = NewSid '27'; Track $s27; Set-OrchOn $s27
$r = Invoke-Hook (BashJson "cat <<'EOF' > notes.md" $s27)
Check '27 flag on heredoc redirect to md passes' ($r.code -eq 0) "code=$($r.code)"

Write-Output "---- $pass passed, $fail failed ----"

foreach ($s in $cleanupSids) {
    $sfe = Safe $s
    Remove-Item -LiteralPath (Join-Path $orchDir "$sfe.on") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $orchDir "$sfe.off") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $gateDir "$sfe.count") -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 } else { exit 0 }
