#requires -Version 5.1
# PreToolUse (Bash|PowerShell|Agent): a "look before you delegate" check for a Codex handoff,
# made mechanical. The rule: do not start a Codex task when the 5-hour window is over its
# used-percent limit or the weekly window over its own. The motivating incident: a job launched
# at 92 percent on the 5-hour window hit the cap after ~3 minutes and wasted its whole run.
#
# Where the numbers come from: Codex writes its own rate-limit snapshot into every rollout log at
# ~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl. Each "rate_limits" object carries
# primary (window_minutes 300 = the 5-hour window) and secondary (window_minutes 10080 = weekly),
# each with used_percent and resets_at (epoch seconds). The newest snapshot whose window has not
# already reset is the live figure; a window past its resets_at reads as unknown, never as zero.
#
# Behavior: blocks (exit 2) only on a KNOWN breach. Unknown state is never a block -- it prints a
# once-per-session advisory naming the rule and exits 0. A codex --version / --help / login status
# probe is never gated. Fails open on any error.
#
# TUNABLE thresholds (the config-driven "new system"): each window's used-percent limit is read from
# agent-ladder-policy.json -> providers.openai.windows.<fiveHour|weekly>.maxUsedPercent. Edit that
# file to change a limit; env AGENT_LADDER_POLICY_PATH overrides the path (tests use this). A missing
# or unreadable file keeps the safe defaults below (5-hour 70, weekly 75) so the gate still gates.

$Primary5hLimit = 70.0
$WeeklyLimit = 75.0
$policyPath = $env:AGENT_LADDER_POLICY_PATH
if ([string]::IsNullOrWhiteSpace($policyPath)) { $policyPath = Join-Path $PSScriptRoot 'agent-ladder-policy.json' }
try {
    if (Test-Path -LiteralPath $policyPath) {
        $oaWin = (Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json).providers.openai.windows
        if ($null -ne $oaWin.fiveHour.maxUsedPercent) { $Primary5hLimit = [double]$oaWin.fiveHour.maxUsedPercent }
        if ($null -ne $oaWin.weekly.maxUsedPercent) { $WeeklyLimit = [double]$oaWin.weekly.maxUsedPercent }
    }
}
catch { }  # unreadable / invalid config keeps the safe defaults above -- never fail toward "no limit"
$RealSubcommands = @('exec', 'app-server', 'apply', 'resume', 'cloud', 'mcp', 'proto')

# True when the args after the codex executable are only a cheap probe (version/help/login status).
function Test-CodexProbe([string]$rest) {
    $t = $rest.Trim()
    if ($t -eq '') { return $false }
    $tokens = @($t -split '\s+' | Where-Object { $_ -ne '' })
    $first = $tokens[0].Trim('"', "'")
    if ($RealSubcommands -contains $first.ToLower()) { return $false }
    if ($first -match '(?i)^(--version|-V|--help|-h|help|completion)$') { return $true }
    if ($first -match '(?i)^login$') { return $true }
    return $false
}

# True when the command line actually INVOKES codex (not merely mentions it in text or a path).
function Test-InvokesCodex([string]$cmd, [ref]$probeOnly) {
    $probeOnly.Value = $false
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    $found = $false
    $allProbes = $true
    # Blank out quoted spans (length preserved) BEFORE splitting on shell separators, so pipes/
    # semicolons INSIDE quotes -- e.g. the alternation in a grep pattern "a|b/codex" -- cannot break
    # the line into phantom segments. Without this a quoted token ending in "/codex" was misread as a
    # codex invocation and the handoff was wrongly blocked. Real launches (codex ..., & $codex exec)
    # sit OUTSIDE quotes and survive the blanking.
    $masked = [regex]::Replace($cmd, '"[^"]*"', { param($m) ' ' * $m.Value.Length })
    $masked = [regex]::Replace($masked, "'[^']*'", { param($m) ' ' * $m.Value.Length })
    foreach ($seg in ($masked -split '(\|\||&&|;|&|\||\r|\n)')) {
        $s = $seg.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        # strip a leading call operator, leading env assignments, and opening quote/paren
        $s = $s -replace '^\s*&\s*', ''
        while ($s -match '^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+') { $s = $s -replace '^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+', '' }
        $s = $s.TrimStart('"', "'", '(').Trim()
        # the notes' documented shape: "<stdin>" | & $codex exec --skip-git-repo-check -s workspace-write ...
        if ($s -match '^(\$\w+|\$\{[^}]+\})\s+exec(\s|$)') {
            $found = $true
            $allProbes = $false
            continue
        }
        $m = [regex]::Match($s, '^(?<exe>[^\s"'']+)')
        if (-not $m.Success) { continue }
        $exe = $m.Groups['exe'].Value.Trim('"', "'")
        $leaf = ($exe -split '[\\/]')[-1]
        if ($leaf -notmatch '(?i)^codex(\.exe|\.cmd|\.bat|\.ps1)?$') { continue }
        $found = $true
        $rest = $s.Substring($m.Length)
        if (-not (Test-CodexProbe $rest)) { $allProbes = $false }
    }
    if ($found -and $allProbes) { $probeOnly.Value = $true }
    return $found
}

# Newest usable rate-limit snapshot from the Codex rollout logs.
function Get-CodexWindows {
    $root = Join-Path $env:USERPROFILE '.codex\sessions'
    if ($env:CODEX_WINDOW_GATE_SESSIONS) { $root = $env:CODEX_WINDOW_GATE_SESSIONS }
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $files = Get-ChildItem -LiteralPath $root -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 12
    $now = [int64][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($f in $files) {
        $line = $null
        try {
            $hits = @(Select-String -LiteralPath $f.FullName -Pattern '"rate_limits"\s*:\s*\{' -ErrorAction Stop)
            if ($hits.Count -gt 0) { $line = $hits[-1].Line }
        } catch { continue }
        if (-not $line) { continue }
        $p = [regex]::Match($line, '"primary"\s*:\s*\{[^}]*?"used_percent"\s*:\s*(?<v>[0-9.]+)[^}]*?"resets_at"\s*:\s*(?<r>[0-9]+)')
        $s = [regex]::Match($line, '"secondary"\s*:\s*\{[^}]*?"used_percent"\s*:\s*(?<v>[0-9.]+)[^}]*?"resets_at"\s*:\s*(?<r>[0-9]+)')
        if (-not $p.Success -and -not $s.Success) { continue }
        $res = @{ primary = $null; weekly = $null; source = $f.FullName }
        if ($p.Success -and ([int64]$p.Groups['r'].Value) -gt $now) { $res.primary = [double]$p.Groups['v'].Value }
        if ($s.Success -and ([int64]$s.Groups['r'].Value) -gt $now) { $res.weekly = [double]$s.Groups['v'].Value }
        if ($null -eq $res.primary -and $null -eq $res.weekly) { continue }
        return $res
    }
    return $null
}

# True when this session was already advised (the advisory fires at most once).
function Test-AdvisedOnce([string]$sid) {
    $dir = Join-Path $env:TEMP 'claude_codex_window_gate'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $flag = Join-Path $dir (($sid + '.advised') -replace '[^A-Za-z0-9_.-]', '_')
    if (Test-Path -LiteralPath $flag) { return $true }
    New-Item -ItemType File -Path $flag -Force | Out-Null
    return $false
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $tool = "$($j.tool_name)"

    $target = $null
    $probeOnly = $false
    if ($tool -eq 'Bash' -or $tool -eq 'PowerShell') {
        $cmd = [string]$j.tool_input.command
        $po = $false
        if (Test-InvokesCodex $cmd ([ref]$po)) { $target = 'codex'; $probeOnly = $po }
    }
    elseif ($tool -eq 'Agent') {
        $sub = [string]$j.tool_input.subagent_type
        if ($sub -match '(?i)codex') { $target = "the $sub agent" }
    }
    if (-not $target) { exit 0 }
    if ($probeOnly) { exit 0 }

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'nosession' }

    $w = Get-CodexWindows
    if ($null -eq $w) {
        if (Test-AdvisedOnce $sid) { exit 0 }
        $adv = ("[codex-window-gate] No live Codex usage snapshot on disk, so the two windows could not be read. " +
            "This fires once per session and the call was NOT blocked. " +
            "Look at both windows before delegating, and do not " +
            "start a Codex task above {0} percent used on the 5-hour window or {1} percent on the weekly one. " +
            "Keep the handoff bounded: name the input files and grep instead of reading whole " +
            "packages, keep reasoning at medium, and make the job write its deliverable early under a timeout.") -f $Primary5hLimit, $WeeklyLimit
        Write-Output $adv
        exit 0
    }

    $breach = @()
    if ($null -ne $w.primary -and $w.primary -gt $Primary5hLimit) {
        $breach += ("the 5-hour window is at {0} percent used, over the {1} percent limit" -f $w.primary, $Primary5hLimit)
    }
    if ($null -ne $w.weekly -and $w.weekly -gt $WeeklyLimit) {
        $breach += ("the weekly window is at {0} percent used, over the {1} percent limit" -f $w.weekly, $WeeklyLimit)
    }

    if ($breach.Count -gt 0) {
        $msg = "[codex-window-gate] BLOCKED: " + ($breach -join ' and ') + ". " +
        "Do not start a Codex task over the configured 5-hour or weekly " +
        "used-percent limits. Motivating incident: a job launched at 92 " +
        "percent hit the 5-hour cap after ~3 minutes and wasted its entire run. " +
        "DO NOT retry this call. Run the work on the other agent instead, or note which window you are waiting on " +
        "and when it resets. Only the user can wave this through."
        [Console]::Error.WriteLine($msg)
        exit 2
    }

    if (Test-AdvisedOnce $sid) { exit 0 }
    if ($null -ne $w.primary) { $pTxt = "{0} percent" -f $w.primary } else { $pTxt = 'unknown, that window already reset' }
    if ($null -ne $w.weekly) { $sTxt = "{0} percent" -f $w.weekly } else { $sTxt = 'unknown, that window already reset' }
    $info = "[codex-window-gate] Codex budget before delegating to {0}: 5-hour window {1} used, weekly window {2} used. " -f $target, $pTxt, $sTxt
    $info += "Both under the configured thresholds, so this went through. Fires once per session. " +
    "The rest is on you, not the hook: name the input files in the spec and grep instead of reading whole packages, " +
    "keep reasoning at medium, and make the job write its deliverable early under a timeout. " +
    "Roughly 50k fresh tokens costs about one point of the weekly hundred, and reading a whole package once is about that much."
    Write-Output $info
    exit 0
}
catch {
    exit 0
}
