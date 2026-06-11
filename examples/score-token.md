# Example — Score a Single Token

This is a complete, copy-pasteable trace of an LCP run for a fictional ERC-20
token on Pharos Mainnet. All values are illustrative.

## 1. User prompt

> LCP, score the liquidity risk of `0xExampleToken0000000000000000000000000000000abc`
> on Pharos mainnet. Show the band, top 3 drivers, and a recommendation.
> Return JSON, schema `lcp.result.v1`.

## 2. Agent loads the Skill

The Agent opens `SKILL.md`, sees this is a Pharos read-only analytics task,
and reads `references/data-collection.md`, `references/risk-model.md`, and
`references/predict.md`.

## 3. Bootstrap

```bash
RPC_URL=$(jq -r '.networks[] | select(.name=="mainnet") | .rpcUrl' assets/networks.json)
# https://rpc.pharos.xyz

cast chain-id --rpc-url "$RPC_URL"
# 1672
```

## 4. Signal collection

```bash
TOKEN=0xExampleToken0000000000000000000000000000000abc

# totalSupply
SUPPLY=$(cast call "$TOKEN" "totalSupply()(uint256)" --rpc-url "$RPC_URL")

# transfer-log window
WINDOW=5000
LATEST=$(cast block-number --rpc-url "$RPC_URL")
FROM=$((LATEST - WINDOW))

cast logs --rpc-url "$RPC_URL" \
  --from-block "$FROM" --to-block "$LATEST" \
  --address   "$TOKEN" \
  --topic0    0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef \
  --json > /tmp/lcp_transfers.json
```

(Outputs elided for brevity; the example numbers in §5 are what the Agent
would compute from the real RPC response.)

## 5. Normalized signals (illustrative)

| Signal | Raw | norm | Weight | Contribution |
|--------|-----|------|--------|--------------|
| `outflow_velocity`    | 0.142  | 1.00 | 0.20 | 0.40 |
| `reserve_depth`       | 41,200 | 1.00 | 0.25 | 0.25 |
| `pool_imbalance`      | 0.41   | 1.00 | 0.15 | 0.15 |
| `holder_concentration`| 0.18   | 0.00 | 0.15 | 0.00 |
| `gas_stress`          | UNAVAILABLE | — | 0.10 | dropped |
| `liquidity_age`       | UNAVAILABLE | — | 0.10 | dropped |
| `supply_growth`       | 0.01   | 0.00 | 0.05 | 0.00 |

After dropping the two missing signals, weights are rescaled to sum to 1.0
within the present set, then the weighted sum is computed.

Note: `reserve_depth` of 41,200 falls in the `critical_below` region
because `watch_above == critical_below == 100,000` in the current
thresholds file — the `norm()` helper treats this as a step at the
watch boundary, giving `norm = 1.0`. Future calibration may split the
boundary into a non-zero-width band; the math handles either form.

## 6. Score

```
score_raw = 0.40 + 0.25 + 0.15 + 0.00 + 0.00 = 0.80
score     = round(100 * 0.80) = 80
```

(The saved sample-output.json uses 79 — the difference is rounding of
`outflow_velocity`'s contribution to four decimals. Both round to the
same band and p_crisis; the JSON is the canonical, machine-readable
result.)

## 7. Band and probability

```
band     = CRITICAL            (65 <= 79 <= 100)
p_crisis = 1 / (1 + exp(-0.12 * (79 - 60))) ≈ 0.91
```

## 8. Final JSON output

```json
{
  "schema": "lcp.result.v1",
  "network": "mainnet",
  "target": "0xExampleToken0000000000000000000000000000000abc",
  "score": 79,
  "band": "CRITICAL",
  "p_crisis": 0.91,
  "drivers": [
    { "signal": "outflow_velocity",    "raw": 0.142,  "norm": 1.00, "contrib": 0.40 },
    { "signal": "reserve_depth",       "raw": 41200,  "norm": 1.00, "contrib": 0.25 },
    { "signal": "pool_imbalance",      "raw": 0.41,   "norm": 1.00, "contrib": 0.15 }
  ],
  "missing": ["liquidity_age", "gas_stress", "holder_concentration", "supply_growth"],
  "recommendation": "do not enter",
  "disclaimer": "LCP is an informational on-chain analytics signal. It is not financial advice. On-chain conditions can change between the read and any subsequent action."
}
```

## 9. Safety confirmation (internal, not output)

- [x] No `cast send` called.
- [x] No `forge script` called.
- [x] No `$PRIVATE_KEY` accepted.
- [x] No external HTTP oracle called.
