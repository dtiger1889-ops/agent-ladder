# Subscription-aware routing — protecting a scarce provider pool

This repo ships two independent pieces for keeping an automatic handoff from burning a subscription
pool you need later. Both are preflights, not cost-write vetoes — neither ever blocks writing code,
only a specific automatic handoff to a specific provider:

1. **The live Codex gate (`hooks/codex_window_gate.ps1`) — a threshold gate.** This is the one wired
   into a Claude Code `PreToolUse` hook. It fires when a Bash/PowerShell command actually invokes the
   `codex` binary, or when an `Agent` call's `subagent_type` names codex, reads Codex's own
   rate-limit snapshot (from its rollout logs), and blocks the handoff (exit 2) when a window is over
   its configured used-percent limit. It **fails open** on unknown usage — a once-per-session
   advisory, never a block — and never reads a caller estimate. This is the simple, recommended path.
2. **The optional estimate-based evaluator (`hooks/subscription_budget.ps1`) — provider-neutral.**
   A stricter check for callers who want it: does a fresh usage snapshot plus a caller-supplied cost
   estimate clear a configurable policy for one named provider? It **fails closed** on missing data,
   so it needs a usage feeder and a per-request estimate. The Codex gate does NOT use it; other
   providers or runtimes (a standalone script, a CI job) can call it directly.

## Files

- `hooks/codex_window_gate.ps1` — the live threshold gate (above). Reads Codex's rollout logs; reads
  its per-window limits from the policy file (see below); depends on nothing else.
- `hooks/subscription_budget.ps1` — the optional provider-neutral estimate evaluator. Dot-source it
  for the `Get-SubscriptionBudgetDecision` function, or run it as a CLI. Not on the Codex gate's path.
- `config/agent-ladder-policy.template.json` — unconfigured, public-safe policy template. Copy it,
  fill in real values, keep the copy private (it will carry account-specific thresholds).

### The Codex gate's thresholds (tunable)

The gate reads `providers.openai.windows.<fiveHour|weekly>.maxUsedPercent` from a policy JSON — by
default `agent-ladder-policy.json` beside the hook, override with env `AGENT_LADDER_POLICY_PATH`. It
blocks when that window's `used_percent` exceeds the number. Edit those numbers to tune it. If the
file is missing or unreadable it keeps safe built-in defaults (5-hour 70, weekly 75) and still gates.
The remaining policy fields below (`minRemainingBefore`, `reserveAfter`, `maxJobPercentPoints`,
freshness bounds) drive the optional evaluator, not the Codex gate.

## Policy schema (per provider key, e.g. `anthropic`, `openai`)

```
{
  "version": 1,
  "priorityOrder": ["anthropic", "openai"],
  "providers": {
    "<providerKey>": {
      "enabled": true,
      "profileRevision": "<free-text label, bump it whenever plan/model/effort calibration changes>",
      "maxUsageAgeMinutes": 5,
      "maxEstimateAgeMinutes": 1440,
      "windows": {
        "<windowKey>": {
          "windowDurationMins": 300,
          "minRemainingBefore": 10,
          "reserveAfter": 5,
          "maxJobPercentPoints": 20
        }
      }
    }
  }
}
```

- `priorityOrder` is metadata for a caller choosing which provider to try first; the evaluator never
  reads it and has no built-in provider preference.
- Window keys are arbitrary strings (`fiveHour`, `weekly`, or anything else) — the evaluator requires
  at least one configured window and validates every one it finds; nothing is hardcoded to a specific
  provider's actual reset cadence.
- `minRemainingBefore` / `reserveAfter` / `maxJobPercentPoints` are **your policy choices** (0–100 /
  0–100 / >0–100), not a vendor-published limit. `profileRevision` is a label you control; there is no
  plan-to-token conversion anywhere in the evaluator.
- A window left at `null` thresholds (as shipped in the template) is treated as unconfigured and
  always declines — filling in real numbers is what turns a provider on, not just `enabled: true`.

## Usage snapshot schema (caller-supplied, per evaluation)

```
{
  "provider": "<providerKey>",
  "profileRevision": "<must match the policy's configured profileRevision for that provider>",
  "observedAt": "<UTC ISO 8601 timestamp>",
  "source": "<nonempty provenance, e.g. path to the raw snapshot this was read from>",
  "windows": {
    "<windowKey>": { "usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1234567890 }
  }
}
```

Every window the policy configures must appear here with a matching `windowDurationMins` and a
`resetsAt` (Unix seconds) strictly in the future — a window whose reset has already passed is
**unknown**, never treated as freshly reset to zero. `observedAt` must be within
`maxUsageAgeMinutes` of now and not more than 60 seconds in the future (clock-skew allowance only).

## Request estimate schema (caller-supplied, per evaluation)

```
{
  "provider": "<providerKey>",
  "profileRevision": "<must match policy>",
  "observedAt": "<UTC ISO 8601 timestamp>",
  "source": "<measurement or upper-bound rationale, nonempty>",
  "requestHash": "<lowercase SHA256 hex of the exact request>",
  "spendPercentPoints": { "<windowKey>": 5 }
}
```

`requestHash` must equal the hash the adapter computed for **this specific request** (see below) —
a stale estimate from an earlier request never silently covers a new one. Every configured window
needs a `spendPercentPoints` entry that is a positive number (`> 0`, `<= 100`) — an estimate of zero
is never accepted as a free pass. The caller is expected to supply a conservative upper bound that
already accounts for any other work it knows is running concurrently against the same window; this
check re-evaluates one request at a time, it does not reserve or track concurrency itself.

## What "allowed" actually means

For each configured window: `remaining = 100 - usedPercent`. The request passes that window only if
`remaining >= minRemainingBefore`, `remaining - estimate >= reserveAfter`, and
`estimate <= maxJobPercentPoints`. All configured windows must pass. Any missing, stale, mismatched,
or invalid input is a decline — never an implicit allow, and never an implicit zero-cost estimate.

This is not a hard spend cap and not a concurrency reservation: it is a point-in-time preflight
against a snapshot the caller supplied. A long-running or high-fan-out job should re-evaluate at
bounded steps (e.g. before each new Codex handoff), not assume one green check covers everything
that follows.

## Codex gate specifics (`codex_window_gate.ps1`)

The live gate is the threshold gate, not the estimate evaluator above.

- Provider windows read: `openai` → `fiveHour` and `weekly` `maxUsedPercent` (see "The Codex gate's
  thresholds" near the top).
- Classifies a Bash/PowerShell command as a Codex launch when it invokes the `codex` binary (or the
  documented `"<stdin>" | & $codex exec ...` shim shape), ignoring mere mentions of "codex" in text
  or paths; a cheap probe (`--version`, `--help`, `login status`) is exempt and never evaluated.
- Classifies an `Agent` tool call as a Codex launch when `subagent_type` matches `codex` (case
  insensitive).
- Usage source: Codex's own rollout logs under `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl`
  (env `CODEX_WINDOW_GATE_SESSIONS` overrides the root for tests). It reads the newest snapshot whose
  window has not already reset; a window past its reset reads as unknown, never as freshly-zero.
- Decision: blocks (exit 2) only on a KNOWN breach — a window whose live `used_percent` exceeds its
  configured `maxUsedPercent`. Unknown usage (no readable snapshot, or every window already reset)
  never blocks: it prints a once-per-session advisory and exits 0. An unrelated tool, and a
  parse/input error before classification, are never evaluated (exit 0).
- No prompt word waives it — there is no keyword bypass. To proceed anyway the user runs the work on
  the other agent, waits for the window to reset, or raises the limit in the policy file.

## Setup

**The Codex gate (recommended):**
1. Put `codex_window_gate.ps1` in your hooks directory and register it as a `PreToolUse` hook for
   `Bash`, `PowerShell`, and `Agent`.
2. Optionally drop an `agent-ladder-policy.json` beside it (copy the template) and set
   `providers.openai.windows.fiveHour.maxUsedPercent` / `weekly.maxUsedPercent`. Without the file it
   uses safe defaults (5-hour 70, weekly 75).

**The optional estimate evaluator (only if you want the stricter, fail-closed check):**
1. Copy `config/agent-ladder-policy.template.json` to a private path and fill in `enabled`,
   `profileRevision`, and real window thresholds per provider.
2. Point a usage-refresh mechanism (not shipped here) at writing a fresh, normalized usage snapshot
   to `AGENT_LADDER_USAGE_PATH`, at least as often as `maxUsageAgeMinutes`.
3. Have the calling agent write an estimate JSON with a matching `requestHash` before a handoff it
   expects to pass, or accept the decline. Deploy `subscription_budget.ps1` where your caller can
   dot-source or invoke it.

## Testing

`tests/subscription_budget_tests.ps1` and `tests/codex_window_gate_tests.ps1` are
self-contained: synthetic fixtures only, no live provider state, no paid model calls. Both accept
relocated temp roots for portable/public CI use (`subscription_budget_tests.ps1 -WorkDir <path>`;
`codex_window_gate_tests.ps1` generates its own root under `$env:TEMP` per run) and clean up only the
exact child directory each run created.
