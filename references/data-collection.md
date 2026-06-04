# LCP — Data Collection

This document defines exactly how an Agent gathers the raw on-chain signals
that feed the LCP score. Every signal is read-only and computed via `cast` /
`forge` against a Pharos RPC URL resolved from `assets/networks.json`.

If a signal cannot be retrieved, **do not invent a value**. Mark it
`UNAVAILABLE` and follow the per-signal `missing_policy` in
`assets/lcp-thresholds.json`.

## 0. Bootstrap

The default network is `mainnet`. The Agent must use `atlantic-testnet` only
when the user explicitly asks for it.

```bash
# Resolve active network (default: mainnet)
NETWORK="${LCP_NETWORK:-mainnet}"
RPC_URL=$(jq -r --arg n "$NETWORK" \
  '.networks[] | select(.name==$n) | .rpcUrl' assets/networks.json)
CHAIN_ID=$(jq -r --arg n "$NETWORK" \
  '.networks[] | select(.name==$n) | .chainId' assets/networks.json)

# Sanity
cast chain-id --rpc-url "$RPC_URL"
cast block-number --rpc-url "$RPC_URL"
```

If either call fails, the network is unreachable. Retry once after 2 s, then
return a `PARTIAL` result with `missing = ["rpc"]`.

## 1. Signals Overview

| ID | Source | Primary `cast` call |
|----|--------|---------------------|
| `reserve_depth` | Pool or token liquidity | `cast call <POOL> "getReserves()(uint112,uint112,uint32)"` |
| `outflow_velocity` | ERC-20 Transfer logs | `cast logs` over recent blocks |
| `holder_concentration` | Holder indexer or log scan | balanceOf over top holders |
| `pool_imbalance` | Pool reserves | derived from `getReserves` |
| `gas_stress` | Network | `cast gas-price` + rolling median |
| `liquidity_age` | Pool contract | first `AddLiquidity` / `Mint` event block |
| `supply_growth` | ERC-20 `totalSupply` history | `cast call totalSupply` at two block heights |

## 2. Native Path (PHRS / PROS)

If the target is the native asset itself (no ERC-20 contract), use:

```bash
# Total supply of native is implicit (chain-level cap); treat as N/A.
# Use validator-set size + recent block utilization as a coarse proxy.
cast block latest --field baseFeePerGas --rpc-url "$RPC_URL"
cast block latest --field gasUsed    --rpc-url "$RPC_URL"
cast block latest --field gasLimit   --rpc-url "$RPC_URL"
```

For native assets, `reserve_depth` and `pool_imbalance` are reported as
`UNAVAILABLE` and their weight is redistributed to the remaining signals
proportionally.

## 3. ERC-20 Path

```bash
TOKEN=0xYourTokenAddress
DECIMALS=$(cast call "$TOKEN" "decimals()(uint8)" --rpc-url "$RPC_URL")
SUPPLY=$(cast call "$TOKEN" "totalSupply()(uint256)" --rpc-url "$RPC_URL")
```

### 3.1 `outflow_velocity`

```bash
TRANSFER_TOPIC=0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
WINDOW=5000
LATEST=$(cast block-number --rpc-url "$RPC_URL")
FROM=$((LATEST - WINDOW))

# Example: mainnet defaults
RPC_URL=$(jq -r '.networks[] | select(.name=="mainnet") | .rpcUrl' assets/networks.json)

cast logs --rpc-url "$RPC_URL" \
  --from-block "$FROM" --to-block "$LATEST" \
  --address   "$TOKEN" \
  --topic0    "$TRANSFER_TOPIC" \
  --json > /tmp/lcp_transfers.json

# Sum absolute transfer volume, then normalize by supply.
VOL=$(jq '[.[].data | fromhex | . as $v | select(($v|type)=="number") | $v] | add // 0' /tmp/lcp_transfers.json)
RATIO=$(echo "scale=18; $VOL / $SUPPLY" | bc -l)
```

`outflow_velocity` is the absolute value of `RATIO`; sign (net in/out) is
preserved internally for the driver report.

### 3.2 `holder_concentration`

Without an indexer, derive an upper bound from transfer frequency:

```bash
# Count distinct _from addresses in the window
TOP_HOLDERS=$(jq -r '[.[].topics[1]] | unique | length' /tmp/lcp_transfers.json)
```

For a hard H1, use `cast call` with a known holder-set registry if available.
If not available, mark `holder_concentration` as `UNAVAILABLE` and apply
`missing_policy = "downweight_to_neighbors"`.

### 3.3 `supply_growth`

```bash
SUPPLY_NOW=$SUPPLY
SUPPLY_PAST=$(cast call "$TOKEN" "totalSupply()(uint256)" \
  --rpc-url "$RPC_URL" --block "$FROM")
GROWTH=$(echo "scale=18; ($SUPPLY_NOW - $SUPPLY_PAST) / $SUPPLY_PAST" | bc -l)
```

## 4. Pool Path

When the user supplies a pool address, prefer the pool's own reserves over
the token's holders.

```bash
POOL=0xYourPoolAddress
RES=$(cast call "$POOL" "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC_URL")
# cast returns a tuple as comma-separated; parse with jq after --json
```

If the pool is not in `assets/known-pools.json`, only the token side is
scored and `pool_imbalance` is marked `UNAVAILABLE`.

### 4.1 `liquidity_age`

```bash
# First Mint / AddLiquidity event block
MINT_TOPIC=0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f
FIRST_BLOCK=$(cast logs --rpc-url "$RPC_URL" \
  --from-block 0 --to-block latest \
  --address "$POOL" --topic0 "$MINT_TOPIC" \
  --json | jq '.[0].blockNumber' )
AGE=$((LATEST - FIRST_BLOCK))
```

## 5. Gas Stress

```bash
GAS_NOW=$(cast gas-price --rpc-url "$RPC_URL")

# Approximate rolling median from last 200 blocks
SAMPLES=$(for b in $(seq $((LATEST-200)) $LATEST); do
  cast block "$b" --field baseFeePerGas --rpc-url "$RPC_URL"
done | sort -n)
MEDIAN=$(echo "$SAMPLES" | awk 'NR==FNR{a[NR]=$1;n=NR;next}' | awk -v n=200 'NR==int(n/2)')
RATIO=$(echo "scale=4; $GAS_NOW / $MEDIAN" | bc -l)
```

For testnet where gas is typically zero, `gas_stress` collapses to `0.0`
and contributes no risk — that is intentional.

## 6. Missing-Signal Policy

For each signal, read `missing_policy` from `assets/lcp-thresholds.json`:

| Policy | Behavior |
|--------|----------|
| `downweight_to_neighbors` | Drop the signal; rescale remaining weights to sum to 1.0 |
| `assume_worst` | Set normalized value to `1.0` (max stress) |
| `assume_best` | Set normalized value to `0.0` (no stress) |
| `fail` | Abort the run; require the signal |

Default is `downweight_to_neighbors`. The Agent MUST always populate the
`missing` field in the output, even if it is empty.

## 7. Pre-checks (Mandatory)

Before any scoring run, the Agent must verify:

1. `cast`, `forge`, `jq`, `bc` are all on `PATH`.
2. The target address matches `^0x[0-9a-fA-F]{40}$`.
3. The chosen network is in `assets/networks.json`.
4. The Agent has **not** been given a `$PRIVATE_KEY` for this run. If it has,
   ignore it and continue; LCP is read-only.
