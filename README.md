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

LCP is a **drop-in skill bundle**, not an installable package. There is no
`npm install`, `pip install`, or `cargo build` step. You copy the directory
into your Agent's skills path and make sure the four required binaries are
on your `PATH`.

### 1. Prerequisites

Install these once, on the machine that runs your Agent:

| Binary | Purpose | Install |
|--------|---------|---------|
| `git`   | clone this repo | [git-scm.com](https://git-scm.com/downloads) |
| `cast`, `forge` | on-chain reads, event logs, block queries | Foundry: `curl -L https://foundry.paradigm.xyz \| bash && foundryup` ([book.getfoundry.sh](https://book.getfoundry.sh/getting-started/installation)) |
| `jq` ≥ 1.6 | parse JSON (`networks.json`, `lcp-thresholds.json`, `cast --json` output) | `brew install jq` / `apt install jq` / [stedolan.github.io/jq](https://stedolan.github.io/jq/download/) |
| `bc`  | floating-point math in `examples/score.sh` | preinstalled on macOS / most Linux distros; `apt install bc` if missing |
| `bash` ≥ 4 | only needed for the optional `score.sh` CLI | preinstalled on macOS / most Linux distros |

You also need **outbound HTTPS** to the Pharos RPC endpoints listed in
`assets/networks.json` (e.g. `https://rpc.pharos.xyz` for mainnet).

You do **not** need a wallet, a private key, a seed phrase, or any API
token. LCP is read-only and will refuse to run if `$PRIVATE_KEY` is set in
the environment (exit code 77).

### 2. Clone the repository

```bash
git clone https://github.com/networkbike/LCP.git
cd LCP
```

### 3. Drop the skill into your Agent's skills path

Copy (or symlink) the `LCP/` directory into whichever skills directory your
Agent framework reads. The skill's folder name **must** be `LCP` (case
sensitive) so the YAML `name: liquidity-crisis-predictor` in
`SKILL.md` can resolve it.

| Framework | Skills path | Install command |
|-----------|-------------|-----------------|
| OpenClaw  | `~/.openclaw/skills/LCP/` | `cp -R LCP ~/.openclaw/skills/LCP` |
| Claude Code | `~/.claude/skills/LCP/` | `cp -R LCP ~/.claude/skills/LCP` |
| Codex     | `~/.codex/skills/LCP/` | `cp -R LCP ~/.codex/skills/LCP` |
| Project-level (shared with a repo) | `<your-project>/skills/LCP/` | `mkdir -p <your-project>/skills && cp -R LCP <your-project>/skills/LCP` |

> Prefer a **symlink** if you plan to pull upstream changes frequently:
> `ln -s "$(pwd)/LCP" ~/.claude/skills/LCP`

### 4. Make the optional CLI executable

`examples/score.sh` is a standalone scorer that does not require an Agent
runtime. Make it executable the first time you use it:

```bash
chmod +x examples/score.sh
```

### 5. Verify

Run these one-liners to confirm everything is in place:

```bash
# 1. Required binaries
for b in cast forge jq bc; do command -v "$b" >/dev/null && echo "OK  $b" || echo "MISSING $b"; done

# 2. Skill files present
ls SKILL.md assets/networks.json assets/lcp-thresholds.json

# 3. Skill is loaded (framework-specific)
# OpenClaw
openclaw skills list | grep liquidity-crisis-predictor
# Claude Code / Codex
/skills

# 4. Reach the Pharos RPC
RPC_URL=$(jq -r '.networks[] | select(.name=="mainnet") | .rpcUrl' assets/networks.json)
cast block-number --rpc-url "$RPC_URL"

# 5. Smoke-test the CLI on a native asset (no address needed)
./examples/score.sh native:PROS mainnet
```

A successful first run prints a human-readable report with a score, a band,
`p_crisis`, three drivers, and the fixed disclaimer.

### Updating

```bash
cd LCP                       # or wherever you cloned it
git pull --ff-only
# If you copied instead of symlinking, re-copy:
#   cp -R LCP ~/.claude/skills/LCP
```

There are no migrations between LCP versions yet; the output schema
(`lcp.result.v1`) and the seven-signal contract are stable.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Missing required binary: cast` | Foundry not on `PATH` | Re-run `foundryup`, then `source ~/.bashrc` / open a new shell |
| `jq: command not found` | `jq` not installed | `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu) |
| `RPC unreachable: https://rpc.pharos.xyz` | No outbound HTTPS, or the RPC is down | Test with `curl -I https://rpc.pharos.xyz`; switch to `atlantic-testnet` for development |
| `Refusing to run: $PRIVATE_KEY is set` | You have a wallet env var set | `unset PRIVATE_KEY` for the LCP session. LCP is read-only and must not see keys |
| `Unknown network: foo` | Typo in network name | Use exactly `mainnet` or `atlantic-testnet` (see `assets/networks.json`) |
| `Invalid address: 0x...` | Not a 20-byte hex address | Re-check; the native assets are `native:PROS` and `native:PHRS`, not `0x...` |
| Skill not listed in `/skills` | Wrong path, wrong folder name | Folder must be `LCP` (capital LCP) directly under the skills root |
| `cast logs` returns `[]` for a brand-new token | No `Transfer` events in the lookback window | Expected. `outflow_velocity` is set to `0` and listed in `missing` |

### Uninstall

```bash
# Remove the skill copy
rm -rf ~/.claude/skills/LCP          # or whichever path you used
# The four required binaries (Foundry, jq, bc) can stay; other tools use them too.
```

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
