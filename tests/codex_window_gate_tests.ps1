# Wrapper tests for the codex_window_gate.ps1 threshold gate -- runs it exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code + output.
# Fake rollout logs are built under $env:TEMP and pointed at with CODEX_WINDOW_GATE_SESSIONS, and a fake
# tunable policy is pointed at with AGENT_LADDER_POLICY_PATH, so the tests never read the real
# ~/.codex/sessions, never touch real usage state, and never depend on the deployed policy file.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File codex_window_gate_tests.ps1 [-Hook <path>]

param(
    [string]$Hook = (Join-Path $PSScriptRoot '../hooks/codex_window_gate.ps1')
)
$hook = $Hook
$run = 'cwg-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$flagDir = Join-Path $env:TEMP 'claude_codex_window_gate'

# --- fake rollout roots -------------------------------------------------------
$soon = [int64][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$past = [int64][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3600
function New-Rollout([string]$root, [double]$p, [int64]$pr, [double]$s, [int64]$sr) {
    $dir = Join-Path $root '2026\09\09'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $line = '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":' +
    $p + ',"window_minutes":300,"resets_at":' + $pr + '},"secondary":{"used_percent":' + $s +
    ',"window_minutes":10080,"resets_at":' + $sr + '},"plan_type":"plus"}}}'
    Set-Content -LiteralPath (Join-Path $dir 'rollout-2026-09-09T01-00-00-test.jsonl') -Value $line -Encoding UTF8
    return $root
}
# Fake tunable policy files (only the fields the gate reads: openai window maxUsedPercent).
function New-Config([string]$path, $fiveH, $week) {
    $obj = @{ version = 1; providers = @{ openai = @{ windows = @{
                    fiveHour = @{ maxUsedPercent = $fiveH }
                    weekly   = @{ maxUsedPercent = $week }
                }
            }
        }
    }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
$rootOk = New-Rollout (Join-Path $env:TEMP "cwg_ok_$run") 10.0 $soon 2.0 $soon
$rootHot = New-Rollout (Join-Path $env:TEMP "cwg_hot_$run") 92.0 $soon 46.0 $soon
$rootWeek = New-Rollout (Join-Path $env:TEMP "cwg_week_$run") 5.0 $soon 91.0 $soon
$rootWeek70 = New-Rollout (Join-Path $env:TEMP "cwg_week70_$run") 5.0 $soon 70.0 $soon
$rootWeek75 = New-Rollout (Join-Path $env:TEMP "cwg_week75_$run") 5.0 $soon 75.0 $soon
$rootStale = New-Rollout (Join-Path $env:TEMP "cwg_stale_$run") 99.0 $past 99.0 $past
$rootEmpty = Join-Path $env:TEMP "cwg_empty_$run"
New-Item -ItemType Directory -Path $rootEmpty -Force | Out-Null

# Default policy for most tests: the shipped defaults, 5-hour 70 / weekly 75.
$cfgDir = Join-Path $env:TEMP "cwg_cfg_$run"
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
$defaultPolicy = New-Config (Join-Path $cfgDir 'default.json') 70 75
$missingPolicy = Join-Path $cfgDir 'does-not-exist.json'

function Invoke-Hook([string]$json, [string]$sessionsRoot, [string]$policyPath = $defaultPolicy) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CODEX_WINDOW_GATE_SESSIONS'] = $sessionsRoot
    $psi.EnvironmentVariables['AGENT_LADDER_POLICY_PATH'] = $policyPath
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out; err = $err }
}
function Bash-Json([string]$cmd, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; session_id = $s
            cwd = 'C:\work\project'; tool_input = @{ command = $cmd }
        } | ConvertTo-Json -Compress)
}
function Agent-Json([string]$sub, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Agent'; session_id = $s
            cwd = 'C:\work\project'; tool_input = @{ subagent_type = $sub; prompt = 'do a thing' }
        } | ConvertTo-Json -Compress)
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}
function Snip([string]$t) { if ($t) { $t.Substring(0, [Math]::Min(120, $t.Length)) } else { '' } }

# 1. 5-hour window over the limit -> blocked
$s1 = "$run-1"
$r = Invoke-Hook (Bash-Json '"go" | codex exec --skip-git-repo-check -s workspace-write -C . "audit these six files"' $s1) $rootHot
Check '1 5-hour window over limit blocks (exit 2)' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"

# 2. weekly window over the limit -> blocked
$s2 = "$run-2"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "build the thing"' $s2) $rootWeek
Check '2 weekly window over limit blocks (exit 2)' ($r.code -eq 2 -and $r.err -match '(?i)weekly window is at 91') "code=$($r.code) err=$(Snip $r.err)"

# 3. both windows healthy -> allowed, one advisory on stdout, silent on the second call
$s3 = "$run-3"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "build the thing"' $s3) $rootOk
Check '3 healthy windows allow (exit 0 + budget line)' ($r.code -eq 0 -and $r.out -match 'codex-window-gate' -and $r.out -match '5-hour window 10') "code=$($r.code) out=$(Snip $r.out)"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "build another thing"' $s3) $rootOk
Check '3b second call in same session is silent' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "out=$(Snip $r.out)"

# 4. probes are never gated, even at 92 percent
$s4 = "$run-4"
foreach ($probe in @('codex --version', 'codex --help', 'codex login status', 'C:\tools\bin\codex.cmd --version')) {
    $r = Invoke-Hook (Bash-Json $probe $s4) $rootHot
    Check "4 probe not gated: $probe" ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out) -and [string]::IsNullOrWhiteSpace($r.err)) "code=$($r.code) err=$(Snip $r.err)"
}

# 5. no readable snapshot -> once-per-session advisory, never a block
$s5 = "$run-5"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "build the thing"' $s5) $rootEmpty
Check '5 unreadable state advises, does not block' ($r.code -eq 0 -and $r.out -match 'both windows' -and $r.out -match 'NOT blocked') "code=$($r.code) out=$(Snip $r.out)"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "again"' $s5) $rootEmpty
Check '5b advisory fires only once' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "out=$(Snip $r.out)"

# 6. a snapshot whose windows already reset reads as unknown, not as 99 percent
$s6 = "$run-6"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "build the thing"' $s6) $rootStale
Check '6 expired snapshot is unknown, not a block' ($r.code -eq 0 -and $r.out -match 'both windows') "code=$($r.code) out=$(Snip $r.out)"

# 7. the codex-rescue agent is gated the same way
$s7 = "$run-7"
$r = Invoke-Hook (Agent-Json 'codex:codex-rescue' $s7) $rootHot
Check '7 codex-rescue agent blocked at 92 percent' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"
$s7b = "$run-7b"
$r = Invoke-Hook (Agent-Json 'general-purpose' $s7b) $rootHot
Check '7b non-codex agent untouched' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "code=$($r.code) out=$(Snip $r.out)"

# 8. merely MENTIONING codex is not an invocation
$s8 = "$run-8"
foreach ($cmd in @('grep -rn "codex exec" C:/work/project',
        'cat C:/work/project/codex_cli_notes.md',
        'ls C:/work/.codex/sessions')) {
    $r = Invoke-Hook (Bash-Json $cmd $s8) $rootHot
    Check "8 mention is not invocation: $($cmd.Substring(0,[Math]::Min(28,$cmd.Length)))" ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.err)) "code=$($r.code) err=$(Snip $r.err)"
}

# 9. the notes' documented shim shape (stdin pipe + call operator + $codex variable) is caught
$s9 = "$run-9"
$r = Invoke-Hook (Bash-Json '"spec" | & $codex exec --skip-git-repo-check -s workspace-write -C hintforge_dev "port the reader"' $s9) $rootHot
Check '9 piped $codex exec shape blocked' ($r.code -eq 2) "code=$($r.code) err=$(Snip $r.err)"

# 10. malformed / empty stdin fails open
$r = Invoke-Hook '' $rootHot
Check '10 empty stdin exits 0' ($r.code -eq 0) "code=$($r.code)"
$r = Invoke-Hook 'not json at all' $rootHot
Check '10b garbage stdin exits 0' ($r.code -eq 0) "code=$($r.code)"

# 11. an unrelated tool is never touched
$r = Invoke-Hook (@{ hook_event_name = 'PreToolUse'; tool_name = 'Read'; session_id = "$run-11"; tool_input = @{ file_path = 'C:\x\codex.md' } } | ConvertTo-Json -Compress) $rootHot
Check '11 Read tool untouched' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "code=$($r.code)"

# --- tunable-threshold coverage (the config-driven "new system") --------------

# 12. weekly at 70 is under the shipped 75 limit -> allowed (a 65-70% weekly window still lets Codex
#     through, where an over-tight limit would have blocked it)
$s12 = "$run-12"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "small job"' $s12) $rootWeek70
Check '12 weekly 70 under default-75 limit allows' ($r.code -eq 0 -and $r.out -match 'weekly window 70') "code=$($r.code) out=$(Snip $r.out)"

# 13. weekly exactly at the limit is not a breach (strictly-greater test)
$s13 = "$run-13"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "small job"' $s13) $rootWeek75
Check '13 weekly exactly at 75 is not blocked' ($r.code -eq 0) "code=$($r.code) err=$(Snip $r.err)"

# 14. LOWERING the weekly limit via config blocks a snapshot that the default would allow
$s14 = "$run-14"
$cfgTight = New-Config (Join-Path $cfgDir 'tight.json') 70 60
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "small job"' $s14) $rootWeek70 $cfgTight
Check '14 config weekly=60 blocks a 70 percent weekly window' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"

# 15. RAISING the 5-hour limit via config lets a snapshot through that the default would block
$s15 = "$run-15"
$cfgLoose = New-Config (Join-Path $cfgDir 'loose.json') 95 75
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "small job"' $s15) $rootHot $cfgLoose
Check '15 config 5-hour=95 allows a 92 percent 5-hour window' ($r.code -eq 0) "code=$($r.code) err=$(Snip $r.err)"

# 16. a missing config file falls back to the safe defaults (5-hour 70) and still gates
$s16 = "$run-16"
$r = Invoke-Hook (Bash-Json 'codex exec -s workspace-write "small job"' $s16) $rootHot $missingPolicy
Check '16 missing config keeps default limits and still blocks' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"

# --- cleanup ------------------------------------------------------------------
foreach ($d in @($rootOk, $rootHot, $rootWeek, $rootWeek70, $rootWeek75, $rootStale, $rootEmpty, $cfgDir)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -LiteralPath $flagDir -File -ErrorAction SilentlyContinue |
Where-Object { $_.Name -like "$run*" } | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output "codex_window_gate: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
