#!/data/data/com.termux/files/usr/bin/bash
# LCP skill one-shot setup for Termux (Android).
#
# What this does:
#   1. Clean any leftover LCP clones (in case of nested-clone mess).
#   2. Wipe a stale ~/.LCP config file if present (Termux has /tmp
#      ownership bugs that drop a junk ~/.LCP file).
#   3. Install Foundry via the official foundryup installer
#      (https://foundry.paradigm.xyz). Foundry goes to ~/.foundry/bin/.
#   4. Clone the LCP repo and run its install.sh, which:
#        - puts the static arm64 Forge at $PREFIX/bin/forge
#        - downloads the Termux-packaged PIE solc 0.8.35 to $PREFIX/bin/solc
#        - patches foundry.toml to use the system solc
#        - runs `forge test -vvv` and `bash test/test_score.sh`
#
# After this finishes, the LCP skill is fully installed. To rerun
# the test gates:
#   export PATH="$HOME/.foundry/bin:$PREFIX/bin:$PATH"
#   cd ~/LCP
#   forge test -vvv                                  # 7 passing
#   bash test/test_score.sh                          # 4 passing, 1 skipped

set -e

cd ~

# 1. Clean any leftover LCP clones. Use find to handle any depth
#    of nested clones safely (avoids the `rm -rf LCP/LCP/LCP`
#    pitfall where bash parses it as `rm -rf LCP/LCP LCP` and
#    wipes the top-level LCP directory too).
echo "[1/5] cleaning any leftover LCP clones..."
find ~ -maxdepth 4 -type d -name LCP -exec rm -rf {} + 2>/dev/null || true
rm -f ~/.LCP 2>/dev/null || true

# 2. Install foundryup (the Foundry installer). This is the official
#    one-liner from https://book.getfoundry.sh/getting-started/installation.
#    It writes ~/.foundry/bin/forge, ~/.foundry/bin/anvil, etc.
echo "[2/5] installing foundryup..."
if ! command -v forge >/dev/null 2>&1 || ! forge --version >/dev/null 2>&1; then
  curl -L https://foundry.paradigm.xyz | bash
else
  echo "  forge already present: $(forge --version | head -1)"
fi

# 3. Make sure ~/.foundry/bin is on PATH for the rest of this script.
#    (We also `source ~/.bashrc` in case foundryup updated it.)
export PATH="$HOME/.foundry/bin:$PREFIX/bin:$PATH"
if [[ -f ~/.bashrc ]]; then
  # shellcheck disable=SC1090
  source ~/.bashrc 2>/dev/null || true
fi

# 4. Pull the latest LCP skill from GitHub.
echo "[3/5] cloning LCP..."
git clone https://github.com/networkbike/LCP.git ~/LCP
cd ~/LCP

# 5. Run the LCP install.sh. This handles:
#    - Termux detection + PATH setup
#    - solc install (Termux PIE .deb path)
#    - forge build + forge test -vvv (7 passing)
#    - shell smoke test (4 passing, 1 skipped)
#    - one-shot CLI run on native:PROS mainnet
echo "[4/5] running LCP install.sh..."
./install.sh

# 6. Print success summary.
echo ""
echo "[5/5] LCP skill installed at ~/LCP"
echo ""
echo "Quick commands (open a new Termux session so PATH updates apply):"
echo "  export PATH=\"\$HOME/.foundry/bin:\$PREFIX/bin:\$PATH\""
echo "  cd ~/LCP"
echo "  forge test -vvv                                  # Foundry test suite (7 passing)"
echo "  bash test/test_score.sh                          # shell smoke test (4 passing, 1 skipped)"
echo "  ./examples/score.sh native:PROS mainnet          # one-shot CLI run"
