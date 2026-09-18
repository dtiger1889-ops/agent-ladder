#requires -Version 5.1
# Provider-neutral subscription budget evaluator. Answers one question -- does a caller-supplied
# usage snapshot plus a caller-supplied request estimate clear a caller-supplied policy's thresholds
# -- for exactly one provider key at a time. No provider priority, no plan-to-token conversion, no
# launch detection and no permission override live here; those are adapter concerns (see
# codex_window_gate.ps1 for the one Claude-side adapter that calls this).
#
# Two ways to use this file:
#   1. Dot-source it (`. subscription_budget.ps1`) to load Get-SubscriptionBudgetDecision and
#      Get-Sha256HexLower into the caller's scope; no side effect happens on dot-source.
#   2. Run it directly as a CLI (`powershell -File subscription_budget.ps1 -PolicyPath ... -Provider
#      ... -UsagePath ... -EstimatePath ... -RequestHash ...`); prints {allowed, reasons} JSON to
#      stdout and exits 0 when allowed, 2 when declined (including on missing/invalid input -- this
#      is a decline, never an implicit allow).
#
# Schemas (both required, both fail closed when missing/stale/mismatched):
#   usage:    {provider, profileRevision, observedAt (UTC ISO), source, windows:{key:{usedPercent,
#              windowDurationMins, resetsAt (unix seconds)}}}
#   estimate: {provider, profileRevision, observedAt (UTC ISO), source, requestHash,
#              spendPercentPoints:{key: number}}
# Policy per provider: enabled, profileRevision, maxUsageAgeMinutes, maxEstimateAgeMinutes,
#   windows:{key:{windowDurationMins, minRemainingBefore, reserveAfter, maxJobPercentPoints}}.
# remaining = 100 - usedPercent. Require remaining >= minRemainingBefore,
# remaining - estimate >= reserveAfter, estimate <= maxJobPercentPoints, for every configured window.

param(
    [string]$PolicyPath,
    [string]$Provider,
    [string]$UsagePath,
    [string]$EstimatePath,
    [string]$RequestHash
)

function Get-Sha256HexLower {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally { $sha.Dispose() }
}

function ConvertTo-UtcDateTime {
    param([string]$Text)
    [DateTimeOffset]::Parse(
        $Text,
        [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    ).UtcDateTime
}

# Core evaluator. $Policy / $Usage / $Estimate are parsed objects (or $null); $Provider and
# $RequestHash are strings. Returns @{ allowed = [bool]; reasons = [string[]] }.
function Get-SubscriptionBudgetDecision {
    param(
        $Policy,
        [string]$Provider,
        $Usage,
        $Estimate,
        [string]$RequestHash
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $decline = { return @{ allowed = $false; reasons = @($reasons) } }

    if ($null -eq $Policy) { $reasons.Add('policy is missing'); return (& $decline) }
    if (-not ($Policy.PSObject.Properties.Name -contains 'version')) { $reasons.Add('policy version is missing'); return (& $decline) }
    $ver = [double]0
    if (-not [double]::TryParse([string]$Policy.version, [ref]$ver) -or $ver -ne 1) { $reasons.Add('policy version must be 1'); return (& $decline) }

    if ([string]::IsNullOrWhiteSpace($Provider)) { $reasons.Add('provider key is required'); return (& $decline) }
    if (-not $Policy.providers -or -not ($Policy.providers.PSObject.Properties.Name -contains $Provider)) {
        $reasons.Add("policy has no configuration for provider '$Provider'"); return (& $decline)
    }
    $prof = $Policy.providers.$Provider
    if (-not $prof.enabled) { $reasons.Add("policy disabled for provider '$Provider'"); return (& $decline) }
    if ([string]::IsNullOrWhiteSpace([string]$prof.profileRevision)) {
        $reasons.Add("profileRevision not configured for provider '$Provider'"); return (& $decline)
    }

    $maxUsageAge = [double]0
    if (-not ($prof.PSObject.Properties.Name -contains 'maxUsageAgeMinutes') -or
        -not [double]::TryParse([string]$prof.maxUsageAgeMinutes, [ref]$maxUsageAge) -or $maxUsageAge -le 0) {
        $reasons.Add('maxUsageAgeMinutes must be a positive number'); return (& $decline)
    }
    $maxEstimateAge = [double]0
    if (-not ($prof.PSObject.Properties.Name -contains 'maxEstimateAgeMinutes') -or
        -not [double]::TryParse([string]$prof.maxEstimateAgeMinutes, [ref]$maxEstimateAge) -or $maxEstimateAge -le 0) {
        $reasons.Add('maxEstimateAgeMinutes must be a positive number'); return (& $decline)
    }

    if (-not $prof.windows -or @($prof.windows.PSObject.Properties).Count -eq 0) {
        $reasons.Add('policy must configure at least one window'); return (& $decline)
    }
    $windowKeys = @($prof.windows.PSObject.Properties.Name)
    $windowCfg = @{}
    foreach ($k in $windowKeys) {
        $w = $prof.windows.$k
        $dur = [double]0; $minRem = [double]0; $reserve = [double]0; $cap = [double]0
        $okDur = ($w.PSObject.Properties.Name -contains 'windowDurationMins') -and [double]::TryParse([string]$w.windowDurationMins, [ref]$dur) -and $dur -gt 0
        $okMin = ($w.PSObject.Properties.Name -contains 'minRemainingBefore') -and ($null -ne $w.minRemainingBefore) -and
        [double]::TryParse([string]$w.minRemainingBefore, [ref]$minRem) -and $minRem -ge 0 -and $minRem -le 100
        $okRes = ($w.PSObject.Properties.Name -contains 'reserveAfter') -and ($null -ne $w.reserveAfter) -and
        [double]::TryParse([string]$w.reserveAfter, [ref]$reserve) -and $reserve -ge 0 -and $reserve -le 100
        $okCap = ($w.PSObject.Properties.Name -contains 'maxJobPercentPoints') -and ($null -ne $w.maxJobPercentPoints) -and
        [double]::TryParse([string]$w.maxJobPercentPoints, [ref]$cap) -and $cap -gt 0 -and $cap -le 100
        if (-not ($okDur -and $okMin -and $okRes -and $okCap)) {
            $reasons.Add("window '$k' is not fully configured (windowDurationMins/minRemainingBefore/reserveAfter/maxJobPercentPoints)")
            continue
        }
        $windowCfg[$k] = @{ durationMins = $dur; minRemainingBefore = $minRem; reserveAfter = $reserve; maxJobPercentPoints = $cap }
    }
    if ($reasons.Count -gt 0) { return (& $decline) }

    $now = [DateTime]::UtcNow
    $skewSec = 60

    if ($null -eq $Usage) { $reasons.Add('usage snapshot is missing'); return (& $decline) }
    if ([string]$Usage.provider -ne $Provider) { $reasons.Add('usage provider does not match requested provider') }
    if ([string]$Usage.profileRevision -ne [string]$prof.profileRevision) { $reasons.Add('usage profileRevision does not match policy profileRevision') }
    if ([string]::IsNullOrWhiteSpace([string]$Usage.source)) { $reasons.Add('usage source is missing') }
    $usageObservedAt = $null
    try { $usageObservedAt = ConvertTo-UtcDateTime ([string]$Usage.observedAt) }
    catch { $reasons.Add('usage observedAt is not a valid timestamp') }
    if ($null -ne $usageObservedAt) {
        if (($usageObservedAt - $now).TotalSeconds -gt $skewSec) { $reasons.Add('usage observedAt is in the future') }
        elseif (($now - $usageObservedAt).TotalMinutes -gt $maxUsageAge) { $reasons.Add('usage snapshot is stale') }
    }
    if ($reasons.Count -gt 0) { return (& $decline) }

    if ($null -eq $Estimate) { $reasons.Add('estimate is missing'); return (& $decline) }
    if ([string]$Estimate.provider -ne $Provider) { $reasons.Add('estimate provider does not match requested provider') }
    if ([string]$Estimate.profileRevision -ne [string]$prof.profileRevision) { $reasons.Add('estimate profileRevision does not match policy profileRevision') }
    if ([string]::IsNullOrWhiteSpace([string]$Estimate.source)) { $reasons.Add('estimate source is missing') }
    if ([string]::IsNullOrWhiteSpace([string]$Estimate.requestHash)) { $reasons.Add('estimate requestHash is missing') }
    elseif ([string]$Estimate.requestHash -ne $RequestHash) { $reasons.Add('estimate requestHash does not match this request') }
    $estObservedAt = $null
    try { $estObservedAt = ConvertTo-UtcDateTime ([string]$Estimate.observedAt) }
    catch { $reasons.Add('estimate observedAt is not a valid timestamp') }
    if ($null -ne $estObservedAt) {
        if (($estObservedAt - $now).TotalSeconds -gt $skewSec) { $reasons.Add('estimate observedAt is in the future') }
        elseif (($now - $estObservedAt).TotalMinutes -gt $maxEstimateAge) { $reasons.Add('estimate is stale') }
    }
    if ($reasons.Count -gt 0) { return (& $decline) }

    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($k in $windowKeys) {
        $cfg = $windowCfg[$k]
        $uw = $null
        if ($Usage.windows -and ($Usage.windows.PSObject.Properties.Name -contains $k)) { $uw = $Usage.windows.$k }
        if (-not $uw) { $reasons.Add("usage missing window '$k'"); continue }

        $usedPercent = [double]0
        if (-not [double]::TryParse([string]$uw.usedPercent, [ref]$usedPercent) -or $usedPercent -lt 0 -or $usedPercent -gt 100) {
            $reasons.Add("usage window '$k' usedPercent is missing or out of range"); continue
        }
        $uwDur = [double]0
        if (-not [double]::TryParse([string]$uw.windowDurationMins, [ref]$uwDur) -or $uwDur -ne $cfg.durationMins) {
            $reasons.Add("usage window '$k' windowDurationMins does not match policy"); continue
        }
        $resetsAt = [int64]0
        if (-not [int64]::TryParse([string]$uw.resetsAt, [ref]$resetsAt)) { $reasons.Add("usage window '$k' resetsAt is not a valid timestamp"); continue }
        if ($resetsAt -le $nowUnix) { $reasons.Add("usage window '$k' has already reset (resetsAt not in the future)"); continue }

        if (-not ($Estimate.spendPercentPoints -and ($Estimate.spendPercentPoints.PSObject.Properties.Name -contains $k))) {
            $reasons.Add("estimate missing spendPercentPoints for window '$k'"); continue
        }
        $spend = [double]0
        if (-not [double]::TryParse([string]$Estimate.spendPercentPoints.$k, [ref]$spend) -or $spend -le 0 -or $spend -gt 100) {
            $reasons.Add("estimate spendPercentPoints for window '$k' must be greater than 0 and at most 100"); continue
        }

        $remaining = 100.0 - $usedPercent
        if ($remaining -lt $cfg.minRemainingBefore) {
            $reasons.Add(("window '{0}' remaining {1} is below minRemainingBefore {2}" -f $k, $remaining, $cfg.minRemainingBefore))
        }
        if (($remaining - $spend) -lt $cfg.reserveAfter) {
            $reasons.Add(("window '{0}' remaining {1} minus estimate {2} is below reserveAfter {3}" -f $k, $remaining, $spend, $cfg.reserveAfter))
        }
        if ($spend -gt $cfg.maxJobPercentPoints) {
            $reasons.Add(("window '{0}' estimate {1} exceeds maxJobPercentPoints {2}" -f $k, $spend, $cfg.maxJobPercentPoints))
        }
    }

    return @{ allowed = ($reasons.Count -eq 0); reasons = @($reasons) }
}

# CLI mode only runs when -PolicyPath was actually bound (so dot-sourcing this file to reuse the
# functions above never triggers file I/O or an exit call).
if ($PSBoundParameters.ContainsKey('PolicyPath')) {
    try {
        $policy = $null; $usage = $null; $estimate = $null
        if (Test-Path -LiteralPath $PolicyPath) { $policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json }
        if ($UsagePath -and (Test-Path -LiteralPath $UsagePath)) { $usage = Get-Content -LiteralPath $UsagePath -Raw | ConvertFrom-Json }
        if ($EstimatePath -and (Test-Path -LiteralPath $EstimatePath)) { $estimate = Get-Content -LiteralPath $EstimatePath -Raw | ConvertFrom-Json }
        $decision = Get-SubscriptionBudgetDecision -Policy $policy -Provider $Provider -Usage $usage -Estimate $estimate -RequestHash $RequestHash
    }
    catch {
        $decision = @{ allowed = $false; reasons = @("invalid input: $($_.Exception.Message)") }
    }
    ($decision | ConvertTo-Json -Depth 6 -Compress) | Write-Output
    if ($decision.allowed) { exit 0 } else { exit 2 }
}
