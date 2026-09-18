#requires -Version 5.1
# PreToolUse (Bash|PowerShell|Agent) adapter: classifies actual Codex CLI launches (a shell
# invocation of the codex binary, or an Agent call whose subagent_type names codex) and asks the
# provider-neutral subscription budget evaluator (subscription_budget.ps1, dot-sourced from this
# file's own directory) whether the OpenAI-side window budget allows it. Cheap probes
# (--version/--help/login status) are exempt and mere mentions of "codex" in text/paths are not
# launches. This adapter intercepts CLAUDE-SIDE Codex launches only -- other providers/runtimes call
# subscription_budget.ps1 directly.
#
# Deploy this beside subscription_budget.ps1 and a filled-in agent-ladder-policy.json in your hooks
# directory (e.g. ~/.claude/hooks), then wire the PreToolUse (Bash|PowerShell|Agent) registration.
# See subscription-routing.md for the policy/usage/estimate schemas and setup steps.
#
# Defaults (each overridable by env var, for tests or a portable install):
#   policy   -> sibling agent-ladder-policy.json          (env AGENT_LADDER_POLICY_PATH)
#   usage    -> sibling agent-ladder-usage.json            (env AGENT_LADDER_USAGE_PATH)
#   estimate -> $env:TEMP/agent_ladder_estimates/<session>.json (env AGENT_LADDER_ESTIMATE_PATH)
#
# Exact request hash: lowercase SHA256 (UTF8) of the shell command line for Bash/PowerShell, or of
# "<subagent_type>\n<prompt>" for an Agent call. A decline names the expected hash so the calling
# agent can write a scoped estimate at the estimate path and retry. No prompt word waives this.

$RealSubcommands = @('exec', 'app-server', 'apply', 'resume', 'cloud', 'mcp', 'proto')
$Provider = 'openai'

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
    foreach ($seg in ($cmd -split '(\|\||&&|;|&|\||\r|\n)')) {
        $s = $seg.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $s = $s -replace '^\s*&\s*', ''
        while ($s -match '^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+') { $s = $s -replace '^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+', '' }
        $s = $s.TrimStart('"', "'", '(').Trim()
        # documented shim shape: "<stdin>" | & $codex exec --skip-git-repo-check -s workspace-write ...
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

function Get-EnvOrDefault([string]$envName, [string]$default) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    return $default
}

$target = $null
$probeOnly = $false
$requestHashInput = $null
$sid = $null

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $tool = "$($j.tool_name)"

    if ($tool -eq 'Bash' -or $tool -eq 'PowerShell') {
        $cmd = [string]$j.tool_input.command
        $po = $false
        if (Test-InvokesCodex $cmd ([ref]$po)) {
            $target = 'codex'
            $probeOnly = $po
            $requestHashInput = $cmd
        }
    }
    elseif ($tool -eq 'Agent') {
        $sub = [string]$j.tool_input.subagent_type
        if ($sub -match '(?i)codex') {
            $target = "the $sub agent"
            $prompt = [string]$j.tool_input.prompt
            $requestHashInput = "$sub`n$prompt"
        }
    }
    if (-not $target) { exit 0 }
    if ($probeOnly) { exit 0 }

    $sidRaw = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sidRaw)) { $sidRaw = 'nosession' }
    $sid = ($sidRaw -replace '[^A-Za-z0-9_.-]', '_')
}
catch {
    # Parse/input errors on unknown classification fail open -- unrelated tools are never affected.
    exit 0
}

# From here on this is a classified, non-probe Codex handoff: any failure below declines rather
# than fails open, per the rule that missing/corrupt helper or policy declines only classified
# Codex handoffs.
try {
    # subscription_budget.ps1 declares its own -Provider param; dot-sourcing it rebinds any
    # variable of that name in this scope to $null, so re-set $Provider immediately after.
    . (Join-Path $PSScriptRoot 'subscription_budget.ps1')
    $Provider = 'openai'
    $requestHash = Get-Sha256HexLower $requestHashInput

    $PolicyPath = Get-EnvOrDefault 'AGENT_LADDER_POLICY_PATH' (Join-Path $PSScriptRoot 'agent-ladder-policy.json')
    $UsagePath = Get-EnvOrDefault 'AGENT_LADDER_USAGE_PATH' (Join-Path $PSScriptRoot 'agent-ladder-usage.json')
    $defaultEstimatePath = Join-Path (Join-Path $env:TEMP 'agent_ladder_estimates') "$sid.json"
    $EstimatePath = Get-EnvOrDefault 'AGENT_LADDER_ESTIMATE_PATH' $defaultEstimatePath

    $policy = $null; $usage = $null; $estimate = $null
    if (Test-Path -LiteralPath $PolicyPath) { $policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json }
    if (Test-Path -LiteralPath $UsagePath) { $usage = Get-Content -LiteralPath $UsagePath -Raw | ConvertFrom-Json }
    if (Test-Path -LiteralPath $EstimatePath) { $estimate = Get-Content -LiteralPath $EstimatePath -Raw | ConvertFrom-Json }

    $decision = Get-SubscriptionBudgetDecision -Policy $policy -Provider $Provider -Usage $usage -Estimate $estimate -RequestHash $requestHash

    if ($decision.allowed) {
        $msg = "[codex-window-gate] Subscription budget preflight passed for {0} (provider={1})." -f $target, $Provider
        Write-Output $msg
        exit 0
    }

    $reasonsTxt = ($decision.reasons -join '; ')
    $msg = "[codex-window-gate] BLOCKED: subscription budget preflight declined this handoff to {0} (provider={1}). " -f $target, $Provider
    $msg += "Reasons: $reasonsTxt. "
    $msg += "Expected request hash for a scoped estimate at ${EstimatePath}: $requestHash. "
    $msg += "DO NOT retry this call as-is. Run the work on the Claude side, or write a fresh usage/estimate snapshot matching that hash and retry. Only the user can wave this through."
    [Console]::Error.WriteLine($msg)
    exit 2
}
catch {
    $msg = "[codex-window-gate] BLOCKED: the subscription budget helper or policy could not be loaded ($($_.Exception.Message)) for a classified Codex handoff to $target. DO NOT retry this call."
    [Console]::Error.WriteLine($msg)
    exit 2
}
