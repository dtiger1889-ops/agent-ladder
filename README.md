# Agent Ladder

Agent Ladder is a compact, runtime-agnostic guide to delegating work between agents, with optional PowerShell guardrails. Everything it needs is in this repository. It pairs with the [Claude Code Harness Toolbox](https://github.com/dtiger1889-ops/claude-harness-toolbox), a separate repo of session-memory tooling, but nothing here requires it.

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

- `hooks/model_gate.ps1` — refuses any sub-agent spawn that names no model or names Haiku (model-selection principle 5 in [agent-ladder.md](agent-ladder.md); every time, no state).
- `hooks/orchestrate_flag.ps1` — accepts explicit whole-prompt mode commands (`/orchestrate`, `/orchestrate on|off|status`, or `/orchestrate <task>`, where the remainder is the task to delegate), preserves OFF until explicit ON, and prints a short cost reminder. Questions, quotes, negations, and worker events cannot toggle preference. The plain phrases `orchestrate this`, `delegate this`, `go inline` and `stop orchestrating` work on their own; the `/orchestrate` form also needs the small skill in `skills/orchestrate/`, because some runtimes reject an unknown slash command before any hook sees it.
- `hooks/orchestrator_mode.ps1` — returns a nonblocking cost reminder on a write after 150 weighted lines or explicit ON. It never forbids inline edits, parses shell writes, or turns the mode on automatically.
- `hooks/delegation_gate.ps1` — counts approximate main-session code output and provides a nonblocking fallback reminder after 600 weighted lines. Workers are excluded. Both volume hooks share one reminder per session and respect explicit OFF. Their exit-zero structured context does not override permission decisions.
- `skills/orchestrate/SKILL.md` — the `/orchestrate` command itself: tells the agent what ON, OFF, status and a task after the command mean. Copy the folder into your skills directory (for Claude Code, `~/.claude/skills/orchestrate/`). The hook owns the state; the skill only responds to it.
- `tests/*_tests.ps1` — subprocess regressions with isolated state: 47 intent checks, 68 shared pre/post reminder checks, and 7 model-gate checks. The delegation-gate test entry point invokes the shared suite; do not count it twice.
- `config/claude-hooks.example.json` — example user-level hook wiring.

The hooks are portable PowerShell adaptations. Replace placeholders in the configuration before installing them, and review hook behavior against your own workflow.

## Status

This is a compact, runtime-agnostic adaptation of a larger private harness routing framework. Model names and product-specific capabilities are intentionally omitted because they change over time.
