# LCP — Prediction Workflow

This is the canonical Agent workflow for producing an LCP result. It supports
single-asset scoring, batch scoring, and machine-readable output.

## 1. Single-Asset Prediction

### 1.1 Inputs (from user prompt)

- `target` — ERC-20 address, pool address, or `native:PROS` / `native:PHRS`.
- `network` — optional; default `mainnet`. Use `atlantic-testnet` only when
  the user explicitly asks for it.
- `format` — optional; `human` (default) or `json`.

### 1.2 Steps

1. **Bootstrap** — resolve `RPC_URL`, `CHAIN_ID`, sanity-check the chain.
2. **Pre-check** — verify `cast`, `forge`, `jq`, `bc` on `PATH`. Validate the
   `target` format. Reject if a `$PRIVATE_KEY` was supplied.
3. **Collect signals** — per `references/data-collection.md`. If the target
   is `native:*`, take the native path; otherwise the ERC-20 path; if a pool
   address matches `assets/known-pools.json`, layer the pool path on top.
4. **Normalize** — per `references/risk-model.md` §2.
5. **Weight** — per `references/risk-model.md` §3.
6. **Score** — per `references/risk-model.md` §4.
7. **Band + p_crisis** — per `references/risk-model.md` §5–6.
8. **Driver report** — top 3 contributors per §7.
9. **Recommendation** — per §8.
10. **Render** — human or JSON per §3 below.

### 1.3 Example prompt

> LCP: assess the liquidity risk of `0xToken...` on Pharos mainnet. Show
> the score, band, top 3 drivers, and a recommendation.

### 1.4 Example human output

```
LCP — Liquidity Crisis Predictor
Network:   Pharos Mainnet (mainnet)
Target:    0xToken...
Score:     72 / 100
Band:      CRITICAL
P(crisis): 0.91

Top drivers:
  1. outflow_velocity     raw=0.142  norm=1.00  contrib=0.40
  2. reserve_depth        raw=41200  norm=0.95  contrib=0.24
  3. pool_imbalance       raw=0.41   norm=1.00  contrib=0.15

Missing: liquidity_age, gas_stress

Recommendation: do not enter

Disclaimer: LCP is an informational on-chain analytics signal. It is not
financial advice. On-chain conditions can change between the read and any
subsequent action.
```

## 2. Batch Prediction

When the user supplies multiple targets (CSV, JSON array, or comma-separated
addresses), run each through §1 in series and emit a summary table.

### 2.1 Input format (CSV)

```csv
target,network
0xTokenA...,mainnet
0xTokenB...,mainnet
native:PROS,mainnet
```

### 2.2 Output table

| Target | Network | Score | Band | P(crisis) | Recommendation |
|--------|---------|-------|------|-----------|----------------|
| `0xTokenA...` | mainnet     | 12  | HEALTHY  | 0.05 | hold |
| `0xTokenB...` | mainnet     | 72  | CRITICAL | 0.91 | do not enter |
| `native:PROS` | mainnet     | 28  | HEALTHY  | 0.13 | hold |

Sort by `score` descending unless the user specifies otherwise.

## 3. Machine-readable output

When `format=json`, emit a single object per target:

```json
{
  "schema": "lcp.result.v1",
  "network": "mainnet",
  "target": "0xToken...",
  "score": 72,
  "band": "CRITICAL",
  "p_crisis": 0.91,
  "drivers": [
    { "signal": "outflow_velocity",  "raw": 0.142, "norm": 1.00, "contrib": 0.40 },
    { "signal": "reserve_depth",     "raw": 41200, "norm": 0.95, "contrib": 0.24 },
    { "signal": "pool_imbalance",    "raw": 0.41,  "norm": 1.00, "contrib": 0.15 }
  ],
  "missing": ["liquidity_age", "gas_stress"],
  "recommendation": "do not enter",
  "disclaimer": "LCP is an informational on-chain analytics signal. It is not financial advice."
}
```

The `schema` field is fixed at `"lcp.result.v1"` and MUST be the first key,
so downstream agents can dispatch on it before parsing the rest.

## 4. Caching

Within a single Agent session, LCP results for the same
`(target, network, block_height)` MAY be cached for the duration of the
session. Do not cache across sessions — on-chain state can change and the
result is no longer fresh.

## 5. Failure modes

| Condition | Behavior |
|-----------|----------|
| Target malformed | Halt; ask the user to re-supply |
| Network not in `assets/networks.json` | Halt; list supported networks |
| All signals `UNAVAILABLE` | Return `band = WATCH`, `p_crisis = 0.5`, `drivers = []` |
| RPC timeout after retry | Return `band = WATCH`, populate `missing` with `rpc` |
| Mixed availability | Proceed with present signals, document in `missing` |

The Agent must never silently substitute fake values. If you cannot compute
the score honestly, say so.

## 6. Safety re-confirmation (internal, not output)

Before any output the Agent must confirm internally:

1. It did not call `cast send` or `forge script`.
2. It did not sign any transaction.
3. It did not request or read `$PRIVATE_KEY`.

These checks are an internal invariant. They are not output to the user.

## 7. Worked end-to-end example

See `examples/score-token.md` and `examples/sample-output.json` for a
complete trace from prompt to result.
