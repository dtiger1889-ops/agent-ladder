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

See [agent-ladder.md](agent-ladder.md) for the full decision rules and source notes, and [HISTORY.md](HISTORY.md) for where each rule came from: the dated incidents, reviews and owner decisions behind every step, and the 2026-09-18 transcript audit that turned the prose rule into the hooks below.

## Implementation

The repository also includes the implementation that turns the ladder into working guardrails:

- `hooks/model_gate.ps1` — refuses any sub-agent spawn that names no model or names Haiku (principle 5, every time, no state).
- `hooks/orchestrate_flag.ps1` — accepts explicit whole-prompt mode commands, preserves OFF until explicit ON, and prints a short cost reminder. Questions, quotes, negations, and worker events cannot toggle preference.
- `hooks/orchestrator_mode.ps1` — returns a nonblocking cost reminder on a write after 150 weighted lines or explicit ON. It never forbids inline edits, parses shell writes, or turns the mode on automatically.
- `hooks/delegation_gate.ps1` — counts approximate main-session code output and provides a nonblocking fallback reminder after 600 weighted lines. Workers are excluded. Both volume hooks share one reminder per session and respect explicit OFF. Their exit-zero structured context does not override permission decisions.
- `tests/*_tests.ps1` — subprocess regressions with isolated state: 45 intent checks, 68 shared pre/post reminder checks, and 7 model-gate checks. The delegation-gate test entry point invokes the shared suite; do not count it twice.
- `config/claude-hooks.example.json` — example user-level hook wiring.

The hooks are portable PowerShell adaptations. Replace placeholders in the configuration before installing them, and review hook behavior against your own workflow.

## Status

This is a compact, runtime-agnostic adaptation of a larger private harness routing framework. Model names and product-specific capabilities are intentionally omitted because they change over time.
