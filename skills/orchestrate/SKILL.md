---
name: orchestrate
description: Set this Claude Code session's cost-aware delegation preference with /orchestrate on, /orchestrate off, /orchestrate status, or /orchestrate <task> (ON plus delegate that task now). Inline changes remain allowed; delegation must justify its total cost.
---

The repository's `hooks/orchestrate_flag.ps1` UserPromptSubmit hook reads explicit commands and owns the session preference. Use this skill only in Claude Code with that hook installed as described in this repository's README. If the hook supplied no state, report that limitation; do not recreate flag handling in the skill.

On `/orchestrate on`, acknowledge the delegation preference in one line. Evaluate the whole remaining ask and each proposed package against briefing, startup/context, execution, review/integration, and likely rework. Delegate bounded packages only when that comparison supports it, naming each worker's model and, when the package needs a different effort level than the worker's definition carries, its effort (agent-ladder.md, model-selection principle 6). Reuse a suitable worker when possible. Small or tightly coupled work stays inline; there is no code-write prohibition or line-count cutoff.

On `/orchestrate <task>`, the preference is ON and the remaining text is the task. Use the current prompt's hook state, rather than a preference from an earlier prompt. Brief the task into bounded packages and make the delegation calls in the same turn, naming each worker's model and, where it differs from the definition's, its effort; keep tightly coupled work and review inline. If delegation is unavailable or fails, report that limitation instead of claiming workers started.

On `/orchestrate off`, acknowledge the inline preference in one line. OFF persists until an explicit ON; code volume must not turn it back on.

On `/orchestrate status`, report the hook's observed preference without changing it. If the hook supplied no state, say that state is unavailable rather than inventing it.

Do not claim a worker was spawned until the actual delegation call succeeds. Do not recreate flag handling in this skill.
