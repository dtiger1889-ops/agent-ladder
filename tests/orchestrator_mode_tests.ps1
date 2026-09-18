# Tests canonical source using child processes with isolated TEMP (never live hook state).
param([string]$HookRoot = (Join-Path $PSScriptRoot '../hooks'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('ladder-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$orch = Join-Path $testRoot 'claude_orchestrator'
$gate = Join-Path $testRoot 'claude_delegation_gate'
[void][IO.Directory]::CreateDirectory($orch)
[void][IO.Directory]::CreateDirectory($gate)
$pass = 0
function Check($name, $condition) {
    if (-not $condition) { throw "FAIL $name" }
    $script:pass++; Write-Host "PASS $name"
}
function Run($which, $sid, $tool = 'Write', $body = 'x', $worker = '') {
    $payload = @{ session_id=$sid; tool_name=$tool; tool_input=@{file_path='project/main.py';content=$body;new_string=$body;command=$body;edits=@(@{new_string=$body})}}
    if ($worker) { $payload.agent_id = $worker }
    Raw $which ($payload | ConvertTo-Json -Compress -Depth 6)
}
function Raw($which, $json) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $HookRoot ($which + '.ps1'))`""
    $psi.UseShellExecute=$false
    $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['TEMP']=$testRoot; $psi.EnvironmentVariables['TMP']=$testRoot
    $p=[Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    Check "$which exit zero" ($p.ExitCode -eq 0 -and -not $err)
    if ($out) {
        $parsed=$out | ConvertFrom-Json
        Check 'structured context only, no deny decision' ($parsed.hookSpecificOutput.additionalContext -match 'total handoff cost' -and -not $parsed.decision -and -not $parsed.hookSpecificOutput.permissionDecision)
    }
    return $out
}
function Marker($sid,$kind) { Set-Content -LiteralPath (Join-Path $orch "$sid.$kind") -Value '1' }
function Count($sid,$n) { Set-Content -LiteralPath (Join-Path $gate "$sid.count") -Value $n }
try {
    $pre='orchestrator_mode'; $post='delegation_gate'
    Check 'small ordinary Write silent' (-not (Run $pre 'small'))
    Marker 'one' 'on'
    Check 'one-line Write allowed with reminder' ((Run $pre 'one') -match 'Keep small work inline')
    Check 'same session reminder only once' (-not (Run $pre 'one'))
    foreach ($tool in @('Edit','MultiEdit')) {
        Marker $tool 'on'
        Check "$tool 41+ lines allowed" ((Run $pre $tool $tool ((1..50) -join "`n")) -match 'Routing cost check')
    }
    Marker 'shell' 'on'
    foreach ($command in @('echo x > main.py', ('python - <<PY' + "`n" + "open('main.py').read()" + "`nPY"))) {
        Check 'shell write/read silently allowed' (-not (Run $pre 'shell' 'Bash' $command))
    }
    Check 'PowerShell silently allowed' (-not (Run $pre 'shell' 'PowerShell' "Set-Content main.py x"))
    Check 'Read silently allowed' (-not (Run $pre 'shell' 'Read'))
    Count 'threshold' 150
    Check '150 triggers nonblocking reminder' ((Run $pre 'threshold') -match 'Routing cost check')
    Check 'threshold never creates on' (-not (Test-Path (Join-Path $orch 'threshold.on')))
    Marker 'off' 'off'; Marker 'off' 'on'; Count 'off' 700
    Check 'off overrides on and count' (-not (Run $pre 'off'))
    Check 'post off suppresses reminder' (-not (Run $post 'off'))
    Marker 'worker' 'on'; Count 'worker' 599
    Check 'worker pre silent' (-not (Run $pre 'worker' 'Write' 'x' 'worker-id'))
    Check 'worker post silent' (-not (Run $post 'worker' 'Write' ((1..700) -join "`n") 'worker-id'))
    Check 'worker never changes main counter' ((Get-Content (Join-Path $gate 'worker.count')) -eq '599')
    Check 'worker without counter silent' (-not (Run $post 'new-worker' 'Write' 'x' 'id'))
    Check 'worker creates no counter' (-not (Test-Path (Join-Path $gate 'new-worker.count')))
    Check 'post threshold reminder' ((Run $post 'post-first' 'Write' ((1..600) -join "`n")) -match 'heuristic')
    Check 'post repeat silent' (-not (Run $post 'post-first'))
    Check 'post then pre deduplicated' (-not (Run $pre 'post-first'))
    Count 'one' 599
    Check 'pre then post deduplicated' (-not (Run $post 'one'))
    Check 'read-only shell not counted' (-not (Run $post 'read-shell' 'Bash' "python - <<PY`nopen('main.py').read()`nPY"))
    Check 'read-only shell creates no counter' (-not (Test-Path (Join-Path $gate 'read-shell.count')))
    Check 'small shell write not nagged' (-not (Run $post 'small-shell' 'Bash' "cat <<EOF > main.py`nx`nEOF"))
    Check 'small shell heuristic count' ((Get-Content (Join-Path $gate 'small-shell.count')) -eq '1')
    foreach ($which in @($pre,$post)) {
        Check 'malformed fails open' (-not (Raw $which '{bad'))
        Check 'missing session fails open' (-not (Raw $which '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"x"}}'))
        Check 'empty fails open' (-not (Raw $which ''))
    }
    Count 'corrupt' 'broken'
    Check 'corrupt counter fails open pre' (-not (Run $pre 'corrupt'))
    Check 'corrupt counter fails open post' (-not (Run $post 'corrupt'))
    Write-Output "$pass checks passed"
} finally {
    $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath.TrimEnd('\', '/')
    $parent = Split-Path -Parent $resolvedRoot
    $leaf = Split-Path -Leaf $resolvedRoot
    if (-not $parent.Equals($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^ladder-tests-[a-f0-9]{32}$' -or
        ((Get-Item -LiteralPath $resolvedRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing cleanup outside the generated TEMP test directory: $resolvedRoot"
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
