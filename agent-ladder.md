# Agent Ladder

## Purpose

Choose the narrowest execution layer that can do the work reliably while preserving judgment in the session that owns the task.

## Models in use (as of 2026-10-29)

A change to this table changes the ladder; the steps below name these models where the choice depends on them.

| Model | Model id | Role in the ladder |
|---|---|---|
| Claude Opus 5.5 | `claude-opus-5-5` | Leads every session and orchestrates: briefs, spawns, review, integration, release. Default worker, at medium effort |
| Claude Fable 5.1 | `claude-fable-5-1` | Writes long-range (multi-phase) plans only, called as a helper. Never leads a session or spawns workers |
| Claude Sonnet 5.5 | `claude-sonnet-5-5` | Workers for bulk, checkable packages whose answer key exists before the worker starts (principle 7) |
| Claude Haiku 4.5 | `claude-haiku-4-5-20251001` | Not used for real work (principle 5; `hooks/model_gate.ps1` refuses it) |
| Sol 6.1 (Codex) | `gpt-6.1-sol` | Read-only second reader: audits plans and finished work, low effort unless named |

## Decision sequence

### 1. Apply the cost gate

Ask whether doing the work inline would likely exceed the context and effort required to brief, start, and review another agent.

- A handful of commands, one configuration change, one status check, or a small edit stays inline.
- A full test suite, large mechanical migration, broad file sweep, or multi-step website interaction may justify delegation.

Evaluate the remaining whole ask, then each proposed package. Include briefing, worker startup/context, execution, review, integration, and likely rework; prefer reusing a suitable worker over another cold start. Already-spent effort and code-line counts do not establish that a handoff will save tokens. The optional hooks provide reminders, never a prohibition on inline work. No numerical savings are claimed without measurement.

This gate outranks the task category. A task being “mechanical” is not enough by itself.

### 2. Keep judgment with the judgment tier

Keep these with the judgment tier, the strongest model that owns the session (which tier that is: the end of this step):

- ambiguous requirements and architecture
- naming, product judgment, and user-facing writing
- decisions involving credentials, permissions, or external side effects
- repository mutations that need an explicit release decision
- reviewing delegated output

Usually the judgment tier owns the session and delegates bounded work down to cheaper workers (steps 3 and 4). It can also be called up into a cheaper session at fixed points (step 5). In both shapes the judgment tier's verdict stands, not the executing session's. Delegation can perform bounded work, but it does not transfer responsibility for the result.

The judgment tier is not automatically the most expensive model on offer. When the top model costs several times the tier below it, and that tier is strong enough to brief, review, and release, the tier below owns the session and does the orchestration. The top model is called in as a helper for one package only: the long-range plan, meaning the multi-phase plan or spec the session then carries out. It does not run sessions or spawn workers. The orchestrating session edits inline only for small one-off fixes and sends everything else to workers. Today that means Claude Opus 5.5 owns the session and orchestrates, and Claude Fable 5.1 writes long-range plans only.

### 3. Add a planning lead only for genuinely multi-layer work

A planning lead is warranted when the owner has settled the goal and boundaries, but producing the implementation plan, interfaces, and worker briefs is itself a large task. The planning lead turns that direction into bounded packages and may delegate those packages to workers when the runtime supports nested agents.

Use this layer only when there are multiple substantial workstreams to coordinate. Apply the cost gate to every delegation edge: if the planning work is small, the owner plans inline and delegates directly to workers.

The default maximum is two levels below the owner: one planning lead and its workers. The owner retains final authority; the planning lead owns decomposition and contracts; workers own only their assigned packages.

The long-range plan from Claude Fable 5.1, the top model (step 2), is a different package from this layer: it is written once, up front, and handed back to the orchestrating session, which then decomposes it itself or through a planning lead on its own tier.

### 4. Delegate bounded mechanical work

Use a sub-agent when the task is well-bounded, repeatable, and large enough to clear the cost gate. Good candidates include:

- bulk exploration and classification
- building or running a development server
- full test suites
- repetitive transformations with an explicit acceptance test
- implementation from a frozen specification

The brief should state the goal, exact scope, constraints, verification command, and expected output. If the agent fails twice for the same reason, take the work back into the owner session.

When the worker operates on a git-backed repository, the brief also tells it to commit and push after every completed step (a draft pull request or a plain push of its own branch is enough). A usage-limit cutoff, a killed process, or a closed window then loses at most the step in progress, never the run; and nothing squashes those step commits away before review.

Define workers as trimmed agent files rather than briefing a general-purpose agent each time. Pin the model and a default effort level in the definition instead of relying on the caller to pass them (model-selection principle 6), and remove the tools a worker should never reach for — spawning further agents and publishing pages are the two that matter, because both let a bounded package quietly become an unbounded one. Keep one definition per tier: a cheaper one for mechanical packages and a stronger one for packages whose output a person will read.

Fix the shape of the report. Every worker ends its report with two lines — what it concluded, and the evidence that makes it true (a command's output, a file and line, a test result). The calling session's own reply then names which model did which part of the work. Both rules exist so a conclusion can be checked rather than re-decided from a bare answer, and so nobody reading the result later has to guess which tier produced it.

Give every worker a hard budget, stated in the brief: a maximum number of tool calls and a wall-clock limit. Reasonable defaults are about 40 tool calls or 15 minutes for a small package and about 120 tool calls or 45 minutes for a medium one. If the worker hits either limit it stops and reports partial work — it does not loop, and it does not retry the same failing approach again. Where the runtime supports a turn-cap field in the agent definition, set it as a backstop; a wall-clock limit usually has no such field, so it is enforced by the brief text alone.

### 5. Invert the ladder for long mechanical builds

Steps 3 and 4 keep the judgment tier on top and send work down. The same judgment boundary also works in the other direction: a session opened on a cheaper model does the build and calls the stronger model in only where judgment is needed. Use this shape when all of these hold:

- a written specification is frozen and serves as the contract
- deterministic checks (tests, build, lint) exist and run locally
- the task is long enough that most of its tokens go to writing and running code rather than deciding what to build

The cheaper session is the driver. It calls the stronger model in as a judge at three fixed points: approving the plan before building starts, sorting review findings into real problems and noise, and accepting or rejecting the finished result. Each call carries a short brief (the task, the binding lines of the spec, the artifact under judgment, and the single question being asked), never the transcript, and tells the judge to rule from the brief alone.

This rung needs guards the downward shape does not. Going down, the strongest tier decides when to delegate. Inverted, the cheaper model would be deciding when to ask for help, which is the weak point the model-cascade research names: a gate that confidently accepts bad work saves money by hiding failures. So:

- The judgment points are fixed by the procedure before the build starts. The driver does not choose when to call a judge, and it does not skip one.
- The driver never overrides a verdict. A rejected plan is revised and resubmitted.
- A failing check is a failure. No judge can approve work the tests reject, and the driver never weakens a test to get past one.
- After three rejections at the same point, the driver stops and hands the state back to a person instead of grinding.
- If a judge call fails on a usage limit, the whole run stops. It never continues unjudged.

The shape is chosen when the session opens, because the session has to start on the cheaper model; a session already running on the strong model gains nothing by spawning judges of its own tier. Keep the procedure itself (brief template, strike counting, abort rules) in a driver skill or script, and let this step decide only when to use it. A public reference for such a driver is kerim's Autodev gist, linked in the source notes.

### 6. Use a second runtime deliberately

A second runtime is useful when it provides a distinct execution environment, a separate usage pool, or a better fit for spec-frozen implementation work. It is not a reason to split a small task or to avoid review.

Before handing work to a second runtime, make the specification self-contained. Assume it has no conversational context, no hidden decisions, and no access to tools that are not explicitly available in that runtime.

### 7. Review and close

The calling session reviews every delegated result before completion. For anything that ships, review the actual changed files and run the acceptance checks against the final tree. A successful sub-agent run is evidence of execution, not proof that the result is correct or publishable.

Check the result against the original brief, never against the builder's own summary of what it did; a builder can launder its own wrong "done" claim without meaning to. With one or two delegated tasks in flight, the calling session does this check itself. With three or more running at once, spawn one fresh reviewer agent (model named, per principle 5) to re-run the acceptance checks, because at that width the caller's own skim is exactly what lets an incomplete result through.

## Model-selection principles

When multiple capable agents are available:

1. Match intelligence to the risk and ambiguity of the work.
2. Preserve taste and judgment for user-facing or shipping output.
3. Use cost only as a tie-breaker after capability and fit.
4. Prefer the simplest capable route once the cost gate is passed.
5. Name the model on every delegated spawn. Omitting the model parameter is not a way to accept a default tier; it is an unrecorded choice, and the review in step 7 cannot tell which tier did the work. It matters most in the inverted shape of step 5: a sub-agent with no model named can fall back to the calling session's model, so a judge spawned without one runs on the cheap tier it was meant to check.
6. Set the effort level as deliberately as the model. A helper with no effort level of its own runs at whatever level the calling session runs at, so a session working at its deepest setting runs a file sweep at that setting too. Give each worker definition a default (a middle level), pass a level at spawn only when the package differs from that default, and always pass one for a built-in agent type, which has no definition to carry a default. A starting split: short, mechanically checkable work (principle 7) at the lowest level, with a checklist in the brief; work built from a written plan with a test at the middle level; harder or longer work, such as a diagnosis with a known reproduction, a change across many files, or a review of delegated work against its brief's acceptance check, one level up; the judgment tier at its own default, one level up when the package is long or failed once. Keep the top everyday levels for work the vendor's guidance describes as long-running, or for when the owner names one, and leave the maximum out: it overthinks simple work. If a package's check fails twice at one level, raise it one step; never raise it just to be safe. A session that started before a definition was edited may keep the old definition until it restarts, so check the level a helper actually ran at before trusting a new default.
7. Decide whether a package is checkable or a verdict before picking its tier. A package is checkable, and may go to the cheap tier, only if a fixed answer key exists before the worker starts (a test, a fixture, a spec, a list of literal strings to match) and the brief names it. A package whose output is a verdict (done or not, needed or not, stale or live, right or wrong, which option) is judgment and goes to the judgment tier, however long the list. A long list of items to "verify" looks like a sweep, but without an answer key each item is a small judgment call.

Do not encode fast-changing model names or permanent numerical rankings into the ladder.

## Source notes

This adaptation draws on:

- Theo's model-routing comparison, https://x.com/theo/status/2072482460122964067
- steipete's codex-first workflow, https://github.com/steipete/agent-scripts/blob/main/skills/codex-first/SKILL.md
- Anthropic's orchestrator-worker pattern, https://www.anthropic.com/engineering/building-effective-agents
- Anthropic's hierarchical/supervisory architecture, including subagent team leaders with their own subagents, https://resources.anthropic.com/hubfs/Building%20Effective%20AI%20Agents-%20Architecture%20Patterns%20and%20Implementation%20Frameworks.pdf
- Magentic-One's planning and progress-tracking orchestrator, https://www.microsoft.com/en-us/research/wp-content/uploads/2024/11/MagenticOne.pdf
- AOrchestra's per-task composition of instruction, context, tools, and model, https://arxiv.org/abs/2602.03786

The inverted rung in step 5 draws on:

- FrugalGPT, which sends a request to the cheapest model first and escalates only when a check on the answer fails, https://arxiv.org/abs/2305.05176
- the model-cascade failure modes, including the gate that accepts bad work, https://www.tmls.nyc/research/model-routing-cascades
- a published Claude Code proposal for a strong planner and cheap implementer where a script, never the worker, decides when to escalate, https://github.com/CrazyWillBear/my-dotclaude/issues/104
- kerim's Autodev gist, a cheap driver that calls an expensive judge at plan approval, review adjudication, and final acceptance, https://gist.github.com/kerim/cb98e883e3d5ba730249344940e475a3
- Claude Code's sub-agent documentation, where a sub-agent's model is set independently of the parent's and may be stronger, https://code.claude.com/docs/en/sub-agents

The effort levels in model-selection principle 6 draw on:

- Anthropic's effort documentation, which names the lowest level for simpler tasks such as subagents and the middle level for well-specified agentic work, https://platform.claude.com/docs/en/build-with-claude/effort
- Claude Code's sub-agent documentation, where a definition's effort field overrides the session's level and an effort passed at spawn overrides the definition, https://code.claude.com/docs/en/sub-agents
- Codex's sub-agent documentation, which takes the spawn's value, then a configured default, then the parent's, https://learn.chatgpt.com/docs/agent-configuration/subagents.md
- oaustegard's agent-routing skill, which routes by whether work can be checked mechanically and refuses to raise the tier on checkable work "to be safe", https://github.com/oaustegard/claude-skills/tree/main/plugins/ai-and-reasoning

The source ideas were adapted rather than copied literally: the model score table was omitted because model capabilities and subscription economics change, while the cost gate, judgment boundary, frozen-spec execution pattern, and bounded planning-lead layer remain useful. The models in use are still listed by full name and dated at the top, because a model change is what changes the ladder (owner decision, 2026-10-29). A planning lead is deliberately optional because extra hierarchy increases coordination cost and can compound errors when workstreams are tightly coupled. The inverted rung adopts the cascade idea of calling a stronger model only when needed, but takes the decision of when away from the cheap model: the call points are fixed in advance, because a cheap model deciding for itself when it needs help is the failure mode the cascade research warns about.
