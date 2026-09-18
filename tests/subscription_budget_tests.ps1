# Wrapper tests for subscription_budget.ps1 -- runs the CLI exactly as a caller would
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File subscription_budget.ps1 -PolicyPath ...),
# checking exit code and the {allowed, reasons} JSON on stdout. All fixtures are synthetic and
# written under a single generated child directory; nothing outside it is ever touched or removed,
# and no paid model call or live provider state is involved.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File subscription_budget_tests.ps1 [-WorkDir <path>]

param(
    [string]$WorkDir = (Join-Path $env:TEMP ("subbudget_tests_" + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$script = Join-Path $PSScriptRoot '../hooks/subscription_budget.ps1'
$existedBefore = Test-Path -LiteralPath $WorkDir
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name  $detail" }
}
function Snip([string]$t) { if ($t) { $t.Substring(0, [Math]::Min(200, $t.Length)) } else { '' } }

function Save-Json($obj, [string]$path) {
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function New-Window([double]$dur, [double]$minRem, [double]$reserve, [double]$cap) {
    return @{ windowDurationMins = $dur; minRemainingBefore = $minRem; reserveAfter = $reserve; maxJobPercentPoints = $cap }
}

# Standard two-window (fiveHour/weekly) policy for one provider; caller can override fields.
function New-Policy([string]$provider, [bool]$enabled, [string]$profileRevision, [double]$maxUsageAge, [double]$maxEstimateAge, $windows) {
    $providers = @{}
    $providers[$provider] = @{
        enabled             = $enabled
        profileRevision     = $profileRevision
        maxUsageAgeMinutes  = $maxUsageAge
        maxEstimateAgeMinutes = $maxEstimateAge
        windows             = $windows
    }
    return @{ version = 1; priorityOrder = @($provider); providers = $providers }
}

function New-Usage([string]$provider, [string]$profileRevision, [string]$observedAt, [string]$source, $windows) {
    return @{ provider = $provider; profileRevision = $profileRevision; observedAt = $observedAt; source = $source; windows = $windows }
}

function New-Estimate([string]$provider, [string]$profileRevision, [string]$observedAt, [string]$source, [string]$requestHash, $spend) {
    return @{ provider = $provider; profileRevision = $profileRevision; observedAt = $observedAt; source = $source; requestHash = $requestHash; spendPercentPoints = $spend }
}

function Invoke-Budget([string]$policyPath, [string]$provider, [string]$usagePath, [string]$estimatePath, [string]$hash) {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-PolicyPath', $policyPath, '-Provider', $provider)
    if ($usagePath) { $args += @('-UsagePath', $usagePath) }
    if ($estimatePath) { $args += @('-EstimatePath', $estimatePath) }
    $args += @('-RequestHash', $hash)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    $decision = $null
    try { $decision = $out | ConvertFrom-Json } catch { }
    return @{ code = $p.ExitCode; out = $out; err = $err; decision = $decision }
}

$now = [DateTime]::UtcNow
function IsoUtc([DateTime]$dt) { $dt.ToString('o') }
$nowIso = IsoUtc $now
$staleIso = IsoUtc ($now.AddMinutes(-60))
$futureIso = IsoUtc ($now.AddMinutes(10))
$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$futureReset = $nowUnix + 3600
$pastReset = $nowUnix - 3600
$reqHash = 'deadbeef00'

$windowsOk = @{
    fiveHour = New-Window 300 10 5 20
    weekly   = New-Window 10080 20 10 40
}

# 1. Both windows healthy -> allowed
$p1 = Save-Json (New-Policy 'anthropic' $true 'rev-a' 5 1440 $windowsOk) (Join-Path $WorkDir 'p1.json')
$u1 = Save-Json (New-Usage 'anthropic' 'rev-a' $nowIso 'probe' @{
        fiveHour = @{ usedPercent = 30; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 40; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'u1.json')
$e1 = Save-Json (New-Estimate 'anthropic' 'rev-a' $nowIso 'upper-bound' $reqHash @{ fiveHour = 5; weekly = 5 }) (Join-Path $WorkDir 'e1.json')
$r = Invoke-Budget $p1 'anthropic' $u1 $e1 $reqHash
Check '1 anthropic provider, both windows healthy -> allowed' ($r.code -eq 0 -and $r.decision.allowed -eq $true) "code=$($r.code) out=$(Snip $r.out)"

# 2. Same shape for openai (provider order/level coverage) -> allowed
$p2 = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 $windowsOk) (Join-Path $WorkDir 'p2.json')
$u2 = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{
        fiveHour = @{ usedPercent = 10; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 15; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'u2.json')
$e2 = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'upper-bound' $reqHash @{ fiveHour = 8; weekly = 8 }) (Join-Path $WorkDir 'e2.json')
$r = Invoke-Budget $p2 'openai' $u2 $e2 $reqHash
Check '2 openai provider, both windows healthy -> allowed' ($r.code -eq 0 -and $r.decision.allowed -eq $true) "code=$($r.code) out=$(Snip $r.out)"

# 3. minRemainingBefore boundary: remaining exactly at threshold -> allowed
$w3 = @{ fiveHour = New-Window 300 10 0 50 }
$p3 = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 $w3) (Join-Path $WorkDir 'p3.json')
$u3 = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{ fiveHour = @{ usedPercent = 90; windowDurationMins = 300; resetsAt = $futureReset } }) (Join-Path $WorkDir 'u3.json')
$e3 = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 1 }) (Join-Path $WorkDir 'e3.json')
$r = Invoke-Budget $p3 'openai' $u3 $e3 $reqHash
Check '3 remaining exactly equals minRemainingBefore -> allowed (boundary inclusive)' ($r.code -eq 0 -and $r.decision.allowed -eq $true) "code=$($r.code) out=$(Snip $r.out)"

# 3b. remaining one point below minRemainingBefore -> declined
$u3b = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{ fiveHour = @{ usedPercent = 91; windowDurationMins = 300; resetsAt = $futureReset } }) (Join-Path $WorkDir 'u3b.json')
$r = Invoke-Budget $p3 'openai' $u3b $e3 $reqHash
Check '3b remaining below minRemainingBefore -> declined' ($r.code -eq 2 -and $r.decision.allowed -eq $false -and ($r.decision.reasons -join ';') -match 'minRemainingBefore') "code=$($r.code) out=$(Snip $r.out)"

# 4. reserveAfter boundary: remaining minus estimate exactly at threshold -> allowed
$w4 = @{ fiveHour = New-Window 300 0 5 50 }
$p4 = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 $w4) (Join-Path $WorkDir 'p4.json')
$u4 = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{ fiveHour = @{ usedPercent = 80; windowDurationMins = 300; resetsAt = $futureReset } }) (Join-Path $WorkDir 'u4.json')
$e4 = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 15 }) (Join-Path $WorkDir 'e4.json')
$r = Invoke-Budget $p4 'openai' $u4 $e4 $reqHash
Check '4 remaining-estimate exactly equals reserveAfter -> allowed (boundary inclusive)' ($r.code -eq 0 -and $r.decision.allowed -eq $true) "code=$($r.code) out=$(Snip $r.out)"

# 4b. one point over -> declined
$e4b = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 16 }) (Join-Path $WorkDir 'e4b.json')
$r = Invoke-Budget $p4 'openai' $u4 $e4b $reqHash
Check '4b remaining-estimate below reserveAfter -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'reserveAfter') "code=$($r.code) out=$(Snip $r.out)"

# 5. maxJobPercentPoints boundary: estimate exactly at cap -> allowed
$w5 = @{ fiveHour = New-Window 300 0 0 20 }
$p5 = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 $w5) (Join-Path $WorkDir 'p5.json')
$u5 = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{ fiveHour = @{ usedPercent = 10; windowDurationMins = 300; resetsAt = $futureReset } }) (Join-Path $WorkDir 'u5.json')
$e5 = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 20 }) (Join-Path $WorkDir 'e5.json')
$r = Invoke-Budget $p5 'openai' $u5 $e5 $reqHash
Check '5 estimate exactly equals maxJobPercentPoints -> allowed (boundary inclusive)' ($r.code -eq 0 -and $r.decision.allowed -eq $true) "code=$($r.code) out=$(Snip $r.out)"

# 5b. estimate one point over the cap -> declined
$e5b = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 21 }) (Join-Path $WorkDir 'e5b.json')
$r = Invoke-Budget $p5 'openai' $u5 $e5b $reqHash
Check '5b estimate over maxJobPercentPoints -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'maxJobPercentPoints') "code=$($r.code) out=$(Snip $r.out)"

# 6. No estimated-zero handoffs
$e6 = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 0 }) (Join-Path $WorkDir 'e6.json')
$r = Invoke-Budget $p5 'openai' $u5 $e6 $reqHash
Check '6 zero estimate is declined (no implicit zero)' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'greater than 0') "code=$($r.code) out=$(Snip $r.out)"

# 7. Policy disabled for provider -> declined
$pDisabled = Save-Json (New-Policy 'openai' $false 'rev-o' 5 1440 $windowsOk) (Join-Path $WorkDir 'pdis.json')
$r = Invoke-Budget $pDisabled 'openai' $u2 $e2 $reqHash
Check '7 policy disabled for provider -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'disabled') "code=$($r.code) out=$(Snip $r.out)"

# 8. Profile mismatch: usage.profileRevision differs from policy's configured profileRevision
$uMismatch = Save-Json (New-Usage 'openai' 'rev-DIFFERENT' $nowIso 'probe' @{
        fiveHour = @{ usedPercent = 10; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 15; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'umismatch.json')
$r = Invoke-Budget $p2 'openai' $uMismatch $e2 $reqHash
Check '8 usage profileRevision mismatch -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'profileRevision') "code=$($r.code) out=$(Snip $r.out)"

# 8b. estimate profile mismatch
$eMismatch = Save-Json (New-Estimate 'openai' 'rev-DIFFERENT' $nowIso 'ub' $reqHash @{ fiveHour = 8; weekly = 8 }) (Join-Path $WorkDir 'emismatch.json')
$r = Invoke-Budget $p2 'openai' $u2 $eMismatch $reqHash
Check '8b estimate profileRevision mismatch -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'profileRevision') "code=$($r.code) out=$(Snip $r.out)"

# 9. Request hash mismatch -> declined
$r = Invoke-Budget $p2 'openai' $u2 $e2 'not-the-real-hash'
Check '9 requestHash mismatch -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'requestHash does not match') "code=$($r.code) out=$(Snip $r.out)"

# 10. Stale usage (observedAt older than maxUsageAgeMinutes) -> declined
$uStale = Save-Json (New-Usage 'openai' 'rev-o' $staleIso 'probe' @{
        fiveHour = @{ usedPercent = 10; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 15; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'ustale.json')
$r = Invoke-Budget $p2 'openai' $uStale $e2 $reqHash
Check '10 stale usage snapshot -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'stale') "code=$($r.code) out=$(Snip $r.out)"

# 10b. Stale estimate (older than maxEstimateAgeMinutes; using a short window here)
$wShortEst = @{ fiveHour = New-Window 300 0 0 50; weekly = New-Window 10080 0 0 50 }
$pShortEst = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1 $wShortEst) (Join-Path $WorkDir 'pshortest.json')
$eStale = Save-Json (New-Estimate 'openai' 'rev-o' $staleIso 'ub' $reqHash @{ fiveHour = 5; weekly = 5 }) (Join-Path $WorkDir 'estale.json')
$r = Invoke-Budget $pShortEst 'openai' $u2 $eStale $reqHash
Check '10c stale estimate -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'stale') "code=$($r.code) out=$(Snip $r.out)"

# 11. Usage window already reset (resetsAt in the past) -> declined, not treated as zero
$uReset = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{
        fiveHour = @{ usedPercent = 5; windowDurationMins = 300; resetsAt = $pastReset }
        weekly   = @{ usedPercent = 5; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'ureset.json')
$r = Invoke-Budget $p2 'openai' $uReset $e2 $reqHash
Check '11 window already reset -> declined (unknown, not zero)' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'already reset') "code=$($r.code) out=$(Snip $r.out)"

# 12. Future-dated observedAt beyond the 60-second skew allowance -> declined
$uFuture = Save-Json (New-Usage 'openai' 'rev-o' $futureIso 'probe' @{
        fiveHour = @{ usedPercent = 5; windowDurationMins = 300; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 5; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'ufuture.json')
$r = Invoke-Budget $p2 'openai' $uFuture $e2 $reqHash
Check '12 future observedAt beyond skew -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'future') "code=$($r.code) out=$(Snip $r.out)"

# 13. windowDurationMins mismatch between usage and policy -> declined
$uBadDur = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{
        fiveHour = @{ usedPercent = 5; windowDurationMins = 999; resetsAt = $futureReset }
        weekly   = @{ usedPercent = 5; windowDurationMins = 10080; resetsAt = $futureReset }
    }) (Join-Path $WorkDir 'ubaddur.json')
$r = Invoke-Budget $p2 'openai' $uBadDur $e2 $reqHash
Check '13 window duration mismatch -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'windowDurationMins') "code=$($r.code) out=$(Snip $r.out)"

# 14. Missing usage file entirely -> declined
$r = Invoke-Budget $p2 'openai' (Join-Path $WorkDir 'does-not-exist.json') $e2 $reqHash
Check '14 missing usage file -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'usage snapshot is missing') "code=$($r.code) out=$(Snip $r.out)"

# 14b. Missing estimate file entirely -> declined
$r = Invoke-Budget $p2 'openai' $u2 (Join-Path $WorkDir 'does-not-exist2.json') $reqHash
Check '14b missing estimate file -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'estimate is missing') "code=$($r.code) out=$(Snip $r.out)"

# 14c. Missing policy file entirely -> declined
$r = Invoke-Budget (Join-Path $WorkDir 'no-policy.json') 'openai' $u2 $e2 $reqHash
Check '14c missing policy file -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'policy is missing') "code=$($r.code) out=$(Snip $r.out)"

# 15. Invalid policy: unconfigured window thresholds (null) -> declined, never treated as zero
$wNull = @{ fiveHour = @{ windowDurationMins = 300; minRemainingBefore = $null; reserveAfter = $null; maxJobPercentPoints = $null } }
$pNull = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 $wNull) (Join-Path $WorkDir 'pnull.json')
$uNull = Save-Json (New-Usage 'openai' 'rev-o' $nowIso 'probe' @{ fiveHour = @{ usedPercent = 5; windowDurationMins = 300; resetsAt = $futureReset } }) (Join-Path $WorkDir 'unull.json')
$eNull = Save-Json (New-Estimate 'openai' 'rev-o' $nowIso 'ub' $reqHash @{ fiveHour = 5 }) (Join-Path $WorkDir 'enull.json')
$r = Invoke-Budget $pNull 'openai' $uNull $eNull $reqHash
Check '15 unconfigured (null) window thresholds -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'not fully configured') "code=$($r.code) out=$(Snip $r.out)"

# 16. Policy with zero windows configured -> declined
$pNoWindows = Save-Json (New-Policy 'openai' $true 'rev-o' 5 1440 @{}) (Join-Path $WorkDir 'pnowin.json')
$r = Invoke-Budget $pNoWindows 'openai' $u2 $e2 $reqHash
Check '16 no configured windows -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'at least one window') "code=$($r.code) out=$(Snip $r.out)"

# 17. Unknown provider key not present in policy -> declined
$r = Invoke-Budget $p2 'unknownprovider' $u2 $e2 $reqHash
Check '17 unknown provider -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'no configuration for provider') "code=$($r.code) out=$(Snip $r.out)"

# 18. Bad policy version -> declined
$pBadVer = New-Policy 'openai' $true 'rev-o' 5 1440 $windowsOk
$pBadVer.version = 2
$pBadVerPath = Save-Json $pBadVer (Join-Path $WorkDir 'pbadver.json')
$r = Invoke-Budget $pBadVerPath 'openai' $u2 $e2 $reqHash
Check '18 policy version != 1 -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'version must be 1') "code=$($r.code) out=$(Snip $r.out)"

# 19. Non-positive freshness setting -> declined
$pBadFresh = New-Policy 'openai' $true 'rev-o' 0 1440 $windowsOk
$pBadFreshPath = Save-Json $pBadFresh (Join-Path $WorkDir 'pbadfresh.json')
$r = Invoke-Budget $pBadFreshPath 'openai' $u2 $e2 $reqHash
Check '19 non-positive maxUsageAgeMinutes -> declined' ($r.code -eq 2 -and ($r.decision.reasons -join ';') -match 'maxUsageAgeMinutes') "code=$($r.code) out=$(Snip $r.out)"

# 20. Garbage / unparseable policy JSON -> declined, never a crash
$badJsonPath = Join-Path $WorkDir 'garbage.json'
Set-Content -LiteralPath $badJsonPath -Value 'not { json at all' -Encoding UTF8
$r = Invoke-Budget $badJsonPath 'openai' $u2 $e2 $reqHash
Check '20 unparseable policy JSON -> declined' ($r.code -eq 2 -and $r.decision.allowed -eq $false) "code=$($r.code) out=$(Snip $r.out)"

# --- cleanup: only the exact generated child directory this run created ------------------------
if (-not $existedBefore) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    $stillThere = Test-Path -LiteralPath $WorkDir
    Check '21 cleanup removed only the generated TEMP child' (-not $stillThere) "WorkDir=$WorkDir"
}
else {
    Write-Output "SKIP  21 cleanup check  (caller-supplied -WorkDir pre-existed, left in place)"
}

Write-Output ''
Write-Output "subscription_budget: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
