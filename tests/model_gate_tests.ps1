# Wrapper tests for hooks/model_gate.ps1 in this repository -- runs the hook exactly as Claude Code does
# (powershell.exe -NoProfile -ExecutionPolicy Bypass -File <hook>, JSON on stdin) and checks exit code + output.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File model_gate_tests.ps1
$hook = Join-Path $PSScriptRoot '..\hooks\model_gate.ps1'

function Invoke-Hook([string]$json, [string]$userHome = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # $userHome: point the hook's USERPROFILE at a temp home so its agents folder is a temp one (effort tests).
    if ($userHome -ne '') { $psi.EnvironmentVariables['USERPROFILE'] = $userHome }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out; err = $err }
}

function AgentJson($toolInput, [string]$sid = 'mgtest-1', [string]$cwd = 'C:\path\to\repo') {
    return (@{ hook_event_name = 'PreToolUse'; tool_name = 'Agent'; session_id = $sid; cwd = $cwd; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 6)
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

# 4. model sonnet -> 0 (effort passed so the effort check stays out of the way)
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'sonnet'; effort = 'low' })
Check '4 model sonnet passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 5. model opus with subagent_type claude-code-guide -> 0
$r = Invoke-Hook (AgentJson @{ description = 'do a thing'; prompt = 'go do it'; model = 'opus'; subagent_type = 'claude-code-guide'; effort = 'low' })
Check '5 model opus with subagent_type passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 6. malformed JSON -> 0
$r = Invoke-Hook 'this is not json'
Check '6 malformed JSON passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 7. tool_name Bash with no model -> 0 (only Agent is gated)
$r = Invoke-Hook (BashJson @{ command = 'ls -la' })
Check '7 non-Agent tool with no model passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"

# 8. effort check: a non-fork spawn with no `effort` whose agent definition is missing or has no frontmatter
# `effort:` is blocked once per session. Fresh session ids; a temp USERPROFILE and a temp project folder
# hold the definitions, so no real agents folder is touched.
function NewSid { return ('mgtest-eff-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('mgtest-home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$tmpAgents = Join-Path $tmpRoot '.claude\agents'
$tmpProject = Join-Path $tmpRoot 'project'
$tmpProjectAgents = Join-Path $tmpProject '.claude\agents'
New-Item -ItemType Directory -Path $tmpAgents -Force | Out-Null
New-Item -ItemType Directory -Path $tmpProjectAgents -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $tmpAgents 'worker.md'), "---`nname: worker`nmodel: sonnet`neffort: medium`n---`nbody`n")
[IO.File]::WriteAllText((Join-Path $tmpAgents 'bodyonly.md'), "---`nname: bodyonly`nmodel: sonnet`n---`nRun this at`neffort: high`nplease`n")
[IO.File]::WriteAllText((Join-Path $tmpProjectAgents 'projworker.md'), "---`nname: projworker`nmodel: sonnet`neffort: low`n---`nbody`n")
$s8 = NewSid
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'general-purpose' } $s8) $tmpRoot
Check '8a general-purpose with no effort is blocked once' ($r.code -eq 2 -and $r.err -match 'no effort level of its own') "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'general-purpose' } $s8) $tmpRoot
Check '8b same session, second such spawn passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'general-purpose'; effort = 'low' } (NewSid)) $tmpRoot
Check '8c general-purpose with effort low passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'worker' } (NewSid)) $tmpRoot
Check '8d user-level definition with frontmatter effort passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'projworker' } (NewSid) $tmpProject) $tmpRoot
Check '8e project-level definition with frontmatter effort passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'fork' } (NewSid)) $tmpRoot
Check '8f fork with no effort passes' ($r.code -eq 0) "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'no-such-agent' } (NewSid)) $tmpRoot
Check '8g missing definition with no effort is blocked' ($r.code -eq 2 -and $r.err -match 'no effort level of its own') "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet'; subagent_type = 'bodyonly' } (NewSid)) $tmpRoot
Check '8h definition whose only effort: line is in the body is blocked' ($r.code -eq 2 -and $r.err -match 'no effort level of its own') "code=$($r.code) err=$($r.err)"
$r = Invoke-Hook (AgentJson @{ description = 'x'; prompt = 'x'; model = 'sonnet' } (NewSid)) $tmpRoot
Check '8i no subagent_type counts as general-purpose and is blocked' ($r.code -eq 2 -and $r.err -match 'no effort level of its own') "code=$($r.code) err=$($r.err)"
# Delete only the temp folder this test created.
$resolvedRoot = [IO.Path]::GetFullPath($tmpRoot)
if ($resolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedRoot) -like 'mgtest-home-*') {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

Write-Output "---- $pass passed, $fail failed ----"
if ($fail -gt 0) { exit 1 } else { exit 0 }
