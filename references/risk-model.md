# LCP — Risk Model

This document defines the LCP (Liquidity Crisis Predictor) scoring math. It is
intentionally simple, deterministic, and reproducible: given the same inputs
and thresholds, the score is bit-identical.

## 1. Inputs

After `references/data-collection.md` has run, the Agent holds a `signals`
object:

```json
{
  "reserve_depth":      <float|null>,
  "outflow_velocity":   <float|null>,
  "holder_concentration": <float|null>,
  "pool_imbalance":     <float|null>,
  "gas_stress":         <float|null>,
  "liquidity_age":      <int|null>,
  "supply_growth":      <float|null>
}
```

Weights `w_i` and per-signal thresholds are read from
`assets/lcp-thresholds.json`.

## 2. Normalization

Each signal is mapped into `[0, 1]`, where `0` = healthy and `1` = max stress.

### 2.1 Continuous (lower-is-risky)

For `reserve_depth` (deeper = healthier) and `liquidity_age` (older = healthier):

```
norm(x) = clamp01( (T_watch - x) / (T_watch - T_critical) )
```

- If `x >= T_watch` (healthy region) → `0`
- If `x <= T_critical` (critical region) → `1`
- Linear in between.

### 2.2 Continuous (higher-is-risky)

For `outflow_velocity`, `holder_concentration`, `pool_imbalance`, `gas_stress`,
`supply_growth`:

```
norm(x) = clamp01( (x - T_watch) / (T_critical - T_watch) )
```

### 2.3 `clamp01`

```python
def clamp01(x):
    return max(0.0, min(1.0, x))
```

## 3. Weight Handling With Missing Signals

Let `S_present` be the set of signals with a non-null value. Define:

```
W_total = sum( w_i for i in S_present )
w_i'    = w_i / W_total   for i in S_present
```

If a signal is `null`, the Agent uses the `missing_policy` from
`lcp-thresholds.json` to substitute a normalized value **after** `W_total`
rescaling:

- `downweight_to_neighbors` → drop, renormalize.
- `assume_worst` → set `norm_i = 1.0`.
- `assume_best` → set `norm_i = 0.0`.

## 4. Composite Score

```
score_raw = sum( w_i' * norm_i )           # in [0, 1]
score     = round( 100 * score_raw )       # in [0, 100], integer
```

## 5. Band

```
HEALTHY    if 0  <= score <= 29
WATCH      if 30 <= score <= 64
CRITICAL   if 65 <= score <= 100
```

Thresholds are in `lcp-thresholds.json > bands`.

## 6. Crisis Probability

Logistic mapping from score to a probability of a near-term (~24h) liquidity
event:

```
p_crisis = 1 / (1 + exp( -k * (score - x0) ))
```

Defaults: `k = 0.12`, `x0 = 60`. Tunable in `lcp-thresholds.json > crisis_probability`.

- `score = 0`  → `p_crisis ≈ 0.0007`
- `score = 30` → `p_crisis ≈ 0.024`
- `score = 60` → `p_crisis ≈ 0.500`
- `score = 90` → `p_crisis ≈ 0.973`

## 7. Driver Report

Sort `[(i, w_i' * norm_i) for i in S_present]` by contribution descending.
Return the top 3 as the human-readable driver list:

```
1. <signal_id>  raw=<value>  norm=<0..1>  contrib=<0..1>
2. ...
3. ...
```

The driver list is the only place raw signal values appear in the output.

## 8. Recommendation

Look up `recommendation_rules` in `lcp-thresholds.json`:

| Band | Action |
|------|--------|
| `HEALTHY`  | `hold` |
| `WATCH`    | `reduce exposure` |
| `CRITICAL` | `do not enter` |

The action is purely informational. LCP must never construct a `cast send`
or `forge script` based on the recommendation.

## 9. Calibration

A maintainer may retune LCP for a specific token by editing
`assets/lcp-thresholds.json`. The JSON schema is:

```json
{
  "weights": { "<signal>": <float in [0,1]>, ... },
  "signals": {
    "<signal>": {
      "healthy_above": <num>,
      "watch_above":   <num>,
      "critical_below":<num>
    }
  }
}
```

After any edit, re-run the example in `examples/sample-output.md` to confirm
the score is still deterministic and within `[0, 100]`.

### Calibration Procedure

1. Collect at least 30 historical Pharos events (depegs, drains, healthy days).
2. For each event, record the seven LCP signal values at `t = T - 1 block`.
3. Fit weights via constrained least squares minimizing Brier score of
   `p_crisis` against the binary event label.
4. Re-fit per-signal thresholds via isotonic regression so that `norm(x)`
   monotonicity holds.
5. Validate on a held-out set; require Brier `< 0.20` and AUC `> 0.75`.

Out-of-the-box weights are conservative and biased toward `HEALTHY`. This is
intentional for a public skill — false positives in liquidity risk are
cheaper than false negatives for users, but not by much.

## 10. Determinism Guarantees

Given:

- A fixed `assets/lcp-thresholds.json`
- A fixed network and block height
- The same input addresses

LCP produces:

- The same `score` (integer)
- The same `band`
- The same `p_crisis` (to 2 decimals)
- The same `drivers` order

Floating-point sensitivity is bounded to ±1 score point by the final
`round()`. The Agent must not introduce additional nondeterminism (no
timestamps, no random sampling, no LLM-judged inputs).

## 11. What LCP is Not

- Not a price oracle. No external prices are consulted.
- Not a wallet drainer, swap router, or transaction builder.
- Not a substitute for human judgment. The disclaimer is non-negotiable.
- Not predictive of black-swan events. LCP captures on-chain mechanical
  stress; it cannot see off-chain catalysts (governance attacks, key
  compromise, regulatory action).
