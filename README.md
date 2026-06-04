# LCP — Liquidity Crisis Predictor

> A read-only on-chain analytics Skill for the **Pharos Agent Center**.
> Submit a token, a pool, or the native asset; LCP returns a deterministic
> 0–100 liquidity-stress score, a band (`HEALTHY` / `WATCH` / `CRITICAL`),
> a crisis probability, the top three contributing signals, and a
> recommendation.

> ⚠️ **LCP is informational only. It is not financial advice. It never asks
> for, signs, or broadcasts transactions.**

---

## What LCP does

Given any ERC-20 token, liquidity pool, or native asset (PHRS / PROS) on
Pharos Atlantic Testnet (default) or Pharos Mainnet, LCP:

1. Pulls seven on-chain signals via `cast` / `forge`:
   - `reserve_depth` — primary pool USD-equivalent depth
   - `outflow_velocity` — recent Transfer volume / totalSupply
   - `holder_concentration` — H1 share
   - `pool_imbalance` — deviation from design ratio
   - `gas_stress` — current gas vs 200-block median
   - `liquidity_age` — blocks since first AddLiquidity
   - `supply_growth` — totalSupply drift
2. Normalizes each into `[0, 1]` and weights them per
   `assets/lcp-thresholds.json`.
3. Maps the weighted sum to a band and a logistic crisis probability.
4. Returns a driver report (top 3 contributors) and a recommendation
   (`hold` / `reduce exposure` / `do not enter`).

All math is deterministic. Same inputs → same score.

## What LCP does **not** do

- It does **not** send transactions, deploy contracts, or move funds.
- It does **not** read or accept a private key.
- It does **not** call any external HTTP oracle (CoinGecko, DefiLlama, etc.).
- It does **not** make a recommendation you should treat as advice.

## Repository layout

```
LCP/
├── SKILL.md                    # Skill manifest (frontmatter + body)
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

LCP is a pure-Skill asset; no code is compiled. Drop the `LCP/` directory
into the Skills path of your Agent framework:

| Framework | Path |
|-----------|------|
| OpenClaw  | `~/.openclaw/skills/LCP/` |
| Claude Code | `~/.claude/skills/LCP/` |
| Codex     | `~/.codex/skills/LCP/` |
| Project-level | `<your-project>/skills/LCP/` |

Verify:

```bash
# OpenClaw
openclaw skills list | grep liquidity-crisis-predictor

# Claude Code / Codex
/skills
```

## Prerequisites

- [`cast`](https://book.getfoundry.sh/) and `forge` from **Foundry**
- `jq` ≥ 1.6
- `bc` (any version)
- An outbound HTTPS connection to the Pharos RPC

LCP does not require a private key, a wallet, or any seed phrase.

## Usage — single asset

Ask your Agent:

> LCP, score the liquidity risk of `0xYourToken...` on Pharos Atlantic
> testnet. Show the band, top 3 drivers, and a recommendation.

The Agent loads `SKILL.md`, follows `references/predict.md`, and prints a
report like the one in `examples/sample-output.json`.

## Usage — batch

> LCP, score these tokens on Atlantic testnet: `0xAAA..., 0xBBB..., native:PHRS`
> Output as a sorted table.

The Agent runs the single-asset workflow for each target and emits a summary
table.

## Usage — JSON for downstream agents

> LCP, score `0xYourToken...` on Atlantic testnet. Return JSON, schema
> `lcp.result.v1`.

The output is a single object whose first key is `schema` (always
`lcp.result.v1`). See `examples/sample-output.json` for the full schema.

## Tunability

All thresholds, weights, and bands live in `assets/lcp-thresholds.json`. A
maintainer can:

- Adjust band cutoffs (`healthy_max`, `watch_max`, `critical_min`).
- Rebalance the seven weights (must sum to ≤ 1.0; rescaled at runtime if
  signals are missing).
- Tweak the crisis-probability logistic (`k`, `x0`).

See `references/risk-model.md#calibration` for the empirical procedure.

## Security

- LCP is **read-only**. It does not sign, send, or propose any transaction.
- LCP **must not** be combined with a private key. If the host environment
  has `$PRIVATE_KEY` set, LCP ignores it.
- LCP does not call external HTTP oracles; all signals are on-chain.
- The Skill is informational. It must never be used to construct
  wallet-draining, phishing, or social-engineering flows.

## Compliance with the Pharos Skill Builder Campaign

- ✅ Original implementation
- ✅ Public on GitHub: `https://github.com/networkbike/LCP`
- ✅ Includes usage instructions (`SKILL.md` + `references/` + `examples/`)
- ✅ Functional: deterministic score from on-chain signals
- ✅ Relevant to Pharos Agent Center (reads Pharos chains, uses `cast` /
  `forge`)
- ✅ No malicious code, no wallet-drainer, no phishing logic

## License

MIT — see `LICENSE`.
