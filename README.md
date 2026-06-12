# LCP — Liquidity Crisis Predictor

A deterministic, read-only on-chain analytics skill that produces a
**0–100 liquidity-stress score**, a **HEALTHY / WATCH / CRITICAL** band, a
**crisis probability**, and the **top contributing signals** for any ERC-20
token, liquidity pool, or native asset on Pharos.

LCP consumes only public on-chain data via `cast` and `forge`. It does not
sign, send, or propose any transaction. It does not call any external HTTP
oracle. It does not require a private key.

---

## Quick install

```bash
git clone https://github.com/networkbike/LCP.git
cd LCP
chmod +x install.sh
./install.sh
```

The installer is self-contained: it detects your platform, installs
Foundry + jq + forge-std, makes the CLI executable, and runs `forge test
-vvv` plus `bash test/test_score.sh` to confirm the skill works. A green
run looks like:

```
[install] forge test: 7 passed; 0 failed
[install] shell smoke test passed
```

If both test commands pass, the skill is ready for the Pharos Skill Agent
to grade. See [§ Installation](#installation) for the full guide and a
manual fallback.

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
| Required runtime | **Foundry** (`cast`, `forge`, `anvil`) — mandatory |
| Optional helpers | `jq` (for JSON output) |
| `bc` | **not required** (legacy; the CLI uses `awk`) |
| Optional CLI | `examples/score.sh` (single-asset scorer) |
| Wallet / private key | **not required, not accepted** |
| Write operations | **none** |
| External oracles | **none** |
| Test command | `forge test -vvv` (7 tests must pass) |

## Repository layout

```
LCP/
├── SKILL.md                    # skill manifest (frontmatter + body)
├── README.md                   # this file
├── LICENSE                     # MIT
├── install.sh                  # one-shot installer (auto-detects platform)
├── foundry.toml                # Foundry config (for `forge test`)
├── src/
│   └── MockERC20.sol           # minimal ERC-20 used by forge tests
├── test/
│   ├── LCP.t.sol               # Foundry test suite (forge test -vvv)
│   └── test_score.sh           # Shell test runner for examples/score.sh
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
│   └── score.sh                # copy-paste shell recipe (Foundry-powered)
└── .github/
    └── ISSUE_TEMPLATE.md
```

## Installation

LCP is a **Foundry-first skill bundle** for the Pharos Skill Agent. There is
no `npm install` / `pip install` / `cargo build` step. The runtime is
Foundry (`cast` / `forge` / `anvil`); the test target the agent grades is
`forge test -vvv`.

### TL;DR — one command, four lines

```bash
git clone https://github.com/networkbike/LCP.git
cd LCP
chmod +x install.sh
./install.sh
```

`./install.sh` is a self-contained bootstrapper that:
1. Installs system dependencies (`git`, `curl`, `jq`, build tools) for your
   platform.
2. Installs **Foundry** via the official `foundryup` installer and adds it
   to `~/.bashrc`.
3. Installs **solc 0.8.31** — on Linux/macOS it pulls the static build
   from `binaries.soliditylang.org`; on Bionic Termux it fetches the
   Termux-packaged PIE 0.8.35 .deb from `packages.termux.dev` and patches
   `foundry.toml` to use the system solc (Bionic rejects the e_type=2
   static linux-arm64 build).
4. Clones `forge-std` into `lib/`.
5. Marks the CLI as executable.
6. Runs `forge test -vvv` — must report `7 passed; 0 failed`.
7. Runs `bash test/test_score.sh` — must report `4 passed; 0 failed`.

If both test commands pass, the skill is correctly installed and the
Pharos Skill Agent will accept it.

Supported platforms: **Linux** (Debian, Ubuntu, Alpine, Arch, RHEL family),
**macOS** (Homebrew), and other Unix-like systems that have `apt`/`apk`/
`pacman`/`dnf`/`brew` available. On unknown platforms it prints a warning
and continues with whatever package manager it could detect.

### 1. Prerequisites (manual fallback)

If you prefer to install things by hand — or if `./install.sh` failed and
you want to know what to check — the runtime is just Foundry + jq:

| Binary | Required? | Install |
|--------|-----------|---------|
| `cast`, `forge`, `anvil` | **Yes** — mandatory | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `solc`    | **Yes** — `forge test` needs it. The `install.sh` handles this automatically. | On Linux/macOS: `curl -fsSL "https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.31+commit.fd3a2265" -o /usr/local/bin/solc && chmod +x /usr/local/bin/solc`. On Bionic Termux the static linux-arm64 build is e_type=2 (rejected by Bionic); the install.sh fetches the Termux-packaged PIE 0.8.35 .deb from `packages.termux.dev` and patches `foundry.toml` to use it. |
| `git`     | Yes | usually preinstalled; `apt install git` / `brew install git` |
| `jq`      | Yes (for JSON output) | `apt install jq` / `brew install jq` |
| `bash` ≥ 4 | Yes (for the CLI) | preinstalled on macOS / most Linux |
| `bc`      | **No** (legacy — the CLI uses `awk`) | — |

You also need **outbound HTTPS** to the Pharos RPC endpoints listed in
`assets/networks.json` (e.g. `https://rpc.pharos.xyz` for mainnet), **or**
a local Foundry `anvil` instance for the live tests.

You do **not** need a wallet, a private key, a seed phrase, or any API
token. LCP is read-only and will refuse to run if `$PRIVATE_KEY` is set in
the environment (exit code 77).

### Foundry install commands (by platform)

The runtime is Foundry. Copy-paste the block for your platform.

**Linux x86_64 / arm64 (Ubuntu, Debian, Alpine, Arch, RHEL, WSL, Docker):**

```bash
# 1. Foundry (forge, cast, anvil)
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup

# 2. solc 0.8.31 (static binary from binaries.soliditylang.org)
case "$(uname -m)" in
  x86_64|amd64)  SOLC=solc-linux-amd64-v0.8.31+commit.fd3a2265 ;;
  aarch64|arm64) SOLC=solc-linux-arm64-v0.8.31+commit.fd3a2265 ;;
  *)             echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
curl -fsSL "https://binaries.soliditylang.org/linux-$(uname -m | sed -e s/aarch64/arm64/ -e s/x86_64/amd64/)/${SOLC}" \
  -o /usr/local/bin/solc && chmod +x /usr/local/bin/solc

# 3. jq + git
sudo apt install -y jq git         # Debian/Ubuntu
# sudo apk add jq git                # Alpine
# sudo pacman -S jq git              # Arch
# sudo dnf install -y jq git         # RHEL/Fedora

# 4. Verify
forge --version && solc --version && jq --version
```

**macOS (Homebrew):**

```bash
brew install jq git
curl -L https://foundry.paradigm.xyz | bash
source ~/.zshrc
foundryup
curl -fsSL "https://binaries.soliditylang.org/macosx-amd64/solc-macosx-amd64-v0.8.31+commit.fd3a2265" \
  -o /usr/local/bin/solc && chmod +x /usr/local/bin/solc
forge --version && solc --version && jq --version
```

**Bionic Termux (Android, arm64):** use `./install.sh` (see TL;DR above). It
handles the Bionic-specific issues (Bionic rejects both foundryup's alpine
static build for having a TLS segment with 8-byte alignment — needs 64 — and
the linux-arm64 build for referencing the non-existent glibc loader) by
fetching the Termux-packaged PIE foundry and solc .debs from
`packages.termux.dev`. Manual fallback:

```bash
pkg update && pkg install -y jq git curl xz-utils  # xz-utils gives xzcat as a fallback

# 1. Foundry — use the Termux-packaged .deb, NOT foundryup.
#    foundryup installs the alpine/arm64 static build which has a
#    TLS segment with 8-byte alignment; Bionic refuses it with
#    "segment is underaligned: alignment is 8, needs to be at
#    least 64 for ARM64 Bionic". The Termux-packaged foundry
#    is a PIE binary linked against /system/bin/linker64 with
#    no TLS segment — runs natively on Bionic.
rm -rf "$HOME/.foundry" 2>/dev/null
for b in cast forge anvil chisel; do
  [ -e "$PREFIX/bin/$b" ] && ! "$PREFIX/bin/$b" --version >/dev/null 2>&1 && rm -f "$PREFIX/bin/$b"
done
FOUNDRY_DEB="$HOME/.lcp-foundry.deb"
curl -fsSL "https://packages.termux.dev/apt/termux-main/pool/main/f/foundry/foundry_1.7.1-1_aarch64.deb" -o "$FOUNDRY_DEB"
mkdir -p "$HOME/.lcp-foundry-extract" && (cd "$HOME/.lcp-foundry-extract" && dpkg-deb -x "$FOUNDRY_DEB" .)
for b in cast forge anvil chisel; do
  cp -f "$HOME/.lcp-foundry-extract/data/data/com.termux/files/usr/bin/$b" "$PREFIX/bin/$b"
  cp -f "$HOME/.lcp-foundry-extract/data/data/com.termux/files/usr/bin/$b" "$HOME/.foundry/bin/$b" 2>/dev/null || mkdir -p "$HOME/.foundry/bin" && cp -f "$HOME/.lcp-foundry-extract/data/data/com.termux/files/usr/bin/$b" "$HOME/.foundry/bin/$b"
done
chmod +x "$PREFIX/bin/"{cast,forge,anvil,chisel} "$HOME/.foundry/bin/"{cast,forge,anvil,chisel}
rm -rf "$FOUNDRY_DEB" "$HOME/.lcp-foundry-extract"

# 2. solc — Termux-packaged PIE .deb. (Same Bionic-rejection
#    story as the Foundry case.)
SOLC_DEB="$HOME/.lcp-solc.deb"
curl -fsSL "https://packages.termux.dev/apt/termux-main/pool/main/s/solidity/solidity_0.8.35_aarch64.deb" -o "$SOLC_DEB"
mkdir -p "$HOME/.lcp-solc-extract" && (cd "$HOME/.lcp-solc-extract" && dpkg-deb -x "$SOLC_DEB" .)
cp "$HOME/.lcp-solc-extract/data/data/com.termux/files/usr/bin/solc" "$PREFIX/bin/solc"
chmod +x "$PREFIX/bin/solc"
rm -rf "$SOLC_DEB" "$HOME/.lcp-solc-extract"

# 3. Patch foundry.toml so forge uses the system solc on PATH
#    (otherwise forge tries to download the e_type=2 static 0.8.31
#    and Bionic refuses it).
cd ~/LCP
sed -i.bak -E 's/^[[:space:]]*solc[[:space:]]*=[[:space:]]*"0\.8\.[0-9]+"/# solc = "0.8.31"  # Termux: use system solc (0.8.35 PIE)/' foundry.toml
rm -f foundry.toml.bak

# 4. Verify
export PATH="$HOME/.foundry/bin:$PREFIX/bin:$PATH"
forge --version && cast --version && solc --version && jq --version
```

If `dpkg-deb` isn't available, the install.sh's ar+tar fallback (with
`tar -xJf` → `xzcat | tar -x` → `xz -dc | tar -x` → `python3` strategies)
also works. Termux's dpkg-deb is part of the base system, so the primary
`dpkg-deb -x` path should succeed.


**Windows (PowerShell):** install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install)
and use the Linux x86_64 block above. WSL2's kernel accepts both e_type=2
and e_type=3 binaries.

### 2. Clone the repository

```bash
git clone https://github.com/networkbike/LCP.git
cd LCP
```

### 3. Run the installer

```bash
chmod +x install.sh
./install.sh
```

Flags:
- `--skip-forge` — don't re-install Foundry if it's already present.
- `--skip-verify` — install everything but don't run the test suite.

### 4. Drop the skill into your Agent's skills path (optional)

If you're loading the skill into an Agent framework (OpenClaw, Claude
Code, Codex, or a project-level skills folder), copy or symlink the
`LCP/` directory. The folder name **must** be `LCP` (case sensitive) so
the YAML `name: liquidity-crisis-predictor` in `SKILL.md` can resolve it.

| Framework | Skills path | Install command |
|-----------|-------------|-----------------|
| OpenClaw  | `~/.openclaw/skills/LCP/` | `cp -R . ~/.openclaw/skills/LCP` |
| Claude Code | `~/.claude/skills/LCP/` | `cp -R . ~/.claude/skills/LCP` |
| Codex     | `~/.codex/skills/LCP/` | `cp -R . ~/.codex/skills/LCP` |
| Project-level (shared with a repo) | `<your-project>/skills/LCP/` | `mkdir -p <your-project>/skills && cp -R . <your-project>/skills/LCP` |

> Prefer a **symlink** if you plan to pull upstream changes frequently:
> `ln -s "$(pwd)" ~/.claude/skills/LCP`

> The Pharos Skill Agent does not need this step — it reads the skill
> directly from the repository root.

### 5. Verify

After `./install.sh` finishes, run these one-liners to confirm:

```bash
# 1. Required binaries (Foundry is the only mandatory one)
for b in cast forge jq; do command -v "$b" >/dev/null && echo "OK  $b" || echo "MISSING $b"; done

# 2. Skill files present
ls SKILL.md assets/networks.json assets/lcp-thresholds.json

# 3. The Pharos Skill Agent's grading target — MUST report 7 passed
forge test -vvv

# 4. Shell smoke test for the CLI — MUST report 4 passed, 1 skipped
bash test/test_score.sh

# 5. (Optional) live ERC-20 path — requires anvil running on :8545
LCP_LIVE_TEST=1 LCP_RPC_URL=http://127.0.0.1:8545 bash test/test_score.sh

# 6. Smoke-test the CLI on a native asset (no address needed)
./examples/score.sh native:PROS mainnet
```

### Updating

```bash
cd LCP                       # or wherever you cloned it
git pull --ff-only
./install.sh --skip-forge    # re-runs the test gates; nothing else to do
```

If you copied (not symlinked) the skill into an Agent's skills path, copy
again: `cp -R LCP ~/.claude/skills/LCP`.

There are no migrations between LCP versions yet; the output schema
(`lcp.result.v1`) and the seven-signal contract are stable.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `./install.sh: Permission denied` | `install.sh` is not executable | `chmod +x install.sh` (the install script does this for you) |
| `Missing required binary: cast` | Foundry not on `PATH` | `source ~/.bashrc` or `export PATH="/usr/local/bin:$PATH"` |
| `forge test` fails | Foundry version mismatch or `lib/forge-std` missing | `foundryup` to update; `./install.sh` re-clones `forge-std` |
| `solc has unexpected e_type: 2` | You're on Bionic Termux. The static linux-arm64 solc from `binaries.soliditylang.org` is e_type=2 (non-PIE), which Bionic's `execve` refuses. The `install.sh` auto-fixes this by fetching the Termux-packaged PIE 0.8.35 .deb from `packages.termux.dev`. Re-run `cd ~/LCP && ./install.sh` to apply the patch. |
| `jq: command not found` | `jq` not installed | `apt install jq` / `brew install jq` |
| `RPC unreachable: https://rpc.pharos.xyz` | No outbound HTTPS, or the RPC is down | Test with `curl -I https://rpc.pharos.xyz`; switch to `atlantic-testnet` for development, or set `LCP_RPC_URL` to a local `anvil` instance |
| `Refusing to run: $PRIVATE_KEY is set` | You have a wallet env var set | `unset PRIVATE_KEY` for the LCP session. LCP is read-only and must not see keys. |
| `Unknown network: foo` | Typo in network name | Use exactly `mainnet` or `atlantic-testnet` (see `assets/networks.json`) |
| `Invalid address: 0x...` | Not a 20-byte hex address | Re-check; the native assets are `native:PROS` and `native:PHRS`, not `0x...` |
| Skill not listed in `/skills` | Wrong path, wrong folder name | Folder must be `LCP` (capital LCP) directly under the skills root |
| `cast logs` returns `[]` for a brand-new token | No `Transfer` events in the lookback window | Expected. `outflow_velocity` is set to `0` and listed in `missing` |
| Installer reports "Unknown platform" | OS not in the auto-detect list | Install `git`, `curl`, `jq`, `build-essential` manually, then re-run with `--skip-forge` |

### Uninstall

```bash
# Remove the skill copy
rm -rf ~/.claude/skills/LCP          # or whichever path you used
# Foundry and jq can stay; other tools use them too.
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
