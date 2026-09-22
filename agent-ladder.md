# Agent Ladder

## Purpose

Choose the narrowest execution layer that can do the work reliably while preserving judgment in the session that owns the task.

## Decision sequence

### 1. Apply the cost gate

Ask whether doing the work inline would likely exceed the context and effort required to brief, start, and review another agent.

- A handful of commands, one configuration change, one status check, or a small edit stays inline.
- A full test suite, large mechanical migration, broad file sweep, or multi-step website interaction may justify delegation.

Evaluate the remaining whole ask, then each proposed package. Include briefing, worker startup/context, execution, review, integration, and likely rework; prefer reusing a suitable worker over another cold start. Already-spent effort and code-line counts do not establish that a handoff will save tokens. The optional hooks provide reminders, never a prohibition on inline work. No numerical savings are claimed without measurement.

This gate outranks the task category. A task being “mechanical” is not enough by itself.

### 2. Keep judgment work with the owner

Stay in the calling session for:

- ambiguous requirements and architecture
- naming, product judgment, and user-facing writing
- decisions involving credentials, permissions, or external side effects
- repository mutations that need an explicit release decision
- reviewing delegated output

Delegation can perform bounded work, but it does not transfer responsibility for the result.

### 3. Add a planning lead only for genuinely multi-layer work

A planning lead is warranted when the owner has settled the goal and boundaries, but producing the implementation plan, interfaces, and worker briefs is itself a large task. The planning lead turns that direction into bounded packages and may delegate those packages to workers when the runtime supports nested agents.

Use this layer only when there are multiple substantial workstreams to coordinate. Apply the cost gate to every delegation edge: if the planning work is small, the owner plans inline and delegates directly to workers.

The default maximum is two levels below the owner: one planning lead and its workers. The owner retains final authority; the planning lead owns decomposition and contracts; workers own only their assigned packages.

### 4. Delegate bounded mechanical work

Use a sub-agent when the task is well-bounded, repeatable, and large enough to clear the cost gate. Good candidates include:

- bulk exploration and classification
- building or running a development server
- full test suites
- repetitive transformations with an explicit acceptance test
- implementation from a frozen specification

The brief should state the goal, exact scope, constraints, verification command, and expected output. If the agent fails twice for the same reason, take the work back into the owner session.

When the worker operates on a git-backed repository, the brief also tells it to commit and push after every completed step (a draft pull request or a plain push of its own branch is enough). A usage-limit cutoff, a killed process, or a closed window then loses at most the step in progress, never the run; and nothing squashes those step commits away before review.

Define workers as trimmed agent files rather than briefing a general-purpose agent each time. Pin the model in the definition instead of relying on the caller to pass one, and remove the tools a worker should never reach for — spawning further agents and publishing pages are the two that matter, because both let a bounded package quietly become an unbounded one. Keep one definition per tier: a cheaper one for mechanical packages and a stronger one for packages whose output a person will read.

Fix the shape of the report. Every worker ends its report with two lines — what it concluded, and the evidence that makes it true (a command's output, a file and line, a test result). The calling session's own reply then names which model did which part of the work. Both rules exist so a conclusion can be checked rather than re-decided from a bare answer, and so nobody reading the result later has to guess which tier produced it.

Give every worker a hard budget, stated in the brief: a maximum number of tool calls and a wall-clock limit. Reasonable defaults are about 40 tool calls or 15 minutes for a small package and about 120 tool calls or 45 minutes for a medium one. If the worker hits either limit it stops and reports partial work — it does not loop, and it does not retry the same failing approach again. Where the runtime supports a turn-cap field in the agent definition, set it as a backstop; a wall-clock limit usually has no such field, so it is enforced by the brief text alone.

### 5. Use a second runtime deliberately

A second runtime is useful when it provides a distinct execution environment, a separate usage pool, or a better fit for spec-frozen implementation work. It is not a reason to split a small task or to avoid review.

Before handing work to a second runtime, make the specification self-contained. Assume it has no conversational context, no hidden decisions, and no access to tools that are not explicitly available in that runtime.

### 6. Review and close

The calling session reviews every delegated result before completion. For anything that ships, review the actual changed files and run the acceptance checks against the final tree. A successful sub-agent run is evidence of execution, not proof that the result is correct or publishable.

Check the result against the original brief, never against the builder's own summary of what it did; a builder can launder its own wrong "done" claim without meaning to. With one or two delegated tasks in flight, the calling session does this check itself. With three or more running at once, spawn one fresh reviewer agent (model named, per principle 5) to re-run the acceptance checks, because at that width the caller's own skim is exactly what lets an incomplete result through.

## Model-selection principles

When multiple capable agents are available:

1. Match intelligence to the risk and ambiguity of the work.
2. Preserve taste and judgment for user-facing or shipping output.
3. Use cost only as a tie-breaker after capability and fit.
4. Prefer the simplest capable route once the cost gate is passed.
5. Name the model on every delegated spawn. Omitting the model parameter is not a way to accept a default tier; it is an unrecorded choice, and the review in step 6 cannot tell which tier did the work.

Do not encode fast-changing model names or permanent numerical rankings into the ladder.

## Source notes

This adaptation draws on:

- Theo's model-routing comparison, https://x.com/theo/status/2072482460122964067
- steipete's codex-first workflow, https://github.com/steipete/agent-scripts/blob/main/skills/codex-first/SKILL.md
- Anthropic's orchestrator-worker pattern, https://www.anthropic.com/engineering/building-effective-agents
- Anthropic's hierarchical/supervisory architecture, including subagent team leaders with their own subagents, https://resources.anthropic.com/hubfs/Building%20Effective%20AI%20Agents-%20Architecture%20Patterns%20and%20Implementation%20Frameworks.pdf
- Magentic-One's planning and progress-tracking orchestrator, https://www.microsoft.com/en-us/research/wp-content/uploads/2024/11/MagenticOne.pdf
- AOrchestra's per-task composition of instruction, context, tools, and model, https://arxiv.org/abs/2602.03786

The source ideas were adapted rather than copied literally: the model score table was omitted because model capabilities and subscription economics change, while the cost gate, judgment boundary, frozen-spec execution pattern, and bounded planning-lead layer remain useful. A planning lead is deliberately optional because extra hierarchy increases coordination cost and can compound errors when workstreams are tightly coupled.
