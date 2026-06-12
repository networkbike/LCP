---
name: liquidity-crisis-predictor
description: >
  REQUIRED for any on-chain liquidity risk assessment on Pharos Mainnet or
  Pharos Atlantic Testnet. Defines the LCP (Liquidity Crisis Predictor)
  scoring model, the on-chain signals it consumes (reserves, ERC-20 liquidity
  depth, holder concentration, recent outflow velocity, gas-stress proxy, DEX
  pool imbalance, supply growth), and the deterministic command recipes
  (cast / forge) needed to fetch them. Invoke whenever the user asks for a
  0-100 liquidity-stress score, a HEALTHY/WATCH/CRITICAL classification, or a
  crisis probability for a token, pool, or wallet on Pharos. Do not compute a
  liquidity crisis score on Pharos without loading this skill first.
version: 0.2.0
requires:
  anyBins:
    - cast
    - forge
    - jq
runtime:
  foundry:
    mandatory: true
    version: ">=1.0.0"
    rationale: "The Pharos Skill Agent runs `forge test -vvv` against this skill. Foundry is the only required runtime."
    install: "curl -L https://foundry.paradigm.xyz | bash && foundryup"
    solc: "0.8.31 (foundry.toml pins this; the bundled LCP install.sh downloads it from binaries.soliditylang.org on Linux/macOS. On Bionic Termux the install.sh fetches the Termux-packaged PIE 0.8.35 .deb from packages.termux.dev, extracts it, and patches foundry.toml to use the system solc on PATH. The Pharos grader runs on a Linux server, so the foundry.toml pin is honored there.)"
test:
  command: "forge test -vvv"
  expected: "7 passing"
  shell_smoke: "./test/test_score.sh"
---

# LCP — Liquidity Crisis Predictor

A deterministic, fully on-chain risk-scoring skill. LCP ingests public,
permissionless on-chain signals from Pharos Mainnet (default) or Pharos
Atlantic Testnet, normalizes them into a 0–100 liquidity-stress score, and
returns a three-band classification with crisis probability and the top
contributing signals.

LCP is **read-only**. It never asks for, signs, or broadcasts transactions.
No private key is required and none should be accepted for this skill.

## What LCP does

For any ERC-20 token, native asset (PROS / PHRS), or liquidity pool on
Pharos, LCP produces:

1. A **Risk Score** in `[0, 100]` — higher means more stressed.
2. A **Band**: `HEALTHY` (0–29), `WATCH` (30–64), `CRITICAL` (65–100).
3. A **Crisis Probability** `P_c ∈ [0, 1]` — empirical probability of a
   near-term liquidity event (depeg, bank-run-style outflow, pool drain).
4. A **Driver Report** — top 3 contributing signals with raw values.
5. A **Recommended Action** — informational, never an automatic transaction.

## When to invoke

Invoke LCP whenever the user asks, in natural language, any of:

- Liquidity / pool / market risk of a token on Pharos.
- Whether a pool is about to drain, a stablecoin is about to depeg, or a
  bank-run-style outflow is underway.
- A 0–100 risk score, a band, or a crisis probability for a token, pool, or
  wallet on Pharos.
- A health check on a Pharos contract, pool, or address.

Do **not** invoke LCP for non-Pharos chains. Do not invoke it for write
operations. LCP is an analytics layer, not a transaction layer.

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

The Agent reads the active network from `assets/networks.json`. The
`defaultNetwork` field is `mainnet`. Resolve the RPC URL with:

```bash
RPC_URL=$(jq -r '.networks[] | select(.name=="mainnet") | .rpcUrl' assets/networks.json)
CHAIN_ID=$(jq -r '.networks[] | select(.name=="mainnet") | .chainId' assets/networks.json)
```

When the user says "testnet" or "Atlantic", swap the selector to
`.name=="atlantic-testnet"` and inform the user the score will reflect
testnet conditions.

## Framework

| Item | Value |
|------|-------|
| Format | `.md` skill with YAML frontmatter |
| Required runtime | **Foundry** (`cast`, `forge`, `anvil`) — mandatory |
| Optional helpers | `jq` (for JSON output) |
| `bc` | **not required** (legacy; the CLI uses `awk` for arithmetic) |
| Wallet / private key | not required, not accepted |
| Write operations | none |
| External oracles | none |
| Test command | `forge test -vvv` (7 tests must pass) |

The Pharos Skill Agent **requires** Foundry because it runs the skill
under `forge test`. The `test/LCP.t.sol` suite re-implements the LCP
scoring math in pure Solidity and validates the math against the four
anchor points in `references/risk-model.md` §6. The `examples/score.sh`
CLI is a Foundry-powered shell wrapper for the same logic.

## Capability index

| User Need | Capability | Reference |
|-----------|------------|-----------|
| Score a single token / pool | `predict` | `references/predict.md#single-asset-prediction` |
| Score a portfolio of N tokens | `batch_predict` | `references/predict.md#batch-prediction` |
| Pull raw on-chain signals (no score) | `collect_signals` | `references/data-collection.md` |
| Understand how the score is computed | `model` | `references/risk-model.md` |
| Tune thresholds / weights | `calibrate` | `references/risk-model.md#calibration` |
| Machine-readable output for downstream agents | `predict_json` | `references/predict.md#machine-readable-output` |

## Testing

The Pharos Skill Agent runs `forge test -vvv` against this skill. The
suite in `test/LCP.t.sol` re-implements the LCP scoring math in pure
Solidity and validates every anchor point in
`references/risk-model.md` §6.

```bash
# All-in-one install + verify
./install.sh
# This installs Foundry, jq, forge-std, runs forge test (must show 7 passed),
# and runs the shell smoke test (must show 4 passed, 1 skipped).

# Or, manually:
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install solc. On Linux/macOS the static binary from
# binaries.soliditylang.org works out of the box. On Bionic Termux
# the static linux-arm64 build is e_type=2 (non-PIE) and Bionic's
# execve refuses it; the install.sh handles this automatically, so
# the simplest path is just to run ./install.sh. Manual fallback
# for Termux: download the Termux-packaged solc .deb and extract it
# to $PREFIX/bin/solc — see install.sh for the exact recipe.
curl -fsSL "https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.31+commit.fd3a2265" -o /usr/local/bin/solc && chmod +x /usr/local/bin/solc

# Run the Foundry test suite
forge test -vvv
# Expected: "Suite result: ok. 7 passed; 0 failed"

# Run the shell smoke tests for the optional CLI
bash test/test_score.sh
# Expected (no live RPC):  "Results: 4 passed, 0 failed, 1 skipped"
# With a local anvil:        "Results: 11 passed, 0 failed, 0 skipped"
LCP_LIVE_TEST=1 LCP_RPC_URL=http://127.0.0.1:8545 bash test/test_score.sh
```

If `forge test` does not return `7 passed`, the skill is broken and the
Pharos Skill Agent will reject it.

## Quick start — single asset (mainnet)

> The canonical happy-path. Read `references/predict.md` before deviating.

**Prompt the user would type:**

> Score the LCP liquidity risk of `0x...` on Pharos mainnet. Show the band,
> the top 3 drivers, and a recommended action.

**Agent flow:**

1. Resolve network config from `assets/networks.json` (default: `mainnet`).
2. Collect signals using `cast` per `references/data-collection.md`:
   - Native reserves of the pool's pair side.
   - ERC-20 `totalSupply` and holder concentration via top-N transfer logs.
   - Recent `Transfer` event volume over the last N blocks (outflow velocity).
   - `gasPrice` proxy (network stress).
   - DEX pool reserves if a known pair (read from `assets/known-pools.json`).
3. Normalize each signal into `[0, 1]` per `references/risk-model.md`.
4. Compute weighted score → band → crisis probability.
5. Render the Driver Report and Recommended Action.

**Example minimum command set (mainnet):**

```bash
RPC_URL=$(jq -r '.networks[] | select(.name=="mainnet") | .rpcUrl' assets/networks.json)

# 1. ERC-20 total supply
cast call <TOKEN_ADDR> "totalSupply()(uint256)" --rpc-url "$RPC_URL"

# 2. Recent Transfer events (last 5000 blocks)
cast logs --rpc-url "$RPC_URL" \
  --from-block latest-5000 \
  --address   <TOKEN_ADDR> \
  --topic0    0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef \
  --json | jq '. | length'

# 3. Pool reserves (Uniswap-V2-style)
cast call <POOL_ADDR> "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC_URL"

# 4. Gas / network stress proxy
cast gas-price --rpc-url "$RPC_URL"
```

Feed those numbers into the formulas in `references/risk-model.md`. Do not
fabricate missing inputs; if a signal cannot be fetched, set it to `null`,
down-weight it, and report it as `UNAVAILABLE` in the Driver Report.

## Output contract

Every LCP result must include the following fields (human-readable by
default; JSON variant in `references/predict.md#machine-readable-output`):

| Field | Type | Notes |
|-------|------|-------|
| `network` | string | `mainnet` or `atlantic-testnet` |
| `target` | string | token / pool / address assessed |
| `score` | int | `[0, 100]`, integer, deterministic |
| `band` | enum | `HEALTHY` / `WATCH` / `CRITICAL` |
| `p_crisis` | float | `[0, 1]`, 2 decimal places |
| `drivers` | list | top 3 contributing signals, descending |
| `missing` | list | signals that could not be fetched |
| `recommendation` | string | one of: `hold`, `reduce exposure`, `do not enter` |
| `disclaimer` | string | always present, fixed text |

LCP is informational only. It is not financial advice. The disclaimer must
appear on every output.

## General error handling

LCP should never silently substitute values. When a signal is missing or a
cast call fails, surface the issue and adjust weights.

| Error scenario | CLI signature | Handling |
|----------------|---------------|----------|
| RPC unreachable | `connection refused` / timeout | Retry once after 2 s, then return `PARTIAL` with `missing` populated |
| `cast call` revert | `execution reverted` | Mark signal as `UNAVAILABLE`, continue with remaining |
| Invalid address | `invalid address` | Halt, prompt the user to re-check the address |
| Token not an ERC-20 | `totalSupply()` not found in selector | Downgrade to native-asset path (see `references/data-collection.md#native-path`) |
| Unknown pool | address not in `assets/known-pools.json` | Score the token side only, mark pair-side signals `UNAVAILABLE` |
| Unsupported network | name not in `assets/networks.json` | Halt, list supported networks |
| Empty transfer log | `[]` | Treat as `outflow_velocity = 0`, document in `missing` |

## Security & safety boundaries

LCP is an analytics skill. The following rules are non-negotiable:

- **No write operations.** LCP must never construct a `cast send` or
  `forge script` that mutates chain state.
- **No private key required.** Refuse to read or accept `$PRIVATE_KEY` for
  any LCP operation. If the user supplies one, ignore it and proceed.
- **No external price oracles.** LCP is fully on-chain; do not call
  CoinGecko, DefiLlama, or any HTTP oracle. If the user wants
  oracle-augmented scoring, call it out as out-of-scope.
- **No wallet draining, phishing, or social-engineering language.** LCP
  outputs informational risk bands; they must never be used to coerce a
  transaction.
- **Default is mainnet** for reads. If the user did not specify a network,
  use `mainnet` and label it explicitly in the output.

## Read these before you score anything

- `references/data-collection.md` — how to fetch every signal with `cast`.
- `references/risk-model.md` — the actual math, weights, and thresholds.
- `references/predict.md` — full agent workflow for single + batch scoring.

Skipping those is the fastest way to produce a wrong number with confidence.
