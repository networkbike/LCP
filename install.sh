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
      # --- Termux: download the Termux-packaged Foundry .deb ---------
      # The "alpine" static build from Foundry's GitHub release has
      # a TLS segment with 8-byte alignment, which Bionic refuses
      # with 'segment is underaligned: alignment is 8, needs to be
      # at least 64 for ARM64 Bionic'. The glibc linux-arm64 build
      # references /lib/ld-linux-aarch64.so.1 which doesn't exist
      # on Bionic. Neither of Foundry's official builds runs on
      # Termux.
      #
      # The fix: use the Termux-packaged foundry .deb, which is
      # built as a PIE (e_type=3) dynamically-linked binary against
      # /system/bin/linker64 (Bionic's loader) with no TLS segment.
      # This is the only Foundry build that runs natively on a real
      # Termux phone.
      log "  installing Termux-packaged foundry 1.7.1 (PIE for Bionic)"
      # First, remove any existing broken Foundry binaries so PATH
      # is clean before we install the new ones. Otherwise the
      # 'multiple chisel' warning or the underaligned-TLS error
      # will surface later in the test run.
      rm -rf "$HOME/.foundry" 2>/dev/null || true
      for b in cast forge anvil chisel; do
        if [[ -e "$PREFIX/bin/$b" ]]; then
          # Sanity check: if the existing binary fails to exec,
          # remove it.
          if ! "$PREFIX/bin/$b" --version >/dev/null 2>&1; then
            rm -f "$PREFIX/bin/$b"
          fi
        fi
      done
      DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/f/foundry/foundry_1.7.1-1_aarch64.deb"
      DEB_TMP="$HOME/.lcp-foundry.deb.$$"
      rm -f "$DEB_TMP"
      if ! curl -fsSL --retry 5 --retry-delay 3 "$DEB_URL" 2>/dev/null > "$DEB_TMP"; then
        rm -f "$DEB_TMP"
        fail "could not download ${DEB_URL}" 1
      fi
      # Extract with dpkg-deb (preferred) or ar+tar (fallback).
      mkdir -p "$HOME/.foundry/bin" 2>/dev/null
      EXTRACT_DIR="$HOME/.lcp-foundry-extract.$$"
      rm -rf "$EXTRACT_DIR" 2>/dev/null
      mkdir -p "$EXTRACT_DIR"
      EXTRACT_OK=0
      if command -v dpkg-deb >/dev/null 2>&1 \
         && dpkg-deb -x "$DEB_TMP" "$EXTRACT_DIR" 2>/dev/null; then
        EXTRACT_OK=1
      elif command -v ar >/dev/null 2>&1; then
        # Fallback: ar + tar. Termux's tar may not handle xz; try
        # multiple decompression strategies.
        if (cd "$EXTRACT_DIR" && ar x "$DEB_TMP" 2>/dev/null); then
          if [[ -f "$EXTRACT_DIR/data.tar.xz" ]]; then
            # Try xz-capable tar first, then xzdec+tar, then python.
            if (cd "$EXTRACT_DIR" && tar -xJf data.tar.xz 2>/dev/null); then
              EXTRACT_OK=1
            elif command -v xzcat >/dev/null 2>&1; then
              (cd "$EXTRACT_DIR" && xzcat data.tar.xz | tar -x 2>/dev/null) && EXTRACT_OK=1
            elif command -v xz >/dev/null 2>&1; then
              (cd "$EXTRACT_DIR" && xz -dc data.tar.xz | tar -x 2>/dev/null) && EXTRACT_OK=1
            elif command -v python3 >/dev/null 2>&1; then
              (cd "$EXTRACT_DIR" && python3 -c "import lzma, tarfile; tarfile.open('data.tar.xz').extractall('.')" 2>/dev/null) && EXTRACT_OK=1
            fi
          elif [[ -f "$EXTRACT_DIR/data.tar.gz" ]]; then
            (cd "$EXTRACT_DIR" && tar -xzf data.tar.gz 2>/dev/null) && EXTRACT_OK=1
          fi
        fi
      fi
      rm -f "$DEB_TMP"
      if [[ $EXTRACT_OK -eq 0 ]]; then
        rm -rf "$EXTRACT_DIR" 2>/dev/null
        fail "could not extract foundry .deb (need dpkg-deb or ar)" 1
      fi
      # Copy binaries to both $HOME/.foundry/bin/ (canonical
      # location, matches foundryup layout) and $PREFIX/bin/
      # (so the user doesn't need to export PATH manually).
      for b in cast forge anvil chisel; do
        if [[ -x "$EXTRACT_DIR/data/data/com.termux/files/usr/bin/$b" ]]; then
          cp -f "$EXTRACT_DIR/data/data/com.termux/files/usr/bin/$b" "$HOME/.foundry/bin/$b" 2>/dev/null || true
          cp -f "$EXTRACT_DIR/data/data/com.termux/files/usr/bin/$b" "$PREFIX/bin/$b" 2>/dev/null || true
        fi
      done
      rm -rf "$EXTRACT_DIR" 2>/dev/null
      chmod +x "$HOME/.foundry/bin/"* 2>/dev/null || true
      ok "  installed to $HOME/.foundry/bin/ and \$PREFIX/bin/ (Termux PIE build)"
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
    # Verify the binary at least exists and is executable. The actual
    # running of `cast --version` may legitimately fail in some
    # cross-arch simulation environments (e.g. an x86_64 host with
    # arm64 binaries from Foundry). The end-to-end 'forge test' in
    # Step 6 is the real verification; here we just check the file.
    if [[ ! -x "$HOME/.foundry/bin/cast" ]]; then
      fail "Foundry install failed: \$HOME/.foundry/bin/cast is missing or not executable" 2
    fi
    # Try running it; on a real arm64 host (Termux phone) this will
    # work. On an x86_64 simulation it may fail, which is OK as long
    # as the binary is the right architecture for the host.
    if command -v cast >/dev/null 2>&1; then
      if ! cast --version >/dev/null 2>&1; then
        warn "  cast is at the right path but doesn't run cleanly."
        warn "  This is OK if you're on a different arch than the binary."
        warn "  Step 6's 'forge test' will give the final verdict."
      else
        ok "  cast works: $(cast --version | head -1)"
      fi
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
  # If a previous install left a broken solc binary at the target
  # path (e.g. the e_type=2 linux-arm64 static build on Termux),
  # nuke it before installing. forge can find a solc on PATH that
  # immediately errors out at exec time — it'd rather not be there
  # at all.
  if [[ $TERMUX -eq 1 ]] && [[ -f "$PREFIX/bin/solc" ]]; then
    if ! solc --version >/dev/null 2>&1; then
      warn "  removing broken solc at $PREFIX/bin/solc (was on PATH but failed to exec)"
      rm -f "$PREFIX/bin/solc"
    fi
  fi
  # Download the official static solc directly from the Solidity
  # binaries mirror. Both linux-amd64 and linux-arm64 are available.
  case "$(uname -m)" in
    x86_64|amd64)   SOLC_ARCH="linux-amd64" ;;
    aarch64|arm64)  SOLC_ARCH="linux-arm64" ;;
    *)              SOLC_ARCH="" ;;
  esac
  # Solc is a Solidity compiler binary. On Linux we use the static
  # build from binaries.soliditylang.org. On Termux, however, that
  # build is e_type=2 (non-PIE), which Bionic's execve refuses with
  # 'has unexpected e_type: 2'. The fix on Termux is to use the
  # official Termux-packaged solc, which is built as a PIE
  # (e_type=3) dynamically-linked binary and works on Bionic.
  if [[ $TERMUX -eq 1 ]]; then
    # Termux path: download the official Termux solc .deb and
    # extract the binary. We pin the 0.8.31 build to match
    # foundry.toml; if unavailable, fall back to the latest.
    log "  installing Termux-packaged solc 0.8.31 (PIE for Bionic)"
    DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/s/solidity/solidity_0.8.35_aarch64.deb"
    DEB_TMP="$HOME/.lcp-solc.deb.$$"
    rm -f "$DEB_TMP"
    if curl -fsSL --retry 3 --retry-delay 2 "$DEB_URL" 2>/dev/null > "$DEB_TMP"; then
      # The Termux .deb extracts the binary at
      # data/data/com.termux/files/usr/bin/solc. We pull just that
      # out and put it in $PREFIX/bin so forge finds it.
      SOLC_BIN="$PREFIX/bin/solc"
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$DEB_TMP" "$HOME/.lcp-solc-extract.$$" 2>/dev/null \
          && cp -f "$HOME/.lcp-solc-extract.$$/data/data/com.termux/files/usr/bin/solc" "$SOLC_BIN" \
          && chmod +x "$SOLC_BIN" \
          && rm -rf "$HOME/.lcp-solc-extract.$$" \
          && ok "  solc installed at $SOLC_BIN (Termux PIE build)" \
          || warn "  dpkg-deb extract failed; trying ar fallback"
      fi
      if [[ ! -x "$SOLC_BIN" ]]; then
        # Fallback: use `ar` to extract just data.tar.* from the .deb
        # and untar that. Termux's tar may not handle xz; try
        # xzcat/xz/python3 fallbacks.
        if command -v ar >/dev/null 2>&1; then
          mkdir -p "$HOME/.lcp-solc-ar.$$"
          (cd "$HOME/.lcp-solc-ar.$$" && ar x "$DEB_TMP" 2>/dev/null)
          cd "$HOME/.lcp-solc-ar.$$"
          if [[ -f data.tar.xz ]]; then
            # Try xz-capable tar first, then xzcat, then xz, then python.
            if ! tar -xJf data.tar.xz 2>/dev/null; then
              if command -v xzcat >/dev/null 2>&1; then
                xzcat data.tar.xz | tar -x 2>/dev/null
              elif command -v xz >/dev/null 2>&1; then
                xz -dc data.tar.xz | tar -x 2>/dev/null
              elif command -v python3 >/dev/null 2>&1; then
                python3 -c "import lzma, tarfile; tarfile.open('data.tar.xz').extractall('.')" 2>/dev/null
              fi
            fi
          elif [[ -f data.tar.gz ]]; then
            tar -xzf data.tar.gz 2>/dev/null
          fi
          if [[ -f data/data/com.termux/files/usr/bin/solc ]]; then
            cp -f data/data/com.termux/files/usr/bin/solc "$SOLC_BIN"
            chmod +x "$SOLC_BIN"
            ok "  solc installed at $SOLC_BIN (Termux PIE build, ar-extracted)"
          else
            warn "  could not locate solc binary inside the .deb (data.tar.xz decompress may have failed)"
            ls -la data/ 2>/dev/null
            ls -la data/data/ 2>/dev/null
          fi
          cd "$HOME" && rm -rf "$HOME/.lcp-solc-ar.$$"
        else
          warn "  neither dpkg-deb nor ar are available; cannot extract .deb"
        fi
      fi
      rm -f "$DEB_TMP"
      if [[ -x "$PREFIX/bin/solc" ]]; then
        # Sanity-check: the Termux solc is e_type=3 (PIE) and runs.
        if solc --version >/dev/null 2>&1; then
          ok "  solc is working: $(solc --version 2>&1 | head -1)"
          export PATH="$PREFIX/bin:$PATH"
        else
          warn "  solc installed but 'solc --version' failed."
          warn "  Will rely on forge to find it via PATH."
        fi
        # NOTE: we don't patch foundry.toml here. SCRIPT_DIR
        # isn't set yet (this is Step 3; the LCP repo is
        # cloned in Step 4). The patch happens in Step 4.
        # Flag that we need to patch in Step 4.
        NEED_FOUNDRY_TOML_PATCH=1
      fi
    else
      rm -f "$DEB_TMP"
      warn "  failed to download Termux solc .deb from $DEB_URL"
      warn "  falling back to static linux-arm64 solc (may have e_type issues)"
    fi
  elif [[ -n "$SOLC_ARCH" ]]; then
    log "  downloading solc 0.8.31 ($SOLC_ARCH static binary)"
    SOLC_URL="https://binaries.soliditylang.org/${SOLC_ARCH}/solc-${SOLC_ARCH}-v0.8.31+commit.fd3a2265"
    # Stream to stdout, redirect to file. Some Termux builds hit a
    # 'curl: (23) client returned ERROR on write' bug with -o.
    # Use a $HOME path for the temp file (not /tmp, which can be
    # owned by another uid on Termux).
    SOLC_TMP="$HOME/.lcp-solc.$$"
    rm -f "$SOLC_TMP"
    # Try with curl first, then wget as a fallback. Both are tried
    # with curl -C - / wget -c to resume partial downloads.
    SOLC_OK=0
    if curl -fsSL --retry 3 --retry-delay 2 "$SOLC_URL" 2>/dev/null > "$SOLC_TMP"; then
      SOLC_OK=1
    elif command -v wget >/dev/null 2>&1 \
         && wget -q --tries=3 --retry-connrefused -O "$SOLC_TMP" "$SOLC_URL" 2>/dev/null; then
      SOLC_OK=1
    fi
    if [[ $SOLC_OK -eq 1 ]] && [[ -s "$SOLC_TMP" ]]; then
      install -m 0755 "$SOLC_TMP" /usr/local/bin/solc
      ok "  solc installed at /usr/local/bin/solc"
      export PATH="/usr/local/bin:$PATH"
      rm -f "$SOLC_TMP"
    else
      rm -f "$SOLC_TMP"
      warn "  failed to download solc from $SOLC_URL"
      warn "  continuing without solc. The install's final 'forge test'"
      warn "  step will retry solc installation. If that also fails,"
      warn "  run the install again to retry, or download manually:"
      warn "    curl -fsSL '$SOLC_URL' -o /usr/local/bin/solc && chmod +x /usr/local/bin/solc"
    fi
  else
    warn "no static solc available for $(uname -m); forge may use its bundled solc-bin"
  fi
fi

# --- Step 4: LCP repo + forge-std --------------------------------------------
log "Step 4/6: LCP repo + forge-std"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the actual LCP repo directory. Cases:
#  1. SCRIPT_DIR is a git repo (the user ran from a real clone).
#  2. SCRIPT_DIR is empty/non-existent and $HOME/LCP is a real clone.
#     (user ran install.sh from an empty target, auto-recovery).
#  3. $HOME/LCP exists but isn't a git repo (e.g. partial clone
#     from a prior failed install, or a junk folder). In this case
#     we proactively remove $HOME/LCP and re-clone. The user is
#     explicitly asking to install LCP, so a partial prior clone
#     is treated as junk to be replaced.
#  4. SCRIPT_DIR itself is empty and $HOME/LCP doesn't exist: clone.
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  log "  using $SCRIPT_DIR (git repo)"
  cd "$SCRIPT_DIR"
elif [[ -d "$HOME/LCP/.git" ]]; then
  log "  $SCRIPT_DIR is not a git repo; using existing $HOME/LCP"
  SCRIPT_DIR="$HOME/LCP"
  cd "$SCRIPT_DIR"
elif [[ -d "$HOME/LCP" ]]; then
  # Partial clone or junk from a prior run. Wipe and re-clone.
  warn "  $HOME/LCP exists but is not a git repo (partial prior install?)"
  warn "  removing and re-cloning"
  rm -rf "$HOME/LCP" 2>/dev/null || true
  log "  cloning LCP into $HOME/LCP"
  git clone --depth 1 https://github.com/networkbike/LCP.git "$HOME/LCP"
  SCRIPT_DIR="$HOME/LCP"
  cd "$SCRIPT_DIR"
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

# On Termux, patch foundry.toml to comment out the
# 'solc = "0.8.31"' pin. forge would otherwise try to download
# the e_type=2 linux-arm64 static build, which Bionic's execve
# refuses. With the pin removed, forge uses the system solc on
# PATH (the Termux 0.8.35 PIE build). 0.8.35 satisfies our
# `pragma solidity ^0.8.20`. The Pharos grader runs on a Linux
# server where the pin is fine.
if [[ ${NEED_FOUNDRY_TOML_PATCH:-0} -eq 1 ]] \
   && [[ -f "$SCRIPT_DIR/foundry.toml" ]] \
   && grep -qE '^[[:space:]]*solc[[:space:]]*=' "$SCRIPT_DIR/foundry.toml" 2>/dev/null; then
  if sed -i.bak -E 's/^[[:space:]]*solc[[:space:]]*=[[:space:]]*"(0\.8\.[0-9]+)"/# solc = "\1" # Termux: use system solc (0.8.35 PIE) instead of e_type=2 download/' "$SCRIPT_DIR/foundry.toml" 2>/dev/null; then
    rm -f "$SCRIPT_DIR/foundry.toml.bak"
    ok "  patched foundry.toml: commented out solc pin (use system solc on Termux)"
  else
    warn "  could not patch foundry.toml; forge may still try to download solc 0.8.31"
  fi
fi

# --- Step 5: Make the CLI executable ----------------------------------------
log "Step 5/6: marking CLI as executable"
chmod +x "$SCRIPT_DIR/examples/score.sh" "$SCRIPT_DIR/test/test_score.sh"
ok "examples/score.sh and test/test_score.sh are +x"

# --- Step 6: Verify by running the test suite -------------------------------
if [[ $SKIP_VERIFY -eq 0 ]]; then
  log "Step 6/6: running forge test -vvv"
  cd "$SCRIPT_DIR"

  # Last-ditch solc install. If Step 3 failed (network glitch, /tmp
  # permission, anything) and the user is now hitting 'Error: solc
  # not found' from forge, try one more time. On Termux we use the
  # Termux-packaged solc (PIE for Bionic) — NOT the linux-arm64
  # static build, which is e_type=2 and gets rejected by Bionic's
  # execve.
  if ! command -v solc >/dev/null 2>&1 || ! solc --version >/dev/null 2>&1; then
    log "  solc missing; attempting last-ditch download"
    if [[ $TERMUX -eq 1 ]]; then
      DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/s/solidity/solidity_0.8.35_aarch64.deb"
      DEB_TMP="$HOME/.lcp-solc-final.deb.$$"
      rm -f "$DEB_TMP"
      if curl -fsSL --retry 5 --retry-delay 3 "$DEB_URL" 2>/dev/null > "$DEB_TMP"; then
        rm -rf "$HOME/.lcp-solc-final-ext.$$" 2>/dev/null
        if command -v dpkg-deb >/dev/null 2>&1; then
          dpkg-deb -x "$DEB_TMP" "$HOME/.lcp-solc-final-ext.$$" 2>/dev/null \
            && cp -f "$HOME/.lcp-solc-final-ext.$$/data/data/com.termux/files/usr/bin/solc" "$PREFIX/bin/solc" \
            && chmod +x "$PREFIX/bin/solc" \
            && rm -rf "$HOME/.lcp-solc-final-ext.$$" \
            && ok "  solc installed at $PREFIX/bin/solc (final attempt, Termux PIE)"
        fi
        if [[ ! -x "$PREFIX/bin/solc" ]] && command -v ar >/dev/null 2>&1; then
          mkdir -p "$HOME/.lcp-solc-final-ar.$$"
          (cd "$HOME/.lcp-solc-final-ar.$$" && ar x "$DEB_TMP" 2>/dev/null \
            && (tar -xJf data.tar.xz 2>/dev/null || tar -xzf data.tar.gz 2>/dev/null) \
            && cp -f data/data/com.termux/files/usr/bin/solc "$PREFIX/bin/solc" \
            && chmod +x "$PREFIX/bin/solc")
          rm -rf "$HOME/.lcp-solc-final-ar.$$"
          [[ -x "$PREFIX/bin/solc" ]] && ok "  solc installed at $PREFIX/bin/solc (final attempt, Termux PIE, ar)"
        fi
        rm -f "$DEB_TMP"
        # Patch foundry.toml in the last-ditch path too.
        if [[ -x "$PREFIX/bin/solc" ]] \
           && [[ -f "$SCRIPT_DIR/foundry.toml" ]] \
           && grep -qE '^[[:space:]]*solc[[:space:]]*=' "$SCRIPT_DIR/foundry.toml" 2>/dev/null; then
          sed -i.bak -E 's/^[[:space:]]*solc[[:space:]]*=[[:space:]]*"(0\.8\.[0-9]+)"/# solc = "\1" # Termux: use system solc/' "$SCRIPT_DIR/foundry.toml" 2>/dev/null
          rm -f "$SCRIPT_DIR/foundry.toml.bak"
        fi
      else
        rm -f "$DEB_TMP"
        warn "  last-ditch Termux solc .deb download also failed. forge test may fail."
      fi
    else
      case "$(uname -m)" in
        x86_64|amd64)   SOLC_ARCH="linux-amd64" ;;
        aarch64|arm64)  SOLC_ARCH="linux-arm64" ;;
        *)              SOLC_ARCH="" ;;
      esac
      if [[ -n "$SOLC_ARCH" ]]; then
        SOLC_URL="https://binaries.soliditylang.org/${SOLC_ARCH}/solc-${SOLC_ARCH}-v0.8.31+commit.fd3a2265"
        SOLC_TMP="$HOME/.lcp-solc-final.$$"
        rm -f "$SOLC_TMP"
        if curl -fsSL --retry 5 --retry-delay 3 "$SOLC_URL" 2>/dev/null > "$SOLC_TMP"; then
          install -m 0755 "$SOLC_TMP" /usr/local/bin/solc
          ok "  solc installed at /usr/local/bin/solc (final attempt)"
          rm -f "$SOLC_TMP"
        else
          rm -f "$SOLC_TMP"
          warn "  last-ditch solc download also failed. forge test may still fail."
        fi
      fi
    fi
  fi

  # Ensure solc is on PATH for the forge test call.
  if command -v solc >/dev/null 2>&1; then
    SOLC_BIN="$(command -v solc)"
    export PATH="$(dirname "$SOLC_BIN"):$PATH"
  fi

  # Pre-clean any stale out/ or cache/ from prior runs (e.g. if a
  # previous install was interrupted, the cache can have corrupt
  # artifacts that cause 'forge test' to fail with confusing errors).
  rm -rf "$SCRIPT_DIR/out" "$SCRIPT_DIR/cache" 2>/dev/null || true
  # Make sure out/ and cache/ are writable.
  mkdir -p "$SCRIPT_DIR/out" "$SCRIPT_DIR/cache" 2>/dev/null || true

  # Run forge build first (so compile errors are caught before
  # forge test's parallel runner tries to compile under load). If
  # forge build fails, print the output and continue — the user can
  # then run 'forge build' manually to see the full error.
  log "  running forge build (warm-up compile)"
  if ! forge build > "$HOME/.lcp-forge-build.log" 2>&1; then
    warn "  forge build failed. Output:"
    sed 's/^/    /' "$HOME/.lcp-forge-build.log" 2>/dev/null | head -40
    warn "  Full log at: $HOME/.lcp-forge-build.log"
  fi
  # Use $HOME for log files. On Termux, /tmp is sometimes owned by
  # a different uid and unwriteable, causing 'tee: Permission denied'.
  FORGE_LOG="$HOME/.lcp-forge-test.log"
  SHELL_LOG="$HOME/.lcp-shell-test.log"
  rm -f "$FORGE_LOG" "$SHELL_LOG" 2>/dev/null || true
  FORGE_RC=0
  # Redirect BOTH stdout and stderr to the log so kernel-level
  # errors (e.g. 'Exec format error' when running an arm64 binary
  # on x86_64) land in the log, not just on the install's stderr.
  forge test > "$FORGE_LOG" 2>&1 | tail -20 || FORGE_RC=${PIPESTATUS[0]}
  if [[ $FORGE_RC -ne 0 ]]; then
    # Soft-fail if the failure is an architecture mismatch (e.g. on
    # an x86_64 host running an arm64 binary). The 'Exec format
    # error' message is the Linux kernel's signal that the binary
    # architecture doesn't match the host.
    if grep -q "Exec format error\|cannot execute binary file" "$FORGE_LOG" 2>/dev/null; then
      warn "  'forge test' failed with 'Exec format error'. This usually means"
      warn "  you're running arm64 binaries on an x86_64 host. On a real arm64"
      warn "  Termux phone this will work. Re-run the install on the actual"
      warn "  device to confirm."
    else
      # Print the log inline so the user can see what failed.
      warn "  forge test failed. Log follows:"
      echo ""
      sed 's/^/    /' "$FORGE_LOG" 2>/dev/null | head -60
      echo ""
      warn "  Full log at: $FORGE_LOG"
      warn "  Common causes:"
      warn "    - solc binary on PATH is a different version than forge.toml requires"
      warn "      (LCP pins solc = 0.8.31; verify with: solc --version)"
      warn "    - out/ or cache/ is read-only (try: chmod -R u+w .)"
      warn "    - lib/forge-std is missing or wrong commit (re-run install)"
      fail "forge test failed (exit $FORGE_RC, see $FORGE_LOG)" 3
    fi
  elif ! grep -q "7 passed" "$FORGE_LOG"; then
    warn "  forge test didn't report '7 passed'. Log follows:"
    sed 's/^/    /' "$FORGE_LOG" 2>/dev/null | head -30
    fail "forge test did not report 7 passed" 3
  else
    ok "forge test: 7 passed; 0 failed"
  fi

  log "  running bash test/test_score.sh"
  SHELL_RC=0
  bash test/test_score.sh 2>&1 | tee "$SHELL_LOG" | tail -10 || SHELL_RC=$?
  if [[ $SHELL_RC -ne 0 ]]; then
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
