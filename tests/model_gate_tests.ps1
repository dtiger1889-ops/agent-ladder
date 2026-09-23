# Wrapper tests for hooks/model_gate.ps1 in this repository -- runs the hook exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code + output.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File model_gate_tests.ps1
$hook = Join-Path $PSScriptRoot '..\hooks\model_gate.ps1'

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

function AgentJson($toolInput) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Agent'; session_id = 'mgtest-1'; cwd = 'C:\path\to\repo'; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 6)
}

function BashJson($toolInput) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; session_id = 'mgtest-1'; cwd = 'C:\path\to\repo'; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 6)
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}

# 1. no model -> 2
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it' })
Check '1 no model blocks' ($r.code -eq 2 -and $r.err -match 'model-gate') "code=$($r.code) err=$($r.err)"

# 2. model haiku -> 2
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'haiku' })
Check '2 model haiku blocks' ($r.code -eq 2 -and $r.err -match 'model-gate') "code=$($r.code) err=$($r.err)"

# 3. model "Haiku 4.5" -> 2
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'Haiku 4.5' })
Check '3 model Haiku 4.5 blocks' ($r.code -eq 2 -and $r.err -match 'model-gate') "code=$($r.code) err=$($r.err)"

# 4. model sonnet -> 0
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'sonnet' })
Check '4 model sonnet passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 5. model opus with subagent_type claude-code-guide -> 0
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'opus'; subagent_type = 'claude-code-guide' })
Check '5 model opus with subagent_type passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 6. malformed JSON -> 0
$r = Invoke-Hook 'this is not json'
Check '6 malformed JSON passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 7. tool_name Bash with no model -> 0 (only Agent is gated)
$r = Invoke-Hook (BashJson @{ command = 'ls -la' })
Check '7 non-Agent tool with no model passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

Write-Output "---- $pass passed, $fail failed ----"
if ($fail -gt 0) { exit 1 } else { exit 0 }
