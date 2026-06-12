#!/usr/bin/env bash
# LCP — One-shot installer
#
# Run this on a fresh machine to install everything needed to use and
# test the LCP skill with Foundry (cast / forge / anvil).
#
# Usage:
#   ./install.sh                       # full install + verify
#   ./install.sh --skip-verify         # install deps, skip tests
#   ./install.sh --skip-forge          # install deps but not Foundry
#   ./install.sh --force               # wipe any pre-existing install
#                                      # and start clean
#
# Supported platforms (auto-detected):
#   - Linux  (Debian/Ubuntu, Alpine, Arch, RHEL family, Termux proot)
#   - macOS  (Homebrew)
#   - Termux (Android): installs the STATIC alpine/arm64 Foundry
#     directly into Termux's $HOME so no proot is needed at all.
#
# Exit codes:
#   0  — success
#   1  — unsupported platform
#   2  — required binary missing
#   3  — forge test failed
#   4  — shell smoke test failed

set -uo pipefail

# --- Args ---------------------------------------------------------------------
SKIP_FORGE=0
SKIP_VERIFY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --skip-forge)  SKIP_FORGE=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --force)       FORCE=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf "Unknown flag: %s\n" "$arg" >&2; exit 1 ;;
  esac
done

# --- Logging -------------------------------------------------------------------
log()  { printf "\033[36m[install]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[install]\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[31m[install]\033[0m %s\n" "$*" >&2; exit "${2:-1}"; }
ok()   { printf "\033[32m[install]\033[0m %s\n" "$*"; }

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

# Termux detection.
if [[ -n "${PREFIX:-}" && "$PREFIX" == */com.termux/* ]]; then
  TERMUX=1
else
  TERMUX=0
fi

# --- Force-clean previous installs -------------------------------------------
if [[ $FORCE -eq 1 ]]; then
  log "Force mode: removing any pre-existing installs"
  for d in "$HOME/.foundry" "$HOME/LCP"; do
    if [[ -e "$d" ]]; then
      log "  removing $d"
      rm -rf "$d" 2>/dev/null || true
    fi
  done
fi

# --- Step 1: System dependencies ----------------------------------------------
log "Step 1/6: system dependencies"
case "$PKG_MGR" in
  apt)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO apt-get update
    $SUDO apt-get install -y git curl ca-certificates jq build-essential
    ;;
  apk)
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
    $SUDO apk add --no-cache git curl ca-certificates jq build-base bash
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
  "")
    # On Termux the host pkg manager is `pkg`. We'll handle the OS deps
    # (git, curl, jq) on the Termux side as part of Foundry install below.
    if [[ $TERMUX -eq 1 ]]; then
      log "  (Termux: installing git, curl, jq via pkg)"
      pkg update -y
      pkg install -y git curl jq
    else
      warn "Unknown Linux distribution ($DISTRO). Assuming git, curl, jq are present."
    fi
    ;;
  *)
    warn "Unknown package manager: $PKG_MGR (skipping system deps)"
    ;;
esac
ok "system dependencies present"

# --- Step 2: Foundry ---------------------------------------------------------
# Strategy:
#   - Termux: download the STATIC alpine/arm64 Foundry binary directly
#     from Foundry's GitHub release. It's a pure musl static build that
#     runs natively on Bionic — no proot, no glibc, no TLS issues.
#   - Linux/macOS: use the official foundryup installer.
#   - In both cases, install to $HOME/.foundry/bin and add to PATH.
if [[ $SKIP_FORGE -eq 0 ]]; then
  log "Step 2/6: Foundry (cast / forge / anvil)"
  if [[ $FORCE -eq 1 && -d "$HOME/.foundry" ]]; then
    log "  removing $HOME/.foundry (force mode)"
    rm -rf "$HOME/.foundry"
  fi

  if command -v cast >/dev/null 2>&1 && command -v forge >/dev/null 2>&1 \
     && cast --version >/dev/null 2>&1 && forge --version >/dev/null 2>&1; then
    ok "Foundry already installed and working (cast=$(command -v cast), forge=$(command -v forge))"
  else
    if [[ $TERMUX -eq 1 ]]; then
      # --- Termux: download the static musl/alpine arm64 build -------
      # The "alpine" build is statically linked against musl, so it
      # doesn't depend on Termux's Bionic libc. This is the only
      # Foundry release asset that runs natively on Termux.
      #
      # IMPORTANT: install to $HOME/.foundry/bin (NOT $PREFIX/bin)
      # so the Foundry binaries are co-located with where the
      # standard foundryup installer would put them. We also make
      # them visible to the Termux shell by symlinking into
      # $PREFIX/bin for convenience.
      mkdir -p "$HOME/.foundry/bin"
      VERSION="v1.7.1"
      ARCH="arm64"
      TARBALL="foundry_${VERSION}_alpine_${ARCH}.tar.gz"
      URL="https://github.com/foundry-rs/foundry/releases/download/${VERSION}/${TARBALL}"
      log "  downloading Foundry ${VERSION} (alpine/${ARCH}, static, ~80 MB)"
      TMP_TGZ="$HOME/.lcp-${TARBALL}.$$"
      if ! curl -fsSL "$URL" 2>/dev/null > "$TMP_TGZ"; then
        rm -f "$TMP_TGZ"
        fail "could not download ${URL}" 1
      fi
      tar -xzf "$TMP_TGZ" -C "$HOME/.foundry/bin"
      rm -f "$TMP_TGZ"
      chmod +x "$HOME/.foundry/bin/"*
      # Also expose cast/forge/anvil at $PREFIX/bin so the user
      # doesn't need to export PATH manually every session.
      for b in cast forge anvil chisel; do
        if [[ -x "$HOME/.foundry/bin/$b" ]]; then
          cp -f "$HOME/.foundry/bin/$b" "$PREFIX/bin/$b" 2>/dev/null || true
        fi
      done
      ok "  installed to $HOME/.foundry/bin/ and \$PREFIX/bin/"
    else
      # --- Linux / macOS: standard foundryup -------------------------
      log "  downloading foundryup"
      curl -L https://foundry.paradigm.xyz | bash
      log "  running foundryup (downloads cast / forge / anvil)"
      # shellcheck disable=SC1091
      [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" 2>/dev/null || true
      "$HOME/.foundry/bin/foundryup"
    fi

    # Verify.
    # Always put $HOME/.foundry/bin on PATH for the rest of this
    # install, regardless of whether the install also created
    # $PREFIX/bin symlinks. This is the canonical Foundry install
    # location and what 'forge test' will look for in the next step.
    export PATH="$HOME/.foundry/bin:$PATH"
    if ! command -v cast >/dev/null 2>&1 || ! cast --version >/dev/null 2>&1; then
      fail "Foundry install failed: 'cast' is not on PATH or does not work" 2
    fi

    # Persist PATH for future shells.
    if [[ -f "$HOME/.bashrc" ]] && ! grep -q '\.foundry/bin' "$HOME/.bashrc"; then
      printf '\n# Foundry (added by LCP install.sh)\nexport PATH="$HOME/.foundry/bin:$PATH"\n' \
        >> "$HOME/.bashrc"
    fi
    if [[ -f "$HOME/.profile" ]] && ! grep -q '\.foundry/bin' "$HOME/.profile"; then
      printf '\n# Foundry (added by LCP install.sh)\nexport PATH="$HOME/.foundry/bin:$PATH"\n' \
        >> "$HOME/.profile"
    fi
  fi
else
  log "Step 2/6: Foundry (skipped via --skip-forge)"
fi

# --- Step 3: solc (Solidity compiler) ---------------------------------------
# forge shells out to 'solc'. On Linux x86_64 the bundled solc-bin
# works; on Linux arm64 and Termux we need a static solc.
log "Step 3/6: Solidity compiler (solc)"
if command -v solc >/dev/null 2>&1 && solc --version >/dev/null 2>&1; then
  ok "solc already installed: $(solc --version 2>&1 | head -1)"
else
  # Download the official static solc directly from the Solidity
  # binaries mirror. Both linux-amd64 and linux-arm64 are available.
  case "$(uname -m)" in
    x86_64|amd64)   SOLC_ARCH="linux-amd64" ;;
    aarch64|arm64)  SOLC_ARCH="linux-arm64" ;;
    *)              SOLC_ARCH="" ;;
  esac
  if [[ -n "$SOLC_ARCH" ]]; then
    log "  downloading solc 0.8.31 ($SOLC_ARCH static binary)"
    SOLC_URL="https://binaries.soliditylang.org/${SOLC_ARCH}/solc-${SOLC_ARCH}-v0.8.31+commit.fd3a2265"
    # Stream to stdout, redirect to file. Some Termux builds hit a
    # 'curl: (23) client returned ERROR on write' bug with -o.
    # Use a $HOME path for the temp file (not /tmp, which can be
    # owned by another uid on Termux).
    SOLC_TMP="$HOME/.lcp-solc.$$"
    rm -f "$SOLC_TMP"
    if curl -fsSL --retry 3 --retry-delay 2 "$SOLC_URL" 2>/dev/null > "$SOLC_TMP"; then
      if [[ $TERMUX -eq 1 ]]; then
        cp -f "$SOLC_TMP" "$PREFIX/bin/solc"
        chmod +x "$PREFIX/bin/solc"
        ok "  solc installed at $PREFIX/bin/solc"
        # $PREFIX/bin is on PATH in Termux, but be defensive.
        export PATH="$PREFIX/bin:$PATH"
      else
        install -m 0755 "$SOLC_TMP" /usr/local/bin/solc
        ok "  solc installed at /usr/local/bin/solc"
        export PATH="/usr/local/bin:$PATH"
      fi
      rm -f "$SOLC_TMP"
    else
      rm -f "$SOLC_TMP"
      warn "  failed to download solc from $SOLC_URL"
      warn "  continuing without solc. forge will try to download it"
      warn "  itself the first time you run 'forge test'."
      warn "  If that also fails, run the install again to retry, or:"
      warn "    curl -fsSL '$SOLC_URL' -o \$PREFIX/bin/solc && chmod +x \$PREFIX/bin/solc"
    fi
  else
    warn "no static solc available for $(uname -m); forge may use its bundled solc-bin"
  fi
fi

# --- Step 4: LCP repo + forge-std --------------------------------------------
log "Step 4/6: LCP repo + forge-std"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the actual LCP repo directory. Three cases:
#  1. SCRIPT_DIR is a git repo (the user ran from a real clone).
#  2. SCRIPT_DIR is empty/non-existent and $HOME/LCP is a real clone.
#     (user ran install.sh from an empty target, auto-recovery).
#  3. $HOME/LCP exists but isn't a git repo and isn't empty.
#     This is a partially-failed previous install. We refuse to
#     clobber; we tell the user to clean up and re-run.
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  log "  using $SCRIPT_DIR (git repo)"
  cd "$SCRIPT_DIR"
elif [[ -d "$HOME/LCP/.git" ]]; then
  log "  $SCRIPT_DIR is not a git repo; using existing $HOME/LCP"
  SCRIPT_DIR="$HOME/LCP"
  cd "$SCRIPT_DIR"
elif [[ -d "$HOME/LCP" ]] && [[ -n "$(ls -A "$HOME/LCP" 2>/dev/null)" ]]; then
  warn "  $HOME/LCP exists and is non-empty but is not a git repo."
  warn "  This usually means a previous 'git clone' failed mid-way."
  warn "  Run:    rm -rf \$HOME/LCP"
  warn "  Then re-run: ./install.sh"
  fail "aborting to avoid clobbering existing files" 5
else
  log "  cloning LCP into $HOME/LCP"
  git clone --depth 1 https://github.com/networkbike/LCP.git "$HOME/LCP"
  SCRIPT_DIR="$HOME/LCP"
  cd "$SCRIPT_DIR"
fi

# Refresh from origin if we have a clean git repo.
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  log "  refreshing $SCRIPT_DIR from origin"
  git pull --ff-only 2>/dev/null || true
fi

if [[ ! -d "$SCRIPT_DIR/lib/forge-std" ]]; then
  log "  cloning forge-std into lib/"
  git clone --depth 1 https://github.com/foundry-rs/forge-std.git "$SCRIPT_DIR/lib/forge-std"
else
  log "  forge-std already present in lib/"
fi
ok "LCP repo + forge-std ready at $SCRIPT_DIR"

# --- Step 5: Make the CLI executable ----------------------------------------
log "Step 5/6: marking CLI as executable"
chmod +x "$SCRIPT_DIR/examples/score.sh" "$SCRIPT_DIR/test/test_score.sh"
ok "examples/score.sh and test/test_score.sh are +x"

# --- Step 6: Verify by running the test suite -------------------------------
if [[ $SKIP_VERIFY -eq 0 ]]; then
  log "Step 6/6: running forge test -vvv"
  cd "$SCRIPT_DIR"
  # Use $HOME for log files. On Termux, /tmp is sometimes owned by
  # a different uid and unwriteable, causing 'tee: Permission denied'.
  FORGE_LOG="$HOME/.lcp-forge-test.log"
  SHELL_LOG="$HOME/.lcp-shell-test.log"
  rm -f "$FORGE_LOG" "$SHELL_LOG" 2>/dev/null || true
  if ! forge test 2>&1 | tee "$FORGE_LOG" | tail -20; then
    fail "forge test failed (see $FORGE_LOG)" 3
  fi
  if ! grep -q "7 passed" "$FORGE_LOG"; then
    fail "forge test did not report 7 passed" 3
  fi
  ok "forge test: 7 passed; 0 failed"

  log "  running bash test/test_score.sh"
  if ! bash test/test_score.sh 2>&1 | tee "$SHELL_LOG" | tail -10; then
    fail "shell smoke test failed (see $SHELL_LOG)" 4
  fi
  ok "shell smoke test passed"
else
  log "Step 6/6: skipped via --skip-verify"
fi

# --- Done --------------------------------------------------------------------
cat <<'DONE'

  LCP install: complete.

  Quick commands (from this directory, in any new shell):
    export PATH="$HOME/.foundry/bin:$PATH"
    cd ~/LCP
    forge test -vvv                                  # Foundry test suite (7 passing)
    bash test/test_score.sh                          # shell smoke test (4 passing, 1 skipped)
    ./examples/score.sh native:PROS mainnet          # one-shot CLI run

  Optional — exercise the live ERC-20 path (requires anvil):
    anvil --port 8545 &                              # in another shell
    LCP_LIVE_TEST=1 LCP_RPC_URL=http://127.0.0.1:8545 bash test/test_score.sh
                                                      # 11 passing; 0 failed

DONE
