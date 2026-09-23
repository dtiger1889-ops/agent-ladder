---
name: orchestrate
description: Set this Claude Code session's cost-aware delegation preference with /orchestrate on, /orchestrate off, /orchestrate status, or /orchestrate <task> (ON plus delegate that task now). Inline changes remain allowed; delegation must justify its total cost.
---

The `hooks/orchestrate_flag.ps1` UserPromptSubmit hook in this repository reads explicit commands and owns the session preference. It does not activate from questions, quotations, negations, or incidental mentions. This skill is CLI-only; it does not implement hook state in other runtimes.

On `/orchestrate on`, acknowledge the delegation preference in one line. Evaluate the whole remaining ask and each proposed package against briefing, startup/context, execution, review/integration, and likely rework. Delegate bounded packages only when that comparison supports it, naming each worker's model. Reuse a suitable worker when possible. Small or tightly coupled work stays inline; there is no code-write prohibition or line-count cutoff.

On `/orchestrate <anything else>` (a task after the command), the preference is ON and the remainder IS the task: the hook prints "the text after /orchestrate IS the task". Do not read the hook's preference line from an earlier prompt, and never announce inline work in reply to this form. Brief the task into bounded packages and make the delegation calls in the same turn, naming each worker's model; keep only tightly coupled slivers and the review inline. (2026-09-21: a session answered `/orchestrate work through the roadmap...` with "this stays inline".)

On `/orchestrate off`, acknowledge the inline preference in one line. OFF persists until an explicit ON; code volume must not turn it back on.

On `/orchestrate status`, report the hook's observed preference without changing it. If the hook supplied no state, say that state is unavailable rather than inventing it.

Do not claim a worker was spawned until the actual delegation call succeeds. Do not recreate flag handling in this skill.
