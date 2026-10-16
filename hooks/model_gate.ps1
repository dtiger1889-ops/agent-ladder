#requires -Version 5.1
# model_gate.ps1 -- PreToolUse HARD block on the Agent tool when the spawn does not name a model, or
# names haiku. Motivation: agent-ladder.md model-selection principle 5, "Name the model on every
# delegated spawn" (owner decision 2026-09-16, see HISTORY.md), and the never-Haiku-for-real-work
# rule (2026-07-09 review, HISTORY.md); the 2026-09-18 transcript audit (HISTORY.md, "The audit and
# the hooks (2026-09-18)") found all ten Haiku subagent runs on disk were unnamed claude-code-guide spawns, two of which
# produced false "not possible" capability claims the owner had to correct.
#
# This hook BLOCKS rather than rewrites the model: Claude Code ignores `updatedInput` for the Agent tool
# (anthropics/claude-code issue 44412), so there is no way to silently fix the spawn from a hook -- the
# only lever is refuse-and-say. Structure: read stdin JSON, try/catch, fail OPEN (exit 0) on any error,
# never write to the transcript.
#
# The model checks are HARD blocks, not block-once: they fire on every unnamed or Haiku spawn, every time,
# with no state file. The effort check below is the one block-once check.
#
# Registered for PreToolUse, matcher "Agent".
# Tests: tests/model_gate_tests.ps1. Built 2026-09-18.
#
# Second check, added 2026-10-16 (agent-ladder.md model-selection principle 6; HISTORY.md, "Effort, not
# just the model (2026-10-16)"): a helper with no effort level of its own runs at its parent session's
# level. A spawn that is not a `fork`, passes no `effort`, and whose agent definition is missing or has
# no `effort:` key inside its frontmatter (the block between the first two `---` lines) is blocked ONCE
# per session (state %TEMP%\model_gate_effort_<sid>.flag); re-issuing passes. Definitions are looked up
# in the project's .claude\agents (from the hook's cwd) and in %USERPROFILE%\.claude\agents; an empty
# subagent_type counts as general-purpose, which has no definition file. Fails open on any error.

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $tool = "$($j.tool_name)"

    if ($tool -ne 'Agent') { exit 0 }

    $m = "$($j.tool_input.model)".Trim()

    if ([string]::IsNullOrWhiteSpace($m)) {
        $msg = '[model-gate] Agent spawn refused: no model named. agent-ladder.md, model-selection principle 5: every spawn names its model. ' +
               'Re-issue with model: sonnet (mechanical/bulk), opus (default for most packages) or fable. Built-in types ' +
               '(claude-code-guide, Explore, Plan) default to Haiku or inherit; name it anyway.'
        [Console]::Error.WriteLine($msg)
        exit 2
    }

    if ($m -match '^(?i)haiku') {
        $msg = '[model-gate] Agent spawn refused: haiku is excluded from real work (HISTORY.md, ' +
               '2026-07-09 review; two false capability claims traced to Haiku doc lookups on 2026-09-18). Use sonnet.'
        [Console]::Error.WriteLine($msg)
        exit 2
    }

    # Effort check: block once per session when the helper would silently run at the session's effort.
    $eff = "$($j.tool_input.effort)".Trim()
    $type = "$($j.tool_input.subagent_type)".Trim()
    if ($type -eq '') { $type = 'general-purpose' }
    if ($type -ne 'fork' -and [string]::IsNullOrWhiteSpace($eff)) {
        $hasEffort = $false
        if ($type -match '^[A-Za-z0-9_.-]+$' -and $type -notmatch '\.\.') {
            $dirs = @()
            $cwd = "$($j.cwd)".Trim()
            if ($cwd -ne '') { $dirs += (Join-Path $cwd '.claude\agents') }
            if ($env:USERPROFILE) { $dirs += (Join-Path $env:USERPROFILE '.claude\agents') }
            foreach ($d in $dirs) {
                $agentFile = Join-Path $d ($type + '.md')
                if (-not (Test-Path -LiteralPath $agentFile -PathType Leaf)) { continue }
                $n = 0
                foreach ($ln in (Get-Content -LiteralPath $agentFile -TotalCount 60)) {
                    $n++
                    if ($n -eq 1) { if ($ln.Trim() -ne '---') { break } else { continue } }
                    if ($ln.Trim() -eq '---') { break }
                    if ($ln -match '^effort:\s*\S') { $hasEffort = $true; break }
                }
                break
            }
        }
        if (-not $hasEffort) {
            $safeSid = ("$($j.session_id)" -replace '[^A-Za-z0-9_-]', '_')
            $flag = Join-Path $env:TEMP ('model_gate_effort_' + $safeSid + '.flag')
            if (-not (Test-Path -LiteralPath $flag)) {
                try { Set-Content -LiteralPath $flag -Value '1' -ErrorAction SilentlyContinue } catch {}
                $msg = '[model-gate] Agent spawn blocked once: this agent type has no effort level of its own and the spawn passed none, ' +
                       'so it would run at this session''s effort. Re-issue with an effort level (agent-ladder.md, model-selection principle 6), ' +
                       'or add `effort:` to that agent''s definition; this fires once per session.'
                [Console]::Error.WriteLine($msg)
                exit 2
            }
        }
    }

    exit 0
}
catch {
    exit 0
}
