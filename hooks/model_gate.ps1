#requires -Version 5.1
# model_gate.ps1 -- PreToolUse HARD block on the Agent tool when the spawn does not name a model, or
# names haiku. Motivation: the workspace instructions "Every delegated spawn names its model explicitly"
# (owner decision 2026-09-16, decision board) and agent-ladder.md's never-Haiku-for-real-work
# rule (2026-07-09 pass); the 2026-09-18 transcript audit (HISTORY.md (2026-09-18 audit)
# section 4) found all ten Haiku subagent runs on disk were unnamed claude-code-guide spawns, two of which
# produced false "not possible" capability claims the owner had to correct.
#
# This hook BLOCKS rather than rewrites the model: Claude Code ignores `updatedInput` for the Agent tool
# (anthropics/claude-code issue 44412), so there is no way to silently fix the spawn from a hook -- the
# only lever is refuse-and-say. Mirrors the structure of ~/.claude/hooks/question_guard.ps1: read stdin
# JSON, try/catch, fail OPEN (exit 0) on any error, never write to the transcript.
#
# This is a HARD block, not block-once: fires on every unnamed or Haiku spawn, every time, no state file.
#
# Registered for PreToolUse, matcher "Agent".
# Tests: tests/model_gate_tests.ps1. Built 2026-09-18.

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $tool = "$($j.tool_name)"

    if ($tool -ne 'Agent') { exit 0 }

    $m = "$($j.tool_input.model)".Trim()

    if ([string]::IsNullOrWhiteSpace($m)) {
        $msg = '[model-gate] Agent spawn refused: no model named. Workspace rule (2026-09-16): every spawn names its model. ' +
               'Re-issue with model: sonnet (mechanical/bulk), opus (ships or user-facing) or fable. Built-in types ' +
               '(claude-code-guide, Explore, Plan) default to Haiku or inherit; name it anyway.'
        [Console]::Error.WriteLine($msg)
        exit 2
    }

    if ($m -match '^(?i)haiku') {
        $msg = '[model-gate] Agent spawn refused: haiku is excluded from real work (agent-ladder.md, ' +
               '2026-07-09 pass; two false capability claims traced to Haiku doc lookups on 2026-09-18). Use sonnet.'
        [Console]::Error.WriteLine($msg)
        exit 2
    }

    exit 0
}
catch {
    exit 0
}
