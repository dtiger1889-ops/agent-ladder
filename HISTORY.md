# Provenance of the Agent Ladder

Where each rule in [agent-ladder.md](agent-ladder.md) came from, in date order, with the
incident or decision that produced it. The private workspace this was extracted from keeps
the full records; this file is the public trail so nobody has to take a rule on faith.

"The owner" is the maintainer of the private workspace. "The model" is whichever Claude
tier was on duty in the session that did the work.

## Before the ladder (2026-05 to 2026-06)

- **2026-05-27.** First delegation in the workspace: a Haiku sub-agent defined to archive
  checkpoint changelog entries between two known files, because doing that inline burned
  main-session context on mechanical text relocation. Lesson recorded the same day: agent
  definition files are loaded at session start, not mid-session. This was a single-purpose
  delegation, not a routing rule.
- **2026-06-15.** The over-routing incident that later anchored the cost gate: a
  four-command service restart was handed to a Sonnet sub-agent and cost about 67k tokens,
  because a sub-agent starts cold, re-explores, and over-verifies. The rule that came out of
  it, in the workspace's always-loaded instructions: the trigger for delegation is token
  weight, not the task's noun; only work that would cost more than roughly 30-40k tokens
  inline pays for a sub-agent's cold start.

## The routing rule (2026-07)

- **2026-07-07/08.** The owner clipped two public sources into notes: a
  cost/intelligence/taste comparison table for choosing models per sub-task
  (https://x.com/theo/status/2072482460122964067) and a codex-first workflow in which the
  primary agent keeps judgment work and hands frozen-spec execution to a second runtime
  (https://github.com/steipete/agent-scripts/blob/main/skills/codex-first/SKILL.md). The
  first pass filed the table as reference only; the owner corrected that the next day and
  made it a task.
- **2026-07-09.** An adversarial review of the table before adoption. Rejected: the
  verbatim grid, because the cost column is API price per token and the owner is
  subscription-billed on both runtimes, so the real cost is usage-window depletion; because
  model names and rankings churn quarterly and a hard-coded grid in an always-loaded file
  guarantees staleness; and because a per-task classification matrix invites more routing
  decisions, which is the documented over-routing failure. Adopted as principles instead:
  taste is a routing dimension (user-facing output stays in the taste tier even when
  token-heavy); intelligence over taste over cost for anything that ships, cost breaking ties
  only; a second runtime is both a routing option and a fallback usage pool. The cost gate
  stayed supreme over every model choice. Never Haiku for real work was set here on
  intelligence grounds. This is the origin of the ladder's steps 1, 2, 4 and principles 1-4.
- **2026-07-17.** The second runtime went live after an activation checklist (the CLI is
  not on PATH; it hangs without an explicit sandbox flag and stdin; it has a roughly
  10k-token floor, so one-liners are never routed there). The owner widened its scope the
  same week: spec-frozen, repo-local, pure-code work is the preferred lane, not the
  eligibility boundary; when the primary runtime's usage is exhausted the second runtime may
  take full harnessed tasks. The owner owns cross-agent concurrency; two agents never work
  the same task at once. Step 5's wording comes from this.
- **2026-07-19.** A reverse rung was evaluated from a public gist: open the session on the
  cheaper model for spec-frozen build batches and spawn the top tier only as a judge for plan
  approval and review adjudication. Filed for a trial on the owner's go; never adopted as a
  default.

## Enforcement begins (2026-09-02 to 2026-09-14)

- **2026-09-02.** First recorded failure of the rule: a multi-thousand-line build was
  started inline until the owner said "offload segmented work to more efficient sub agents
  and act as an orchestrator." The owner asked the same night what the workspace's
  delegation conventions were and whether there was a hook. There was not. One was built
  that night: a post-edit counter that prints one reminder past 600 inline code lines,
  advisory, never blocking. `hooks/delegation_gate.ps1` in this repo is that hook.
- **2026-09-03/04.** The ladder was extracted from the private framework into this
  repository, minus private paths, workspace-only instructions, personal usage data and
  volatile model rankings. The hooks, the checkpoint scripts and their wrapper tests followed
  the next day after the owner asked why the implementation was missing from the public
  release.
- **2026-09-04.** An audit of the public and private texts found they covered owner-to-worker
  delegation but never defined owner-to-planning-lead-to-workers. Prior art was swept
  (Anthropic's orchestrator-worker and supervisory patterns, Magentic-One, MetaGPT,
  AOrchestra, and Anthropic's own reports of heavy token use and weak results when
  workstreams share many dependencies). The owner chose a three-tier shape with a named
  planning-lead model as an optional depth rung: only when decomposition and coordination
  independently clear the cost gate and there are multiple substantial worker packages;
  capped at one planning lead plus its workers; and if the runtime substitutes a different
  model, the session says so rather than treating the preference as met. Step 3 comes from
  this.
- **2026-09-09.** Build agents save early: a worker on its own branch commits after every
  completed step and opens a draft pull request after the first green step, so a killed
  agent loses at most the step in progress; step commits are never squashed away before
  review. The owner set this after a build run whose partial work survived only because of
  that habit.
- **2026-09-11.** Second recorded failure, same rule: four spec-frozen review items in one
  repository were all done inline through many small edits that never crossed the counter's
  600 lines. The owner asked twice, "Are you delegating as your hook requires?" then "Should
  you have been delegating?" The mechanism named: the cost-gate litmus was being asked of
  the next step, which always looks like a few commands, never of the whole list a go
  covered. Rule added: judge the batch, not the next step; a batch of small steps is a build.
- **2026-09-14.** Two candidate fixes reviewed against shipped prior art. A tool-call
  counter was dropped (noisy proxy, fires too late; Anthropic had declined a mechanical
  spawn-cost hook, https://github.com/anthropics/claude-code/issues/55144). A prompt-time
  reminder that fires when a prompt hands over a list of three or more items plus a go-word
  was built instead, citing a published always-on delegation nudge
  (https://github.com/Jerry0022/dotclaude/pull/379) as the pattern.

## Two rules from a review of other people's setups (2026-09-15/16)

- **2026-09-15.** Two community sub-agent setups were compared against the ladder. Found
  already covered: strict per-agent scope, scratch-file hand-off for big output, no two
  agents editing the same file. Found missing: a reviewer that checks the builder's result
  against the original brief rather than the builder's own summary, and explicit model
  pinning on every spawn. Rejected again: Haiku as a scout role, on the 2026-07-09 grounds
  plus the thread's own top comment. A subscription cost-per-task chart was evaluated the
  same day and not adopted: self-reported estimates, not measurements.
- **2026-09-16.** The owner picked from a decision board: name the model on every delegated
  spawn, because omitting the parameter is an unrecorded routing choice the review cannot
  see (principle 5, commit d82c160); and for delegated work that ships, check "done" against
  the original brief by re-running the acceptance command, with the orchestrating session
  doing it at one or two tasks in flight and a fresh reviewer agent at three or more, in the
  owner's words "Only spawn an agent on 3 or more delegated tasks at the time. Orchestrator
  should check for 2-1" (step 6, commit 6fc4272). The incident behind step 6: on 2026-09-04
  a build agent reported six steps done and 677 tests green while its pushed branch lacked
  the main change and its new tests could not import; the orchestrator's skim let it merge.
- **2026-09-16, open.** The owner filed a question for a later measurement: whether a
  diagnosis that needs a reproduction harness (three client builds, a throwaway server, a
  headless browser driven over the devtools protocol, then a 60-line fix) should have gone to
  a builder instead of staying inline. No verdict yet.

## The audit and the hooks (2026-09-18)

- The owner asked whether the top tier had actually been applying the ladder. The check
  read 130 session transcripts rather than the incident ledger. Findings: 228 spawns since
  09-01 and model naming compliant after the rule; but ten owner prompts in fifteen days were
  needed to start or restart delegation; three sessions that opened with an orchestrate
  instruction drifted back to typing code; the line counter had fired in three sessions ever
  and was followed by 954 more inline lines in one; the list reminder had never fired in a
  top-tier session; and all ten Haiku sub-agent runs on disk were unnamed spawns of the
  built-in documentation-lookup agent, which pins Haiku in its own definition and so
  outranks the environment variable that would force a model
  (https://code.claude.com/docs/en/sub-agents). Two of those runs produced the month's two
  false "not possible" capability claims the owner had to correct, one of them about the
  planning lead's own model.
- Why the counter had been silent in the two largest inline sessions, found by the repair
  worker: three hooks shared one post-edit matcher entry, and when more than one exits 2 on
  the same call only one message reaches the transcript; the counter, listed last, lost.
- An outside pass before designing: a pre-spawn hook can read the spawn's input and refuse it
  but cannot rewrite its model (https://github.com/anthropics/claude-code/issues/44412);
  hook input carries an agent id only inside a sub-agent
  (https://code.claude.com/docs/en/hooks), which lets a write-block tell the orchestrating
  session from its workers; the nearest packaged orchestrator
  (https://github.com/Nanako0129/pilotfish) is prompt-only and keeps main-session coding.
- The owner was interviewed on twelve forks. Picks: a hard block, every time, on any spawn
  with no model or with Haiku; a per-session orchestrator mode, on by phrase or a slash
  command, off by phrase, during which the main session writes docs and the checkpoint only
  and any code write, including a shell heredoc, is refused with a one-line redirect to a
  named-model worker; auto-on after 150 cumulative inline code lines, reconciling "I never
  have to say orchestrate again" with "no false block on a small edit"; one short delegation
  line on every real prompt, replacing the list reminder; the counter repaired to see shell
  writes and given its own matcher entry. Rejected: widening the list reminder's trigger
  (another proxy on the same fading-rule problem), rewriting the model from the hook (not
  possible), budget-aware delegation (a different question), enforcement in runtimes with no
  hooks.
- The four hooks and their wrapper tests are in `hooks/` and `tests/`.

## Correcting over-enforcement (2026-09-18, later)

The owner questioned whether the implementation served token efficiency. The audit found that relaxing the veto first to two lines and then forty had left its underlying error intact: a one-line new file was blocked, a read-only Python heredoc was misclassified as a write, and a question or explicit negation could turn the restriction on. Worker output was also counted as inline work. Passing wrapper tests had confirmed the restriction, not its economic value.

The owner authorized delegated fixes. The automatic veto and shell detector were removed; line volume now supplies a nonblocking reminder to compare the whole remaining ask and each package against total handoff costs. Explicit ON is a preference, OFF persists, and only whole-prompt commands change state. Workers are excluded before state mutation. Pre/post reminders share one atomic session marker and return structured additional context without a permission decision. Model naming and review requirements remain.

The earlier explanation that shared hook entries caused lost exit-2 feedback was plausible transcript analysis, not a controlled runtime result. Current reminders use the documented exit-zero `additionalContext` channel instead; see the [hooks reference](https://code.claude.com/docs/en/hooks#add-context-for-claude). Regression checks establish these behaviors, not measured net token savings.

## Scoping the repo back to the ladder (2026-09-18, later still)

The owner reviewed this repository and found it overgrown: alongside the ladder it had accreted a
checkpoint subsystem (a finisher-guard hook plus finish / sort / verify scripts, mirrored from the
[Claude Code Harness Toolbox](https://github.com/dtiger1889-ops/claude-harness-toolbox) so the guard had something to point at), a build-kickoff "grill" gate, and a
subscription budget evaluator with a Codex adapter. None of that decides whether to delegate work.
It was removed so the repo is just the ladder: the guide, this history, the four routing hooks
(`model_gate`, `orchestrate_flag`, `orchestrator_mode`, `delegation_gate`) with their tests, and one
example config. The checkpoint scripts live in the toolbox repo linked above, which is optional and not needed to
use anything here; the subscription gate stays in the owner's private workspace. Earlier entries above still mention the removed pieces because they are
the record of what was tried -- this note is why they are no longer in the tree.

## The task form (2026-09-21)

The 2026-09-18 tightening made `orchestrate_flag` accept only the bare command and the three
keywords. On 2026-09-21 the owner typed `/orchestrate work through the roadmap...`: the hook
matched nothing, reported OFF, and the session announced it would work inline. The owner had
invoked the `/orchestrate` skill (now shipped in `skills/orchestrate/`) precisely to get delegation. Fix: a prompt that starts with `/orchestrate` is
always explicit; any remainder other than `on`/`off`/`status` turns the preference ON and is
named as the task in the hook's output. Prompts that merely contain the command elsewhere
still toggle nothing. Tests: 47 pass.

## Push after every step (2026-09-22)

A worker that only pushes at the end loses the whole run when the usage window closes or the
process dies mid-task. The owner had already decided on 2026-09-09 that build agents commit per
step and open a draft pull request after the first green step; on 2026-09-21 an inbox note asked
for the ladder itself to say so, since the ladder is what a delegating session reads when it writes
the brief. Step 4 now carries one paragraph: on a git-backed repository the brief tells the worker
to commit and push after every completed step, and nothing squashes those commits away before review.

## Trimmed workers, a fixed report shape, and a per-worker budget (2026-09-22)

The owner clipped two public threads on 2026-09-18, both about running the strongest model as an
orchestrator over cheaper workers. Most of what they described the ladder already did -- the cost
gate, a reviewer after the builder, workers returning a summary, isolated worktrees -- so only four
ideas were new, and they went to the owner as a decision. He took three and rejected the fourth.

Taken: (1) define workers as trimmed agent files with the model pinned in the definition and the
agent-spawning and page-publishing tools removed, because a general-purpose agent carries tool
definitions it will never use and, worse, can turn a bounded package into an unbounded one by
spawning more agents; (2) a fixed report shape, two closing lines naming what the worker concluded
and the evidence for it, with the calling session's own reply naming which model did which part,
so a conclusion is checked rather than re-decided from a bare answer; (3) a hard budget per worker
-- a maximum number of tool calls and a wall-clock limit, stated in every brief, with the worker
stopping and reporting partial work instead of looping. Defaults set at roughly 40 calls or 15
minutes for a small package and 120 calls or 45 minutes for a medium one. The turn cap has a real
field in the agent definition; the wall-clock half is enforced by the brief text only.

Rejected: (4) a cheapest-tier agent used purely as a test runner that trims output down to the
failures. It is a genuine token saving, but the workspace has never routed real work to that tier
since 2026-07-09, on intelligence grounds, and the owner declined to make the first exception for
a saving this small.

## Standing on its own (2026-09-23)

The owner's rule for every public repo: linking to another repo is fine, depending on one is not. A
read of this repository as a stranger would read it found places that still reached into the private
workspace: a hook comment pointing at a file on the owner's machine, refusal messages citing a
"workspace rule" the reader does not have, a test header naming the owner's install path, and a
`/orchestrate` command whose skill half was never published. The pointers now name this repository's
own files; the skill ships in `skills/orchestrate/`; the toolbox is linked as optional. No behavior
changed and the three suites still pass (7, 47, 68 checks).

## What has stayed constant

The cost gate has outranked every model-choice rule since 2026-06-15. Judgment, taste, and
release decisions have never left the owning session. Every enforcement layer was built
after a dated failure of the prose rule, not in anticipation of one, and each one names the
incident it answers in its header comment.
