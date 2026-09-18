# Subscription budget preflight — module contract

A provider-neutral check: does a fresh usage snapshot plus a caller-supplied cost estimate clear a
configurable policy's thresholds for one named provider? It is a preflight, not a cost-write veto —
it never blocks writing code, only a specific automatic handoff to a specific provider.

Two independent gates exist in this repo and both must pass before an automatic handoff proceeds:
the core agent-ladder policy (model choice, delegation cost gate; documented elsewhere in this repo)
and this subscription budget preflight. Neither substitutes for the other.

**Scope of the shipped adapter:** `hooks/codex_window_gate.ps1` intercepts Claude-side Codex
launches only — a Bash/PowerShell command that invokes the `codex` binary, or an `Agent` tool call
whose `subagent_type` names codex. Other providers and other runtimes (Codex's own hooks, a
standalone script, a CI job) call `subscription_budget.ps1` directly; nothing here pretends to
intercept launches it cannot see.

## Files

- `hooks/subscription_budget.ps1` — the evaluator. Dot-source it for the
  `Get-SubscriptionBudgetDecision` function, or run it as a CLI.
- `hooks/codex_window_gate.ps1` — the one adapter that wires the evaluator into a Claude Code
  `PreToolUse` hook for Codex launches.
- `config/agent-ladder-policy.template.json` — unconfigured, public-safe policy template. Copy it,
  fill in real values, keep the copy private (it will carry account-specific thresholds).

Both `.ps1` files must be deployed side by side — `codex_window_gate.ps1` dot-sources
`subscription_budget.ps1` from its own directory (`$PSScriptRoot`).

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

## Codex adapter specifics (`codex_window_gate.ps1`)

- Provider key used: `openai`.
- Classifies a Bash/PowerShell command as a Codex launch by the same "invokes the codex binary,
  ignores mentions of it in text/paths" logic as the original hook; a cheap probe (`--version`,
  `--help`, `login status`) is exempt and never evaluated.
- Classifies an `Agent` tool call as a Codex launch when `subagent_type` matches `codex` (case
  insensitive).
- Exact request hash: lowercase SHA256 (UTF8) of the shell command line, or of
  `"<subagent_type>\n<prompt>"` for an Agent call. A decline names this exact hash so the calling
  agent can write a scoped estimate file with a matching `requestHash` and retry.
- Default paths (each overridable by env var for tests or a portable install):
  - policy: sibling `agent-ladder-policy.json` (`AGENT_LADDER_POLICY_PATH`)
  - usage: sibling `agent-ladder-usage.json` (`AGENT_LADDER_USAGE_PATH`)
  - estimate: `$env:TEMP/agent_ladder_estimates/<sanitized session id>.json`
    (`AGENT_LADDER_ESTIMATE_PATH`)
- No prompt word waives this check — there is no keyword bypass anywhere in the adapter or the
  evaluator. Owner-directed work is handled by the owner supplying a matching, fresh usage/estimate
  pair (or running the work outside this adapter's reach); the hook itself has no silent override.
- Failure modes: a parse/input error before classification (garbage stdin, an unrelated tool) fails
  open — exit 0, nothing blocked. Once a launch is classified as a real (non-probe) Codex handoff,
  any failure from that point on — missing policy, corrupt policy, missing/stale usage, missing or
  mismatched estimate — declines (exit 2). Unrelated tools are never evaluated at all.

## Setup

1. Copy `config/agent-ladder-policy.template.json` to a private path (e.g. beside the deployed hook),
   fill in `enabled`, `profileRevision`, and real window thresholds per provider.
2. Point a usage-refresh mechanism (not shipped here) at writing a fresh, normalized usage snapshot
   to the path `AGENT_LADDER_USAGE_PATH` names, at least as often as `maxUsageAgeMinutes`.
3. Have the calling agent write an estimate JSON with a matching `requestHash` before a Codex handoff
   it expects to pass, or accept the decline and run the work elsewhere.
4. Deploy `subscription_budget.ps1` and `codex_window_gate.ps1` together and wire the `PreToolUse`
   registration for `Bash`, `PowerShell`, and `Agent`.

## Testing

`tests/subscription_budget_tests.ps1` and `tests/codex_window_gate_tests.ps1` are
self-contained: synthetic fixtures only, no live provider state, no paid model calls. Both accept
relocated temp roots for portable/public CI use (`subscription_budget_tests.ps1 -WorkDir <path>`;
`codex_window_gate_tests.ps1` generates its own root under `$env:TEMP` per run) and clean up only the
exact child directory each run created.
