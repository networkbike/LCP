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
#   - Other Unix-like systems (auto-detect falls back to a warning)
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
# Foundry needs glibc; on Termux (Bionic libc) we route through
# proot-distro Debian so the rest of the script can run unchanged.
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

# --- Termux auto-routing -----------------------------------------------------
# Foundry requires glibc; the userland on Android phones is Bionic libc
# and cannot load Foundry's binaries. We transparently re-launch the
# install inside a proot-distro Debian rootfs so the rest of the script
# runs unchanged. The marker env var prevents infinite re-entry.
if [[ $TERMUX -eq 1 && -z "${LCP_INSIDE_PROOT:-}" ]]; then
  log "Detected Android userland. Routing install through proot-distro (Foundry needs glibc)."
  command -v proot-distro >/dev/null 2>&1 || {
    log "  installing proot-distro"
    pkg install -y proot-distro
  }
  # Ensure a Debian rootfs exists. 'proot-distro list' output format
  # varies; rather than parse it, just try to login first, and only
  # install if that fails. This handles "debian already exists" cleanly
  # without parsing fragile output.
  if ! proot-distro login debian -- /bin/true 2>/dev/null; then
    log "  installing Debian rootfs (one-time, ~150 MB)"
    proot-distro install debian
  fi
  log "  re-running this script inside proot-distro Debian."
  # proot-distro bind-mounts the Termux filesystem under /data, so the
  # script's absolute path is preserved as long as we resolve it before
  # re-exec.
  SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  ARGS=""
  for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done
  exec proot-distro login debian -- env LCP_INSIDE_PROOT=1 \
    /bin/bash -lc "cd /root && '$SCRIPT_ABS' $ARGS"
fi

# --- Step 1: System dependencies ---------------------------------------------
log "Step 1/6: system dependencies"
case "$PKG_MGR" in
  apt)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO apt-get update
    $SUDO apt-get install -y git curl ca-certificates jq build-essential
    # `forge` shells out to the `solc` binary by default. Foundry's
    # bundled solc-bin works on Linux x86_64, but on ARM64 hosts (e.g.
    # the Termux proot environment, Raspberry Pi, AWS Graviton) we need
    # a system `solc` because the bundled one is x86_64 only. If `solc`
    # isn't already on PATH, install it via pip + solc-select, which
    # downloads the official static solc release tarball. Falls back
    # gracefully if pip or network is unavailable.
    if ! command -v solc >/dev/null 2>&1; then
      # On Linux x86_64 forge ships a working bundled solc, but on
      # arm64 (Termux proot, Raspberry Pi, Graviton) the bundled
      # solc-bin can't load. We download a static solc directly from
      # the official Solidity binaries mirror and put it in
      # /usr/local/bin. Both amd64 and arm64 builds of 0.8.31+ are
      # available there, and our foundry.toml pins solc = "0.8.31".
      ARCH="$(uname -m)"
      case "$ARCH" in
        x86_64|amd64)   SOLC_ARCH="linux-amd64" ;;
        aarch64|arm64)  SOLC_ARCH="linux-arm64" ;;
        *)              SOLC_ARCH="" ;;
      esac
      if [[ -n "$SOLC_ARCH" ]]; then
        log "  downloading solc 0.8.31 ($SOLC_ARCH static binary)"
        SOLC_URL="https://binaries.soliditylang.org/${SOLC_ARCH}/solc-${SOLC_ARCH}-v0.8.31+commit.fd3a2265"
        if curl -fsSL "$SOLC_URL" -o /tmp/solc-static 2>/dev/null; then
          $SUDO install -m 0755 /tmp/solc-static /usr/local/bin/solc
          rm -f /tmp/solc-static
          if command -v solc >/dev/null 2>&1; then
            ok "  solc 0.8.31 installed at /usr/local/bin/solc"
          fi
        else
          warn "  failed to download solc from $SOLC_URL"
          warn "  forge test will fail until solc is available."
        fi
      fi
    fi
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
    # Host userland when on Android; the heavy install is being routed
    # to proot-distro Debian by the auto-routing block above. Only need
    # the basic CLI helpers here.
    pkg update -y
    pkg install -y git curl jq
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
  if command -v cast >/dev/null 2>&1 && command -v forge >/dev/null 2>&1 \
     && cast --version >/dev/null 2>&1; then
    ok "Foundry already on PATH and working (cast=$(command -v cast), forge=$(command -v forge))"
  else
    # Install Foundry to /usr/local/bin (or, on the Termux proot,
    # /usr/local/bin on the proot's own rootfs). This avoids the
    # bind-mounted /root path that triggers Termux's loader to try
    # to interpret the glibc binary and fail with 'TLS segment
    # underaligned'. The foundryup installer honours FOUNDRY_DIR.
    FOUNDRY_DIR="/usr/local"
    export FOUNDRY_DIR
    if [[ -d "$HOME/.foundry" ]]; then
      log "  removing pre-existing (possibly broken) foundry at $HOME/.foundry"
      rm -rf "$HOME/.foundry" 2>/dev/null || true
    fi
    log "  downloading foundryup"
    curl -L https://foundry.paradigm.xyz | bash
    log "  running foundryup (installs to $FOUNDRY_DIR/bin)"
    "$HOME/.foundry/bin/foundryup"
    # foundryup installs to $FOUNDRY_DIR/bin; ensure it's on PATH.
    if [[ -x "$FOUNDRY_DIR/bin/forge" ]]; then
      ln -sf "$FOUNDRY_DIR/bin/cast"  /usr/local/bin/cast  2>/dev/null || true
      ln -sf "$FOUNDRY_DIR/bin/forge" /usr/local/bin/forge 2>/dev/null || true
      ln -sf "$FOUNDRY_DIR/bin/anvil" /usr/local/bin/anvil 2>/dev/null || true
      export PATH="/usr/local/bin:$PATH"
    else
      # Fallback: foundryup may have used a different layout.
      export PATH="$HOME/.foundry/bin:$PATH"
    fi
    # Persist for future shells.
    if [[ -f "$HOME/.bashrc" ]] && ! grep -q '/usr/local/bin' "$HOME/.bashrc"; then
      printf '\n# Foundry (added by LCP install.sh)\nexport PATH="/usr/local/bin:$PATH"\n' >> "$HOME/.bashrc"
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
log "Step 4/6: forge-std dependency + repo freshness check"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If the script is being run from a directory that isn't a git repo,
# fall back to a known good location. This protects against the user
# running the script from an empty/aborted clone target.
if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
  TARGET="$HOME/LCP"
  if [[ -d "$TARGET/.git" ]]; then
    log "  $SCRIPT_DIR is not a git repo; switching to existing $TARGET"
    SCRIPT_DIR="$TARGET"
    cd "$SCRIPT_DIR"
  else
    log "  cloning LCP into $TARGET"
    git clone --depth 1 https://github.com/networkbike/LCP.git "$TARGET"
    SCRIPT_DIR="$TARGET"
    cd "$SCRIPT_DIR"
  fi
else
  log "  refreshing $SCRIPT_DIR from origin"
  git pull --ff-only || true
fi

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
