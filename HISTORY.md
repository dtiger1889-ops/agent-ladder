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

## What has stayed constant

The cost gate has outranked every model-choice rule since 2026-06-15. Judgment, taste, and
release decisions have never left the owning session. Every enforcement layer was built
after a dated failure of the prose rule, not in anticipation of one, and each one names the
incident it answers in its header comment.
