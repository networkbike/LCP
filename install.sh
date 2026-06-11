#!/usr/bin/env bash
# LCP — One-shot installer
#
# Run this on a fresh machine to install everything needed to use and test
# the LCP skill:
#   1. Foundry (cast, forge, anvil) — the only mandatory runtime
#   2. jq (for JSON output)
#   3. forge-std (LCP test dependency, cloned into lib/)
#   4. chmod +x the CLI
#   5. Run `forge test -vvv` to confirm the skill is healthy
#   6. Run `bash test/test_score.sh` for the CLI smoke tests
#
# Usage:
#   ./install.sh
#   ./install.sh --skip-forge     # if Foundry is already installed
#   ./install.sh --skip-verify    # install deps but don't run tests
#
# Supported platforms (auto-detected):
#   - Linux  (Debian/Ubuntu, Alpine, Arch, RHEL family)
#   - macOS  (via Homebrew)
#   - Termux (via proot-distro Debian; auto-detected)
#
# Exit codes:
#   0  — success, all checks passed
#   1  — unsupported platform
#   2  — required binary missing after install
#   3  — `forge test` failed (skill is broken)
#   4  — shell smoke test failed

set -euo pipefail

# --- Args ---------------------------------------------------------------------
SKIP_FORGE=0
SKIP_VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --skip-forge)  SKIP_FORGE=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf "Unknown flag: %s\n" "$arg" >&2; exit 1 ;;
  esac
done

# --- Platform detection -------------------------------------------------------
OS="$(uname -s)"
DISTRO=""
PKG_MGR=""
if [[ "$OS" == "Linux" ]]; then
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
  fi
  case "$DISTRO" in
    debian|ubuntu|pop|linuxmint|elementary|kali|raspbian)
      PKG_MGR=apt ;;
    alpine) PKG_MGR=apk ;;
    arch|manjaro|endeavouros) PKG_MGR=pacman ;;
    fedora|rhel|centos|rocky|almalinux|ol)
      PKG_MGR="dnf"
      command -v dnf >/dev/null 2>&1 || PKG_MGR="yum" ;;
    *) PKG_MGR="" ;;
  esac
elif [[ "$OS" == "Darwin" ]]; then
  PKG_MGR="brew"
fi

# Termux detection — when $PREFIX is set, we're inside Termux's userland.
if [[ -n "${PREFIX:-}" && "$PREFIX" == */com.termux/* ]]; then
  TERMUX=1
  PKG_MGR="pkg"
else
  TERMUX=0
fi

log()  { printf "\033[36m[install]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[install]\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[31m[install]\033[0m %s\n" "$*" >&2; exit "${2:-1}"; }
ok()   { printf "\033[32m[install]\033[0m %s\n" "$*"; }

# --- Step 1: System dependencies ---------------------------------------------
log "Step 1/6: system dependencies"
case "$PKG_MGR" in
  apt)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO apt-get update
    $SUDO apt-get install -y git curl ca-certificates jq build-essential
    ;;
  apk)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO apk add --no-cache git curl ca-certificates jq build-base
    ;;
  pacman)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO pacman -Sy --noconfirm git curl ca-certificates jq base-devel
    ;;
  dnf|yum)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO $PKG_MGR install -y git curl ca-certificates jq gcc make
    ;;
  brew)
    brew update || true
    brew install git curl jq
    ;;
  pkg)
    pkg update -y
    pkg install -y git curl jq proot-distro
    warn "Termux detected. Foundry requires glibc; install it under proot-distro Debian."
    warn "After this script finishes, run: proot-distro install debian && proot-distro login debian"
    warn "Then re-run this script inside the proot session. See README.md §Termux."
    ;;
  *)
    warn "Unknown platform (OS=$OS, DISTRO=$DISTRO)."
    warn "Install manually: git, curl, jq, build-essential (or equivalent), then re-run."
    ;;
esac
ok "system dependencies present"

# --- Step 2: Foundry ---------------------------------------------------------
if [[ $SKIP_FORGE -eq 0 ]]; then
  log "Step 2/6: Foundry (cast / forge / anvil)"
  if command -v cast >/dev/null 2>&1 && command -v forge >/dev/null 2>&1; then
    ok "Foundry already on PATH (cast=$(command -v cast), forge=$(command -v forge))"
  else
    if [[ $TERMUX -eq 1 ]]; then
      fail "Foundry cannot be installed directly in Termux. Use proot-distro Debian." 1
    fi
    log "  downloading foundryup"
    curl -L https://foundry.paradigm.xyz | bash
    log "  running foundryup (downloads cast / forge / anvil)"
    # foundryup installs to ~/.foundry/bin
    export PATH="$HOME/.foundry/bin:$PATH"
    "$HOME/.foundry/bin/foundryup"
    if ! command -v cast >/dev/null 2>&1; then
      export PATH="$HOME/.foundry/bin:$PATH"
    fi
    # Persist for future shells.
    if [[ -f "$HOME/.bashrc" ]] && ! grep -q '\.foundry/bin' "$HOME/.bashrc"; then
      printf '\n# Foundry (added by LCP install.sh)\nexport PATH="$HOME/.foundry/bin:$PATH"\n' >> "$HOME/.bashrc"
    fi
  fi
else
  log "Step 2/6: Foundry (skipped via --skip-forge)"
fi

# --- Step 3: Verify binaries -------------------------------------------------
log "Step 3/6: verifying required binaries"
for bin in cast forge jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "required binary missing: $bin (try running without --skip-forge)" 2
  fi
done
CAST_VER="$(cast --version 2>/dev/null | head -1 || echo unknown)"
FORGE_VER="$(forge --version 2>/dev/null | head -1 || echo unknown)"
ok "cast : $CAST_VER"
ok "forge: $FORGE_VER"

# --- Step 4: forge-std dependency --------------------------------------------
log "Step 4/6: forge-std test dependency"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$SCRIPT_DIR/lib"
if [[ ! -d "$SCRIPT_DIR/lib/forge-std" ]]; then
  git clone --depth 1 https://github.com/foundry-rs/forge-std.git "$SCRIPT_DIR/lib/forge-std"
else
  log "  forge-std already present in lib/ (skipping clone)"
fi
ok "lib/forge-std ready"

# --- Step 5: Make the CLI executable -----------------------------------------
log "Step 5/6: marking CLI as executable"
chmod +x "$SCRIPT_DIR/examples/score.sh" "$SCRIPT_DIR/test/test_score.sh"
ok "examples/score.sh and test/test_score.sh are +x"

# --- Step 6: Verify by running the test suite -------------------------------
if [[ $SKIP_VERIFY -eq 0 ]]; then
  log "Step 6/6: running forge test -vvv"
  cd "$SCRIPT_DIR"
  if ! forge test 2>&1 | tee /tmp/lcp-forge-test.log | tail -20; then
    fail "forge test failed (see /tmp/lcp-forge-test.log)" 3
  fi
  if ! grep -q "7 passed" /tmp/lcp-forge-test.log; then
    fail "forge test did not report 7 passed" 3
  fi
  ok "forge test: 7 passed; 0 failed"

  log "  running bash test/test_score.sh"
  if ! bash test/test_score.sh 2>&1 | tee /tmp/lcp-shell-test.log | tail -10; then
    fail "shell smoke test failed (see /tmp/lcp-shell-test.log)" 4
  fi
  ok "shell smoke test passed"
else
  log "Step 6/6: skipped via --skip-verify"
fi

# --- Done --------------------------------------------------------------------
cat <<'DONE'

  LCP install: complete.

  Quick commands:
    cd LCP
    forge test -vvv                                 # Foundry test suite (7 passing)
    bash test/test_score.sh                         # shell smoke test (4 passing, 1 skipped)
    ./examples/score.sh native:PROS mainnet         # one-shot CLI run

  Optional — exercise the live ERC-20 path:
    anvil --port 8545 &                              # in another shell
    LCP_LIVE_TEST=1 LCP_RPC_URL=http://127.0.0.1:8545 bash test/test_score.sh
                                                      # 11 passing; 0 failed

DONE
