# Wrapper tests for the codex_window_gate.ps1 adapter -- runs it exactly as Claude Code
# would (powershell.exe -NoProfile -ExecutionPolicy Bypass -File codex_window_gate.ps1, JSON on
# stdin) and checks exit code + output. All policy/usage/estimate fixtures are synthetic, normalized
# JSON written under a generated TEMP child and pointed at via the AGENT_LADDER_* env overrides, so
# this never reads or mutates any real policy/usage state.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File codex_window_gate_tests.ps1

$hook = Join-Path $PSScriptRoot '../hooks/codex_window_gate.ps1'
$run = 'cwg-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP "cwg_tests_$run"
New-Item -ItemType Directory -Path $root -Force | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}
function Snip([string]$t) { if ($t) { $t.Substring(0, [Math]::Min(220, $t.Length)) } else { '' } }

function Save-Json($obj, [string]$path) {
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}
function Save-JsonQuiet($obj, [string]$path) {
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
}
function Get-Sha256Hex([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally { $sha.Dispose() }
}

function Bash-Json([string]$cmd, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; session_id = $s
            cwd = 'C:\work\project'; tool_input = @{ command = $cmd }
        } | ConvertTo-Json -Compress)
}
function Agent-Json([string]$sub, [string]$prompt, [string]$s) {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Agent'; session_id = $s
            cwd = 'C:\work\project'; tool_input = @{ subagent_type = $sub; prompt = $prompt }
        } | ConvertTo-Json -Compress)
}

function Invoke-Hook([string]$json, [hashtable]$envOverrides = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($k in $envOverrides.Keys) { $psi.EnvironmentVariables[$k] = $envOverrides[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out; err = $err }
}

# --- shared fixtures: a policy/usage pair that clears every threshold comfortably ---------------
$now = [DateTime]::UtcNow
$nowIso = $now.ToString('o')
$futureReset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600

$goodPolicy = @{
    version       = 1
    priorityOrder = @('openai')
    providers     = @{
        openai = @{
            enabled                = $true
            profileRevision        = 'rev-test'
            maxUsageAgeMinutes     = 5
            maxEstimateAgeMinutes  = 1440
            windows                = @{
                fiveHour = @{ windowDurationMins = 300; minRemainingBefore = 10; reserveAfter = 5; maxJobPercentPoints = 20 }
                weekly   = @{ windowDurationMins = 10080; minRemainingBefore = 20; reserveAfter = 10; maxJobPercentPoints = 40 }
            }
        }
    }
}
$goodUsage = @{
    provider        = 'openai'
    profileRevision = 'rev-test'
    observedAt      = $nowIso
    source          = 'test-fixture'
    windows         = @{
        fiveHour = @{ usedPercent = 20; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 30; windowDurationMins = 10080; resetsAt = $futureReset }
    }
}

$policyPath = Save-Json $goodPolicy (Join-Path $root 'policy.json')
$usagePath = Save-Json $goodUsage (Join-Path $root 'usage.json')
$estimateDir = Join-Path $root 'estimates'
New-Item -ItemType Directory -Path $estimateDir -Force | Out-Null

$baseEnv = @{ AGENT_LADDER_POLICY_PATH = $policyPath; AGENT_LADDER_USAGE_PATH = $usagePath }

# 1. Classified launch, no estimate file present at all -> declined, names the expected hash
$s1 = "$run-1"
$estPath1 = Join-Path $estimateDir "$s1.json"
$env1 = $baseEnv + @{ AGENT_LADDER_ESTIMATE_PATH = $estPath1 }
$cmd1 = '"go" | codex exec --skip-git-repo-check -s workspace-write -C . "audit these six files"'
$r = Invoke-Hook (Bash-Json $cmd1 $s1) $env1
$expectedHash1 = Get-Sha256Hex $cmd1
Check '1 classified launch, no estimate file -> blocked (exit 2)' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"
Check '1b decline names the exact expected request hash' ($r.err -match [regex]::Escape($expectedHash1)) "err=$(Snip $r.err)"

# 2. Classified launch with a matching, fresh estimate under threshold -> allowed
$s2 = "$run-2"
$estPath2 = Join-Path $estimateDir "$s2.json"
$cmd2 = 'codex exec -s workspace-write "build the thing"'
$hash2 = Get-Sha256Hex $cmd2
Save-JsonQuiet (@{ provider = 'openai'; profileRevision = 'rev-test'; observedAt = $nowIso; source = 'caller-upper-bound'
        requestHash = $hash2; spendPercentPoints = @{ fiveHour = 5; weekly = 5 } }) $estPath2
$env2 = $baseEnv + @{ AGENT_LADDER_ESTIMATE_PATH = $estPath2 }
$r = Invoke-Hook (Bash-Json $cmd2 $s2) $env2
Check '2 classified launch with matching fresh estimate -> allowed (exit 0)' ($r.code -eq 0 -and $r.out -match 'preflight passed') "code=$($r.code) out=$(Snip $r.out)"

# 3. Classified launch whose estimate exceeds a window cap -> declined
$s3 = "$run-3"
$estPath3 = Join-Path $estimateDir "$s3.json"
$cmd3 = 'codex exec -s workspace-write "a much bigger job"'
$hash3 = Get-Sha256Hex $cmd3
Save-JsonQuiet (@{ provider = 'openai'; profileRevision = 'rev-test'; observedAt = $nowIso; source = 'caller-upper-bound'
        requestHash = $hash3; spendPercentPoints = @{ fiveHour = 99; weekly = 5 } }) $estPath3
$env3 = $baseEnv + @{ AGENT_LADDER_ESTIMATE_PATH = $estPath3 }
$r = Invoke-Hook (Bash-Json $cmd3 $s3) $env3
Check '3 estimate over maxJobPercentPoints -> blocked' ($r.code -eq 2 -and $r.err -match 'maxJobPercentPoints') "code=$($r.code) err=$(Snip $r.err)"

# 4. Probes are never gated, even with no policy/usage/estimate on disk
$s4 = "$run-4"
foreach ($probe in @('codex --version', 'codex --help', 'codex login status', 'C:\tools\bin\codex.cmd --version')) {
    $r = Invoke-Hook (Bash-Json $probe $s4) @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
    Check "4 probe not gated: $probe" ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out) -and [string]::IsNullOrWhiteSpace($r.err)) "code=$($r.code) err=$(Snip $r.err)"
}

# 5. Merely MENTIONING codex is not an invocation -- untouched even with no fixtures
$s5 = "$run-5"
foreach ($cmd in @('grep -rn "codex exec" C:/work/project',
        'cat C:/work/project/codex_cli_notes.md',
        'ls C:/work/.codex/sessions')) {
    $r = Invoke-Hook (Bash-Json $cmd $s5) @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
    Check "5 mention is not invocation: $($cmd.Substring(0,[Math]::Min(28,$cmd.Length)))" ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.err)) "code=$($r.code) err=$(Snip $r.err)"
}

# 6. The notes' documented shim shape (stdin pipe + call operator + $codex variable) is caught
$s6 = "$run-6"
$r = Invoke-Hook (Bash-Json '"spec" | & $codex exec --skip-git-repo-check -s workspace-write -C hintforge_dev "port the reader"' $s6) @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
Check '6 piped $codex exec shape is classified and blocked (no policy on disk)' ($r.code -eq 2) "code=$($r.code) err=$(Snip $r.err)"

# 7. An Agent call whose subagent_type names codex is gated the same way
$s7 = "$run-7"
$estPath7 = Join-Path $estimateDir "$s7.json"
$prompt7 = 'do a thing'
$hash7 = Get-Sha256Hex "codex:codex-rescue`n$prompt7"
Save-JsonQuiet (@{ provider = 'openai'; profileRevision = 'rev-test'; observedAt = $nowIso; source = 'caller-upper-bound'
        requestHash = $hash7; spendPercentPoints = @{ fiveHour = 5; weekly = 5 } }) $estPath7
$env7 = $baseEnv + @{ AGENT_LADDER_ESTIMATE_PATH = $estPath7 }
$r = Invoke-Hook (Agent-Json 'codex:codex-rescue' $prompt7 $s7) $env7
Check '7 codex-rescue agent with matching estimate -> allowed' ($r.code -eq 0) "code=$($r.code) out=$(Snip $r.out) err=$(Snip $r.err)"

# 7b. A non-codex agent is never touched
$s7b = "$run-7b"
$r = Invoke-Hook (Agent-Json 'general-purpose' 'do a thing' $s7b) @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
Check '7b non-codex agent untouched' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out) -and [string]::IsNullOrWhiteSpace($r.err)) "code=$($r.code)"

# 8. Malformed / empty stdin: unknown classification fails open
$r = Invoke-Hook '' @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
Check '8 empty stdin exits 0' ($r.code -eq 0) "code=$($r.code)"
$r = Invoke-Hook 'not json at all' @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'missing-policy.json') }
Check '8b garbage stdin exits 0' ($r.code -eq 0) "code=$($r.code)"

# 9. An unrelated tool is never touched
$r = Invoke-Hook (@{ hook_event_name = 'PreToolUse'; tool_name = 'Read'; session_id = "$run-9"; tool_input = @{ file_path = 'C:\x\codex.md' } } | ConvertTo-Json -Compress) @{}
Check '9 Read tool untouched' ($r.code -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) "code=$($r.code)"

# 10. Missing/corrupt policy file declines only the classified handoff -- request hash still named
$s10 = "$run-10"
$cmd10 = 'codex exec -s workspace-write "another job"'
Set-Content -LiteralPath (Join-Path $root 'corrupt-policy.json') -Value 'not { json' -Encoding UTF8
$r = Invoke-Hook (Bash-Json $cmd10 $s10) @{ AGENT_LADDER_POLICY_PATH = (Join-Path $root 'corrupt-policy.json') }
Check '10 corrupt policy declines the classified handoff' ($r.code -eq 2 -and $r.err -match 'BLOCKED') "code=$($r.code) err=$(Snip $r.err)"

# 11. requestHash in the estimate file does not match this exact request -> declined
$s11 = "$run-11"
$estPath11 = Join-Path $estimateDir "$s11.json"
$cmd11 = 'codex exec -s workspace-write "yet another job"'
Save-JsonQuiet (@{ provider = 'openai'; profileRevision = 'rev-test'; observedAt = $nowIso; source = 'caller-upper-bound'
        requestHash = 'stale-hash-from-a-different-request'; spendPercentPoints = @{ fiveHour = 5; weekly = 5 } }) $estPath11
$env11 = $baseEnv + @{ AGENT_LADDER_ESTIMATE_PATH = $estPath11 }
$r = Invoke-Hook (Bash-Json $cmd11 $s11) $env11
Check '11 estimate requestHash mismatch -> declined' ($r.code -eq 2 -and $r.err -match 'requestHash does not match') "code=$($r.code) err=$(Snip $r.err)"

# --- cleanup: only this run's generated TEMP child ------------------------------------------------
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
$stillThere = Test-Path -LiteralPath $root
Check '12 cleanup removed only the generated TEMP child' (-not $stillThere) "root=$root"

Write-Output ''
Write-Output "codex_window_gate: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
