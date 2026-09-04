# Agent Ladder

## Purpose

Choose the narrowest execution layer that can do the work reliably while preserving judgment in the session that owns the task.

## Decision sequence

### 1. Apply the cost gate

Ask whether doing the work inline would likely exceed the context and effort required to brief, start, and review another agent.

- A handful of commands, one configuration change, one status check, or a small edit stays inline.
- A full test suite, large mechanical migration, broad file sweep, or multi-step website interaction may justify delegation.

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

### 5. Use a second runtime deliberately

A second runtime is useful when it provides a distinct execution environment, a separate usage pool, or a better fit for spec-frozen implementation work. It is not a reason to split a small task or to avoid review.

Before handing work to a second runtime, make the specification self-contained. Assume it has no conversational context, no hidden decisions, and no access to tools that are not explicitly available in that runtime.

### 6. Review and close

The calling session reviews every delegated result before completion. For anything that ships, review the actual changed files and run the acceptance checks against the final tree. A successful sub-agent run is evidence of execution, not proof that the result is correct or publishable.

## Model-selection principles

When multiple capable agents are available:

1. Match intelligence to the risk and ambiguity of the work.
2. Preserve taste and judgment for user-facing or shipping output.
3. Use cost only as a tie-breaker after capability and fit.
4. Prefer the simplest capable route once the cost gate is passed.

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
