# Agent Ladder

A companion to the [Claude Code Harness Toolbox](https://github.com/dtiger1889-ops/claude-harness-toolbox), Agent Ladder pulls its delegation logic into a compact, runtime-agnostic guide with optional PowerShell guardrails.

Use it to decide whether work should stay in the current session, move to a sub-agent, or run in a second agent runtime.

The central rule is simple: route by the shape and weight of the work, not by the task's label.

## The ladder

1. **Stay inline** for short, stateful, ambiguous, or judgment-heavy work.
2. **Use a sub-agent** when the work is large and mechanical enough to justify rebuilding context.
3. **Add a planning lead** only when decomposing and coordinating the work is itself substantial enough to clear the cost gate and will produce multiple bounded worker briefs.
4. **Use a second runtime** when the work is spec-frozen, repo-local, and execution-heavy, or when the primary runtime's usage pool is constrained.
5. **Review the result in the calling session** before treating it as complete, especially when it changes user-facing output or repository state.

The cost gate comes first: if the work can be finished in a few commands or a short edit, delegation usually costs more context than it saves.

See [agent-ladder.md](agent-ladder.md) for the full decision rules and source notes.

## Implementation

The repository also includes the implementation that turns the ladder into working guardrails:

- `hooks/delegation_gate.ps1` — reminds the session to delegate after enough inline code has accumulated.
- `hooks/grill_gate.ps1` — detects build kickoffs, advises an interview, and blocks the first ungrilled build write once.
- `hooks/checkpoint_finisher_guard.ps1` — reminds the session to verify and finish a checkpoint after editing it.
- `scripts/finish-checkpoint.ps1` — stamps, measures, sorts, and optionally archives a checkpoint.
- `scripts/sort_open_threads.ps1` — keeps tagged open-thread bullets in owner/agent and low/high order.
- `scripts/verify_checkpoint_claims.ps1` — checks checkpoint paths, state claims, and routing tags.
- `tests/grill_gate_tests.ps1` — wrapper tests for the grill gate; all 19 tests pass in the reference environment.
- `config/claude-hooks.example.json` — example user-level hook wiring.

The scripts are portable PowerShell adaptations. Replace placeholders in the configuration before installing them, and review hook behavior against your own workflow.

## Status

This is a compact, runtime-agnostic adaptation of a larger private harness routing framework. Model names and product-specific capabilities are intentionally omitted because they change over time.
