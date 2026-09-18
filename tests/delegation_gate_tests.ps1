# Wrapper tests for ~/.claude/hooks/delegation_gate.ps1 -- runs the hook exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code + output.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File delegation_gate_tests.ps1
$hook = Join-Path $PSScriptRoot '..\hooks\delegation_gate.ps1'
$dir  = Join-Path $env:TEMP 'claude_delegation_gate'

function New-Sid([string]$tag) { return "dgtest-$tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8) }

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

function WriteJson([string]$sid, [string]$fp, [int]$n) {
    $content = (@('x = 1') * $n) -join "`n"
    return (@{ session_id = $sid; tool_name = 'Write'; tool_input = @{ file_path = $fp; content = $content } } | ConvertTo-Json -Compress)
}

function BashJson([string]$sid, [string]$cmd) {
    return (@{ session_id = $sid; tool_name = 'Bash'; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress)
}

function HeredocCmd([string]$targetPath, [int]$n) {
    $bodyLines = @('x = 1') * $n
    $body = ($bodyLines -join "`n")
    return "cat > $targetPath <<'EOF'`n$body`nEOF"
}

function Remove-State([string]$sid) {
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')
    Remove-Item -LiteralPath (Join-Path $dir "$safe.count") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $dir "$safe.fired") -Force -ErrorAction SilentlyContinue
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}

# 1. 700-line Write of a .py file fires
$sid1 = New-Sid '1'
Remove-State $sid1
$r = Invoke-Hook (WriteJson $sid1 'C:\path\to\repo\scratch_dg1.py' 700)
Check '1 700-line Write fires' ($r.code -eq 2 -and $r.err -match 'delegation-gate') "code=$($r.code) err=$($r.err)"

# 2. Repeat on the same session (already past threshold, already fired) stays silent
$r2 = Invoke-Hook (WriteJson $sid1 'C:\path\to\repo\scratch_dg1.py' 10)
Check '2 repeat silent' ($r2.code -eq 0 -and [string]::IsNullOrEmpty($r2.err)) "code=$($r2.code) err=$($r2.err)"
Remove-State $sid1

# 3. Markdown Write of 700 lines stays silent (extension not in $CodeExt)
$sid3 = New-Sid '3'
Remove-State $sid3
$r3 = Invoke-Hook (WriteJson $sid3 'C:\path\to\repo\scratch_dg3.md' 700)
Check '3 markdown Write silent' ($r3.code -eq 0 -and [string]::IsNullOrEmpty($r3.err)) "code=$($r3.code) err=$($r3.err)"
Remove-State $sid3

# 4. Bash heredoc of 650 code lines to a .py target fires
$sid4 = New-Sid '4'
Remove-State $sid4
$cmd4 = HeredocCmd 'C:\path\to\repo\scratch_dg4.py' 650
$r4 = Invoke-Hook (BashJson $sid4 $cmd4)
Check '4 Bash heredoc 650 lines fires' ($r4.code -eq 2 -and $r4.err -match 'delegation-gate') "code=$($r4.code) err=$($r4.err)"
Remove-State $sid4

# 5. 700-line heredoc to a scratchpad path does not fire (half weight -> 350 < 600)
$sid5 = New-Sid '5'
Remove-State $sid5
$cmd5 = HeredocCmd 'D:\scratch\AppData\Local\Temp\claude\scratch_dg5.py' 700
$r5 = Invoke-Hook (BashJson $sid5 $cmd5)
Check '5 scratchpad 700-line heredoc silent' ($r5.code -eq 0 -and [string]::IsNullOrEmpty($r5.err)) "code=$($r5.code) err=$($r5.err)"
Remove-State $sid5

# 6. 1,300 lines to a scratchpad path fires (650 weighted, past 600)
$sid6 = New-Sid '6'
Remove-State $sid6
$cmd6 = HeredocCmd 'D:\scratch\AppData\Local\Temp\claude\scratch_dg6.py' 1300
$r6 = Invoke-Hook (BashJson $sid6 $cmd6)
Check '6 scratchpad 1300-line heredoc fires' ($r6.code -eq 2 -and $r6.err -match 'delegation-gate') "code=$($r6.code) err=$($r6.err)"
Remove-State $sid6

# 7. Bash `git status` adds nothing
$sid7 = New-Sid '7'
Remove-State $sid7
$r7 = Invoke-Hook (BashJson $sid7 'git status')
Check '7 git status adds nothing' ($r7.code -eq 0 -and [string]::IsNullOrEmpty($r7.err)) "code=$($r7.code) err=$($r7.err)"
$safe7 = ($sid7 -replace '[^A-Za-z0-9-]', '_')
$hasCounter = Test-Path -LiteralPath (Join-Path $dir "$safe7.count")
Check '7b git status writes no counter file' (-not $hasCounter) "counter exists: $hasCounter"
Remove-State $sid7

Write-Output ""
Write-Output "TOTAL: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
