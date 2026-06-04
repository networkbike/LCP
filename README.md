# LCP — Liquidity Crisis Predictor

A deterministic, read-only on-chain analytics skill that produces a
**0–100 liquidity-stress score**, a **HEALTHY / WATCH / CRITICAL** band, a
**crisis probability**, and the **top contributing signals** for any ERC-20
token, liquidity pool, or native asset on Pharos.

LCP consumes only public on-chain data via `cast` and `forge`. It does not
sign, send, or propose any transaction. It does not call any external HTTP
oracle. It does not require a private key.

---

## Overview

Given a target (token, pool, or `native:PHRS` / `native:PROS`) on a Pharos
network, LCP:

1. Pulls seven on-chain signals (reserves, outflow velocity, holder
   concentration, pool imbalance, gas stress, liquidity age, supply growth)
   directly from RPC.
2. Normalizes each signal into `[0, 1]` and weights them per
   `assets/lcp-thresholds.json`.
3. Maps the weighted sum to a band and a logistic crisis probability.
4. Returns a driver report (top 3 contributors) and an informational
   recommendation.

All math is deterministic. Same inputs and block height → same score.

## Network

| Parameter | Value |
|-----------|-------|
| Primary network | **Pharos Mainnet** |
| Secondary network | Pharos Atlantic Testnet (development & calibration) |
| Chain ID (mainnet) | 1672 |
| Chain ID (testnet) | 688689 |
| Native token (mainnet) | PROS |
| Native token (testnet) | PHRS |
| Default when unspecified | mainnet |

Network details, RPC endpoints, and explorer URLs live in
`assets/networks.json`. The `defaultNetwork` field is set to `mainnet`; the
Agent uses it whenever the user does not name a network.

## Framework

| Item | Value |
|------|-------|
| Format | Pharos Skill Engine `.md` skill with YAML frontmatter |
| Required binaries | `cast`, `forge`, `jq`, `bc` |
| Required runtime | Foundry (`curl -L https://foundry.paradigm.xyz \| bash`) |
| Optional CLI | `examples/score.sh` (single-asset scorer) |
| Wallet / private key | **not required, not accepted** |
| Write operations | **none** |
| External oracles | **none** |

## Repository layout

```
LCP/
├── SKILL.md                    # skill manifest (frontmatter + body)
├── README.md                   # this file
├── LICENSE                     # MIT
├── assets/
│   ├── networks.json           # Pharos RPC + chain IDs
│   ├── lcp-thresholds.json     # weights, bands, thresholds, policy
│   └── known-pools.json        # optional pool registry
├── references/
│   ├── data-collection.md      # how to fetch every signal with `cast`
│   ├── risk-model.md           # the math + calibration procedure
│   └── predict.md              # single + batch + JSON workflows
├── examples/
│   ├── score-token.md          # worked example
│   ├── sample-output.json      # machine-readable LCP result
│   └── score.sh                # copy-paste shell recipe
└── .github/
    └── ISSUE_TEMPLATE.md
```

## Installation

Drop the `LCP/` directory into the Skills path of your Agent framework.

| Framework | Path |
|-----------|------|
| OpenClaw  | `~/.openclaw/skills/LCP/` |
| Claude Code | `~/.claude/skills/LCP/` |
| Codex     | `~/.codex/skills/LCP/` |
| Project-level | `<your-project>/skills/LCP/` |

Verify the skill is loaded:

```bash
# OpenClaw
openclaw skills list | grep liquidity-crisis-predictor

# Claude Code / Codex
/skills
```

## Prerequisites

- [`cast` and `forge`](https://book.getfoundry.sh/) from **Foundry**
- `jq` ≥ 1.6
- `bc` (any version)
- Outbound HTTPS to the Pharos RPC

LCP does not require a wallet, a private key, a seed phrase, or any API
token.

## Usage

### Single asset

> LCP, score the liquidity risk of `0xYourToken...` on Pharos mainnet. Show
> the band, top 3 drivers, and a recommendation.

### Native asset

> LCP, score `native:PROS` on Pharos mainnet.

### Batch

> LCP, score these on Pharos mainnet: `0xAAA..., 0xBBB..., native:PROS`.
> Output a sorted table.

### JSON for downstream agents

> LCP, score `0xYourToken...` on Pharos mainnet. Return JSON, schema
> `lcp.result.v1`.

The output object is fixed-shape; its first key is always `schema` with value
`"lcp.result.v1"`. See `examples/sample-output.json`.

### CLI (no Agent required)

```bash
./examples/score.sh 0xYourToken... mainnet
# or
./examples/score.sh native:PROS mainnet
# or, for JSON
LCP_JSON=1 ./examples/score.sh 0xYourToken... mainnet
```

## Output contract

Every LCP result includes:

| Field | Type | Notes |
|-------|------|-------|
| `network` | string | `mainnet` or `atlantic-testnet` |
| `target` | string | token / pool / `native:PROS` / `native:PHRS` |
| `score` | int | `[0, 100]`, integer, deterministic |
| `band` | enum | `HEALTHY` (0–29) / `WATCH` (30–64) / `CRITICAL` (65–100) |
| `p_crisis` | float | `[0, 1]`, two decimals, logistic mapping |
| `drivers` | list | top 3 contributing signals, descending |
| `missing` | list | signals that could not be fetched |
| `recommendation` | string | `hold` / `reduce exposure` / `do not enter` |
| `disclaimer` | string | always present, fixed text |

## Tunability

All thresholds, weights, and bands live in `assets/lcp-thresholds.json`. A
maintainer can:

- Adjust band cutoffs (`healthy_max`, `watch_max`, `critical_min`).
- Rebalance the seven signal weights (must sum to ≤ 1.0; rescaled at
  runtime when signals are missing).
- Tweak the crisis-probability logistic (`k`, `x0`).

The empirical calibration procedure is documented in
`references/risk-model.md#calibration`.

## Safety properties

- **Read-only.** No `cast send`, no `forge script`, no transaction
  construction of any kind.
- **No private key.** LCP refuses to read or accept `$PRIVATE_KEY`. The CLI
  exits with code 77 if one is set in the environment.
- **No external HTTP.** All signals come from the Pharos RPC. No price
  oracles, no analytics APIs, no telemetry.
- **Honest about missing data.** Missing signals are down-weighted, never
  fabricated. They are always listed in the `missing` field of the output.
- **No mainnet-by-default on writes** is moot here — LCP makes no writes.
  Mainnet is the default read network because that is the network users
  actually need assessed.
- **Informational only.** The `recommendation` field is descriptive, not
  prescriptive. LCP is not financial advice.

## License

MIT — see `LICENSE`.
