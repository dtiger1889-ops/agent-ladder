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
- `hooks/orchestrate_flag.ps1` — turns a per-session orchestrator mode on or off from the prompt ("orchestrate", "delegate the rest", `/orchestrate on`; "go inline", `/orchestrate off`) and prints one short delegation reminder on every real prompt.
- `hooks/orchestrator_mode.ps1` — while the mode is on, refuses code writes from the main session (files with code extensions, shell heredocs, `Set-Content`, `sed -i`); docs and the checkpoint pass; workers are exempt because their hook input carries an agent id. Also turns the mode on by itself once the delegation gate's counter reaches 150 inline code lines.
- `hooks/delegation_gate.ps1` — counts inline code lines, including shell heredoc writes, and reminds the session to delegate once past 600. Give it its own PostToolUse entry: when several hooks in one entry exit 2 on the same call, only one message survives.
- `hooks/grill_gate.ps1` — detects build kickoffs, advises an interview, and blocks the first ungrilled build write once.
- `hooks/checkpoint_finisher_guard.ps1` — reminds the session to verify and finish a checkpoint after editing it.
- `scripts/finish-checkpoint.ps1` — stamps, measures, sorts, and optionally archives a checkpoint.
- `scripts/sort_open_threads.ps1` — keeps tagged open-thread bullets in owner/agent and low/high order.
- `scripts/verify_checkpoint_claims.ps1` — checks checkpoint paths, state claims, and routing tags.
- `tests/*_tests.ps1` — wrapper tests for each hook (grill gate 19, model gate 7, orchestrate flag 14, orchestrator mode 13, delegation gate 8); all pass in the reference environment.
- `config/claude-hooks.example.json` — example user-level hook wiring.

The three checkpoint scripts are the same files the [Claude Code Harness Toolbox](https://github.com/dtiger1889-ops/claude-harness-toolbox) ships inside its `checkpoint` skill; that repo is their home and carries the skill text that calls them. They are mirrored here so the finisher hook has something to point at.

The scripts are portable PowerShell adaptations. Replace placeholders in the configuration before installing them, and review hook behavior against your own workflow.

## Status

This is a compact, runtime-agnostic adaptation of a larger private harness routing framework. Model names and product-specific capabilities are intentionally omitted because they change over time.
