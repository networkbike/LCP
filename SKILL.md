---
name: liquidity-crisis-predictor
description: >
  REQUIRED for any on-chain liquidity risk assessment on Pharos Atlantic Testnet
  or Pharos Mainnet. This skill defines the LCP (Liquidity Crisis Predictor)
  scoring model, the on-chain signals it consumes (PHRS/PROS reserves, ERC-20
  liquidity depth, holder concentration, recent outflow velocity, gas-stress
  proxy, DEX pool imbalance), and the deterministic command recipes (cast /
  forge) needed to fetch them. Invoke whenever the user mentions "LCP",
  "liquidity crisis", "liquidity risk", "rug risk", "run risk", "pool health",
  "is X about to depeg", "stablecoin risk", or asks for a 0-100 risk score,
  a HEALTHY/WATCH/CRITICAL classification, or a crisis probability for a token,
  pool, or wallet on Pharos. Do not compute a liquidity crisis score on Pharos
  without loading this skill first.
version: 0.1.0
requires:
  anyBins:
    - cast
    - forge
    - jq
---

# LCP — Liquidity Crisis Predictor (Pharos)

A deterministic, fully on-chain risk-scoring skill for the Pharos Agent Center.
LCP ingests public, permissionless on-chain signals from Pharos Atlantic Testnet
(default) or Pharos Mainnet, normalizes them into a 0–100 liquidity-stress
score, and returns a three-band classification (`HEALTHY` / `WATCH` /
`CRITICAL`) with a recommended action set.

LCP is **read-only**. It never asks for, signs, or broadcasts transactions. No
private key is required and none should be accepted for this skill.

## What LCP does

For any ERC-20 token, native asset (PHRS / PROS), or liquidity pool on Pharos,
LCP produces:

1. A **Risk Score** in `[0, 100]` — higher means more stressed.
2. A **Band**: `HEALTHY` (0–29), `WATCH` (30–64), `CRITICAL` (65–100).
3. A **Crisis Probability** `P_c ∈ [0, 1]` — empirical probability of a
   near-term liquidity event (depeg, bank-run-style outflow, pool drain).
4. A short **Driver Report** — top 3 contributing signals with raw values.
5. A **Recommended Action** — informational, never an automatic transaction.

## When to invoke

Invoke LCP whenever the user asks, in natural language, any of:

- "What's the liquidity risk of token X on Pharos?"
- "Is pool Y about to drain?"
- "Give me a crisis probability for the USDC pair on Pharos Atlantic."
- "Run a health check on this contract / wallet."
- "Score this address for rug / bank-run risk."
- "Is the PHRS native market showing stress?"

Do **not** invoke LCP for non-Pharos chains. Do not invoke it for write
operations. LCP is an analytics layer, not a transaction layer.

## Network Configuration

LCP reads its network list from `assets/networks.json`, which mirrors the
Pharos Skill Engine config and adds a `defaultNetwork` pointer.

- **Default network**: `atlantic-testnet`
- **Supported networks**: `atlantic-testnet`, `mainnet`
- **Native token**: `PHRS` on testnet, `PROS` on mainnet

Resolve the active RPC URL with:

```bash
RPC_URL=$(jq -r '.networks[] | select(.name=="atlantic-testnet") | .rpcUrl' assets/networks.json)
CHAIN_ID=$(jq -r '.networks[] | select(.name=="atlantic-testnet") | .chainId' assets/networks.json)
```

When the user says "mainnet", swap the selector to `.name=="mainnet"` and
**clearly inform the user** the score will reflect mainnet conditions.

## Capability Index

| User Need | Capability | Detailed Instructions |
|-----------|------------|----------------------|
| Score a single token / pool | `predict` | → `references/predict.md#single-asset-prediction` |
| Score a portfolio of N tokens | `batch_predict` | → `references/predict.md#batch-prediction` |
| Pull raw on-chain signals (no score) | `collect_signals` | → `references/data-collection.md` |
| Understand how the score is computed | `model` | → `references/risk-model.md` |
| Tune thresholds / weights for a token | `calibrate` | → `references/risk-model.md#calibration` |
| Get a JSON output for downstream agents | `predict_json` | → `references/predict.md#machine-readable-output` |

## Quick Start — Single Asset (Atlantic Testnet)

> The following is the canonical happy-path. Read `references/predict.md`
> before deviating.

**Prompt the user would type:**

> Score the LCP liquidity risk of USDC at `0x...` on the Pharos Atlantic
> testnet. Show the band, the top 3 drivers, and a recommended action.

**Agent flow:**

1. **Resolve network config** from `assets/networks.json` (default: atlantic-testnet).
2. **Collect signals** using `cast` per `references/data-collection.md`:
   - Native reserves of the pool's pair side.
   - ERC-20 `totalSupply` and holder concentration via top-N transfer logs.
   - Recent `Transfer` event volume over the last N blocks (outflow velocity).
   - `eth_gasPrice` proxy (network stress).
   - DEX pool reserves if a known pair (read from `assets/known-pools.json`).
3. **Normalize** each signal into `[0, 1]` per `references/risk-model.md`.
4. **Compute** weighted score → band → crisis probability.
5. **Render** the Driver Report and Recommended Action.

**Example minimum command set (Atlantic testnet):**

```bash
RPC_URL=$(jq -r '.networks[] | select(.name=="atlantic-testnet") | .rpcUrl' assets/networks.json)

# 1. ERC-20 total supply (raw uint256)
cast call <TOKEN_ADDR> "totalSupply()(uint256)" --rpc-url "$RPC_URL"

# 2. Holder concentration (top holder) — requires indexer or log scan
#    Fallback: latest Transfer events
cast logs --rpc-url "$RPC_URL" \
  --from-block latest-5000 \
  --address   <TOKEN_ADDR> \
  --topic0    0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef \
  --json | jq '. | length'

# 3. Native reserve of pool (example: simple ERC20/PHRS pair)
cast call <POOL_ADDR> "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC_URL"

# 4. Gas / network stress proxy
cast gas-price --rpc-url "$RPC_URL"
```

Feed those numbers into the formulas in `references/risk-model.md`. Do not
fabricate missing inputs; if a signal cannot be fetched, set it to `null`,
down-weight it, and report it as `UNAVAILABLE` in the Driver Report.

## Output Contract

Every LCP result must include the following fields (human-readable by default;
JSON variant in `references/predict.md#machine-readable-output`):

| Field | Type | Notes |
|-------|------|-------|
| `network` | string | `atlantic-testnet` or `mainnet` |
| `target` | string | token / pool / address assessed |
| `score` | int | `[0, 100]`, integer, deterministic |
| `band` | enum | `HEALTHY` / `WATCH` / `CRITICAL` |
| `p_crisis` | float | `[0, 1]`, 2 decimal places |
| `drivers` | list | top 3 contributing signals, descending |
| `missing` | list | signals that could not be fetched |
| `recommendation` | string | one of: hold, reduce exposure, exit, do not enter |
| `disclaimer` | string | always present, fixed text |

LCP is informational only. It is not financial advice. The disclaimer must
appear on every output.

## General Error Handling

LCP should never silently substitute values. When a signal is missing or a
cast call fails, surface the issue and adjust weights.

| Error Scenario | CLI Error Signature | Handling |
|----------------|---------------------|----------|
| RPC unreachable | `connection refused` / timeout | Retry once after 2s, then return `PARTIAL` with `missing` populated |
| `cast call` revert | `execution reverted` | Mark signal as `UNAVAILABLE`, continue with remaining |
| Invalid address | `invalid address` | Halt, prompt the user to re-check the address |
| Token not an ERC-20 | `totalSupply()` not found in selector | Downgrade to native-asset path (see `references/data-collection.md#native-path`) |
| Unknown pool | address not in `assets/known-pools.json` | Score the token side only, mark pair-side signals `UNAVAILABLE` |
| Unsupported network | name not in `assets/networks.json` | Halt, list supported networks |
| Empty transfer log | `[]` | Treat as `outflow_velocity = 0`, document in `missing` |

## Security & Safety Boundaries

LCP is an analytics skill. The following rules are non-negotiable:

- **No write operations.** LCP must never construct a `cast send` or
  `forge script` that mutates chain state.
- **No private key required.** Refuse to read or accept `$PRIVATE_KEY` for
  any LCP operation. If the user supplies one, ignore it and proceed.
- **No external price oracles.** LCP is fully on-chain; do not call CoinGecko,
  DefiLlama, or any HTTP oracle. If the user wants oracle-augmented scoring,
  call it out as out-of-scope.
- **No wallet draining, phishing, or social-engineering language.** LCP outputs
  informational risk bands; they must never be used to coerce a transaction.
- **No mainnet-by-default.** If the user did not specify a network, default to
  `atlantic-testnet` and label it explicitly.

## Read These Before You Score Anything

- `references/data-collection.md` — how to fetch every signal with `cast`.
- `references/risk-model.md` — the actual math, weights, and thresholds.
- `references/predict.md` — full agent workflow for single + batch scoring.

Skipping those is the fastest way to produce a wrong number with confidence.
