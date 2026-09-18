# Run canonical hook in child PowerShell with an isolated TEMP directory.
param([string]$Hook = (Join-Path $PSScriptRoot '../hooks/orchestrate_flag.ps1'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('orchestrate-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$dir = Join-Path $testRoot 'claude_orchestrator'
$pass = 0; $fail = 0
function Invoke-Hook([string]$prompt, [string]$agent = '', [string]$event = 'UserPromptSubmit', [string]$raw = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Hook`""
    $psi.EnvironmentVariables['TEMP'] = $testRoot
    $psi.EnvironmentVariables['TMP'] = $testRoot
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    if (-not $raw) { $raw = @{hook_event_name=$event; session_id='test'; prompt=$prompt; agent_id=$agent} | ConvertTo-Json -Compress }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($raw); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{code=$p.ExitCode; out=$out; err=$err}
}
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Output "PASS $name" } else { $script:fail++; Write-Output "FAIL $name" }
}
function Has([string]$suffix) { Test-Path -LiteralPath (Join-Path $dir "test.$suffix") }
function Reset-State {
    foreach ($suffix in @('on','off','reminded')) { Remove-Item -LiteralPath (Join-Path $dir "test.$suffix") -Force -ErrorAction SilentlyContinue }
}
try {
    $r = Invoke-Hook '/orchestrate on' 'worker'
    Check 'worker cannot create state directory' ($r.code -eq 0 -and -not (Test-Path $dir) -and -not $r.out)
    foreach ($command in @('/orchestrate','/orchestrate on','orchestrate this','orchestrate the work.','delegate this','delegate the work')) {
        Reset-State
        $r = Invoke-Hook $command
        Check "explicit ON: $command" ($r.code -eq 0 -and (Has 'on') -and -not (Has 'off') -and $r.out -match 'routing preference ON')
    }
    foreach ($command in @('/orchestrate off','go inline','work inline','stop orchestrating','do it yourself.')) {
        Invoke-Hook '/orchestrate on' | Out-Null
        $r = Invoke-Hook $command
        Check "explicit OFF: $command" ($r.code -eq 0 -and (Has 'off') -and -not (Has 'on'))
    }
    $ambiguous = @('Do not orchestrate this task.','Do not orchestrate this','Why does orchestrator mode block tiny edits?', 'Can you orchestrate this?', 'delegate this?', 'orchestrate this?', '"orchestrate this"', "'delegate this'", '`/orchestrate on`', '> /orchestrate on', 'The docs say /orchestrate on', '/orchestrate on please', "/orchestrate on`n/orchestrate off", 'orchestrate this but actually go inline', 'Do not stop orchestrating', 'Should I go inline?', 'The orchestrator failed', '/orchestrate status?')
    foreach ($prompt in $ambiguous) {
        Reset-State
        $r = Invoke-Hook $prompt
        Check "no inferred ON: $prompt" ($r.code -eq 0 -and -not (Has 'on') -and -not (Has 'off') -and $r.out -match '\[delegation\]')
    }
    Invoke-Hook '/orchestrate off' | Out-Null
    $off = Join-Path $dir 'test.off'
    (Get-Item $off).LastWriteTime = (Get-Date).AddDays(-30)
    $before = (Get-Item $off).LastWriteTimeUtc
    $r = Invoke-Hook '/orchestrate status'
    Check 'status preserves old explicit OFF' ((Has 'off') -and -not (Has 'on') -and (Get-Item $off).LastWriteTimeUtc -eq $before -and $r.out -match 'routing preference OFF')
    $r = Invoke-Hook 'Do not orchestrate this task.'
    Check 'neutral or negative prompt preserves explicit OFF' ((Has 'off') -and -not (Has 'on') -and (Get-Item $off).LastWriteTimeUtc -eq $before)
    $r = Invoke-Hook '/orchestrate on' 'worker'
    Check 'worker cannot override OFF or sweep old state' ((Has 'off') -and -not (Has 'on') -and (Get-Item $off).LastWriteTimeUtc -eq $before -and -not $r.out)
    $r = Invoke-Hook '/orchestrate on'
    Check 'explicit ON clears OFF' ((Has 'on') -and -not (Has 'off'))
    $on = Join-Path $dir 'test.on'
    $before = (Get-Item $on).LastWriteTimeUtc
    $r = Invoke-Hook '/orchestrate off' 'worker'
    Check 'worker cannot override ON' ((Has 'on') -and -not (Has 'off') -and (Get-Item $on).LastWriteTimeUtc -eq $before -and -not $r.out)
    $r = Invoke-Hook '/orchestrate status'
    Check 'status is read only while ON' ((Has 'on') -and (Get-Item $on).LastWriteTimeUtc -eq $before -and $r.out -match 'routing preference ON')
    $r = Invoke-Hook 'continue'
    Check 'per-prompt reminder prices whole remainder and every package' ($r.out -match 'remaining whole ask AND each package' -and $r.out -match 'startup/context.*brief.*execution.*review/integration.*rework' -and $r.out -match 'small work stays inline' -and $r.out -notmatch 'docs and CHECKPOINT only|every code change goes|build-shaped')
    foreach ($prompt in @('<task-notification>orchestrate this</task-notification>', '<agent-message>delegate this</agent-message>', 'Stop hook feedback orchestrate this', 'Goal check-in orchestrate this', '<system-reminder>orchestrate this</system-reminder>')) {
        $r = Invoke-Hook $prompt
        Check "harness prompt ignored: $prompt" ($r.code -eq 0 -and -not $r.out -and (Get-Item $on).LastWriteTimeUtc -eq $before)
    }
    $r = Invoke-Hook '/orchestrate off' '' 'PostToolUse'
    Check 'other events ignored' (-not $r.out -and (Has 'on'))
    $r = Invoke-Hook '' '' 'UserPromptSubmit' 'not json {{{'
    Check 'malformed input fails open' ($r.code -eq 0 -and -not $r.out)
    $r = Invoke-Hook ''
    Check 'empty prompt ignored' ($r.code -eq 0 -and -not $r.out)
}
finally {
    # Delete only this test's generated child of the system temp directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'orchestrate-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output "---- $pass passed, $fail failed ----"
if ($fail -gt 0) { exit 1 }
