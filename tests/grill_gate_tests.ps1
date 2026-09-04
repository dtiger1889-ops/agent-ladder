# Wrapper tests for ~/.claude/hooks/grill_gate.ps1 -- runs the hook exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code + output.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File grill_gate_tests.ps1
$hook = Join-Path $PSScriptRoot '..\\hooks\\grill_gate.ps1'
$dir  = Join-Path $env:TEMP 'agent_ladder_grill_gate'
$sid  = 'grilltest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$tpNo = Join-Path $env:TEMP "grill_test_transcript_none_$sid.jsonl"
$tpYes = Join-Path $env:TEMP "grill_test_transcript_grilled_$sid.jsonl"
Set-Content -LiteralPath $tpNo -Value '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\x\\CHECKPOINT.md"}}]}}' -Encoding UTF8
Set-Content -LiteralPath $tpYes -Value '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[]}}]}}' -Encoding UTF8

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
function Prompt-Json([string]$prompt, [string]$tp, [string]$s = $sid) {
    return (@{ hook_event_name = 'UserPromptSubmit'; session_id = $s; transcript_path = $tp; cwd = '<workspace-root>'; prompt = $prompt } | ConvertTo-Json -Compress)
}
function Write-Json([string]$file, [string]$tp, [string]$s = $sid, [bool]$agent = $false) {
    $h = @{ hook_event_name = 'PreToolUse'; tool_name = 'Write'; session_id = $s; transcript_path = $tp; cwd = '<workspace-root>'; tool_input = @{ file_path = $file; content = 'x' } }
    if ($agent) { $h['agent_id'] = 'sub-1' }
    return ($h | ConvertTo-Json -Compress)
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}

# 1. kickoff prompt -> advisory on stdout, exit 0, pending flag written
$r = Invoke-Hook (Prompt-Json 'We need a workspace wide deep implementation of grill me that forces you to ask me questions' $tpNo)
Check '1 kickoff prompt advises (exit 0 + stdout)' ($r.code -eq 0 -and $r.out -match 'grill-gate') "code=$($r.code) out=$($r.out.Substring(0,[Math]::Min(80,$r.out.Length)))"
Check '1b pending flag exists' (Test-Path (Join-Path $dir "$sid.pending"))

# 2. second kickoff prompt same session -> silent (advised once), pending stays
$r = Invoke-Hook (Prompt-Json 'now build me a dashboard for the sprint queue please' $tpNo)
Check '2 second kickoff is silent' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "out=$($r.out)"

# 3. first Write with pending + no interview -> exit 2 block
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\new_thing.md' $tpNo)
Check '3 first write blocks once (exit 2)' ($r.code -eq 2 -and $r.err -match 'BLOCKED ONCE') "code=$($r.code) err=$($r.err.Substring(0,[Math]::Min(80,$r.err.Length)))"

# 4. re-issue -> passes
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\new_thing.md' $tpNo)
Check '4 re-issued write passes' ($r.code -eq 0) "code=$($r.code)"

# 5. fresh session: CHECKPOINT.md write never blocked even with pending
$s5 = "$sid-5"; Invoke-Hook (Prompt-Json 'please create a new skill for triaging my downloads folder' $tpNo $s5) | Out-Null
$r = Invoke-Hook (Write-Json '<workspace-root>\CHECKPOINT.md' $tpNo $s5)
Check '5 CHECKPOINT.md write exempt' ($r.code -eq 0) "code=$($r.code)"
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\x.md' $tpNo $s5)
Check '5b then a spec write blocks' ($r.code -eq 2) "code=$($r.code)"

# 6. fresh session: interview already in transcript -> no block, done flag
$s6 = "$sid-6"; Invoke-Hook (Prompt-Json 'implement a new hook that counts tokens per session' $tpNo $s6) | Out-Null
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\x.md' $tpYes $s6)
Check '6 grilled transcript passes' ($r.code -eq 0) "code=$($r.code)"
Check '6b done flag set' (Test-Path (Join-Path $dir "$s6.done"))

# 7. opt-out phrases and slash commands never arm the gate
$s7 = "$sid-7"
$r = Invoke-Hook (Prompt-Json 'build me a dashboard for the queue, just build it, no questions' $tpNo $s7)
Check '7 opt-out prompt silent' ([string]::IsNullOrWhiteSpace($r.out) -and -not (Test-Path (Join-Path $dir "$s7.pending")))
$r = Invoke-Hook (Prompt-Json '/checkpoint' $tpNo $s7)
Check '7b slash prompt silent' ([string]::IsNullOrWhiteSpace($r.out))
$r = Invoke-Hook (Prompt-Json 'why do I see two tasks in the queue? is that correct?' $tpNo $s7)
Check '7c question prompt silent' ([string]::IsNullOrWhiteSpace($r.out) -and -not (Test-Path (Join-Path $dir "$s7.pending")))
$r = Invoke-Hook (Prompt-Json 'fix the typo in the README and rename the variable foo to bar' $tpNo $s7)
Check '7d edit/fix prompt silent' ([string]::IsNullOrWhiteSpace($r.out))

# 8. subagent write never gated
$s8 = "$sid-8"; Invoke-Hook (Prompt-Json 'create a new automation that posts the daily summary' $tpNo $s8) | Out-Null
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\x.md' $tpNo $s8 $true)
Check '8 subagent write passes' ($r.code -eq 0) "code=$($r.code)"

# 9. malformed input fails open
$r = Invoke-Hook 'this is not json'
Check '9 malformed input fails open' ($r.code -eq 0) "code=$($r.code)"

# 10. harness-generated turns never arm the gate (2026-09-03: a subagent task-notification did)
$s10 = "$sid-10"
$notif = "<system-reminder>`n[SYSTEM NOTIFICATION - NOT USER INPUT]`n<task-notification>`n<summary>Agent `"Backfill android CHECKPOINT tags`" finished</summary>`n<result>We need to implement a new hook and build a dashboard for this.</result>`n</task-notification>`n</system-reminder>"
$r = Invoke-Hook (Prompt-Json $notif $tpNo $s10)
Check '10a task-notification prompt silent' ([string]::IsNullOrWhiteSpace($r.out) -and $r.code -eq 0) "out=$($r.out) code=$($r.code)"
$r = Invoke-Hook (Write-Json '<workspace-root>\specs\x.md' $tpNo $s10)
Check '10b write after notification passes' ($r.code -eq 0) "code=$($r.code)"
$r = Invoke-Hook (Prompt-Json "[SYSTEM NOTIFICATION - NOT USER INPUT] please build a new tracker app for the queue" $tpNo $s10)
Check '10c system-notification prefix silent' ([string]::IsNullOrWhiteSpace($r.out)) "out=$($r.out)"
$r = Invoke-Hook (Prompt-Json "please build a new tracker app for the queue" $tpNo $s10)
Check '10d real kickoff still advises' (-not [string]::IsNullOrWhiteSpace($r.out)) "out=$($r.out)"

Write-Output "---- $pass passed, $fail failed ----"
Get-ChildItem $dir -File -Filter "$sid*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tpNo, $tpYes -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 } else { exit 0 }


