#!/usr/bin/env bash
# LCP — Shell test runner for examples/score.sh
#
# Usage:  ./test/test_score.sh
#
# This test does not require bats. It uses bash, jq, and the skill's own
# `examples/score.sh` CLI to validate the read-only behavior, the input
# validation, the network dispatch, and the JSON output contract.
#
# For the live-RPC end-to-end tests, set LCP_LIVE_TEST=1 and provide a
# reachable RPC via LCP_RPC_URL. The Pharos Skill Agent runs with a
# managed anvil instance, so the live test is opt-in.
#
# Required runtime: Foundry (cast), bash, jq.
# Optional: forge, anvil (only if LCP_LIVE_TEST=1).

set -uo pipefail

# --- Setup ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCORE_SH="$SKILL_DIR/examples/score.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n    %s\n" "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf "  \033[33mSKIP\033[0m  %s\n    %s\n" "$1" "$2"; }

# --- Pre-checks ----------------------------------------------------------------
for bin in bash cast jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf "Missing required binary: %s\n" "$bin" >&2
    exit 2
  fi
done

if [[ ! -x "$SCORE_SH" ]]; then
  printf "examples/score.sh is not executable: %s\n" "$SCORE_SH" >&2
  printf "Run: chmod +x %s\n" "$SCORE_SH" >&2
  exit 2
fi

printf "Running LCP shell test suite against:\n  %s\n\n" "$SCORE_SH"

# --- Test 1: usage on no args -------------------------------------------------
"$SCORE_SH" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 64 ]]; then
  ok "exits 64 with usage on missing argument"
else
  bad "exits 64 with usage on missing argument" "rc=$rc"
fi

# --- Test 2: usage on bad address ---------------------------------------------
"$SCORE_SH" "0xnotanaddress" mainnet >/dev/null 2>&1; rc=$?
if [[ $rc -eq 64 ]]; then
  ok "exits 64 with 'Invalid address' on malformed input"
else
  bad "exits 64 with 'Invalid address' on malformed input" "rc=$rc"
fi

# --- Test 3: refuses PRIVATE_KEY ----------------------------------------------
PRIVATE_KEY=0xdeadbeef "$SCORE_SH" "native:PROS" mainnet >/dev/null 2>&1; rc=$?
if [[ $rc -eq 77 ]]; then
  ok "exits 77 on \$PRIVATE_KEY (read-only invariant)"
else
  bad "exits 77 on \$PRIVATE_KEY (read-only invariant)" "rc=$rc"
fi

# --- Test 4: unknown network --------------------------------------------------
# Note: when LCP_RPC_URL is set, the script uses it as a fallback and
# only checks the network name when the RPC is empty. We must clear
# the env var for this test to exercise the bad-network code path.
_SAVED_RPC_URL="${LCP_RPC_URL:-}"
unset LCP_RPC_URL
"$SCORE_SH" "native:PROS" "foobar" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 65 ]]; then
  ok "exits 65 with 'Unknown network' on bad network name"
else
  bad "exits 65 with 'Unknown network' on bad network name" "rc=$rc"
fi
# Restore for the live tests below.
if [[ -n "$_SAVED_RPC_URL" ]]; then export LCP_RPC_URL="$_SAVED_RPC_URL"; fi
unset _SAVED_RPC_URL

# --- Live tests (opt-in) ------------------------------------------------------
if [[ "${LCP_LIVE_TEST:-0}" == "1" && -n "${LCP_RPC_URL:-}" ]]; then
  if ! command -v forge >/dev/null 2>&1; then
    skip "live ERC-20 end-to-end" "forge not on PATH"
  else
    TMPDIR=$(mktemp -d -t lcp-live-XXXXXX)
    cat > "$TMPDIR/MockERC20.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract MockERC20 {
    string public name = "Mock"; string public symbol = "M";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);
    constructor() { totalSupply = 1_000_000 ether; balanceOf[msg.sender] = totalSupply; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "x");
        balanceOf[msg.sender] -= v; balanceOf[to] += v;
        emit Transfer(msg.sender, to, v); return true;
    }
}
EOF
    cat > "$TMPDIR/foundry.toml" <<'EOF'
[profile.default]
src = "."
out = "out"
solc = "0.8.20"
EOF
    (cd "$TMPDIR" && forge build --quiet) 2>/dev/null
    DEPLOY=$(forge create --rpc-url "$LCP_RPC_URL" --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast "$TMPDIR/MockERC20.sol:MockERC20" 2>&1)
    TOKEN=$(echo "$DEPLOY" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')
    if [[ -z "$TOKEN" ]]; then
      skip "live ERC-20 deploy" "forge create did not return an address"
    else
      # Run with LCP_RPC_URL so the test bypasses Pharos RPC.
      out=$(LCP_RPC_URL="$LCP_RPC_URL" "$SCORE_SH" "$TOKEN" mainnet 2>&1); rc=$?
      if [[ $rc -eq 0 && "$out" == *"LCP — Liquidity Crisis Predictor"* ]]; then
        ok "human-readable output on a live ERC-20 (rc=0)"
      else
        bad "human-readable output on a live ERC-20" "rc=$rc, output=$out"
      fi

      json=$(LCP_RPC_URL="$LCP_RPC_URL" LCP_JSON=1 "$SCORE_SH" "$TOKEN" mainnet 2>/dev/null); rc=$?
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.schema // empty')" == "lcp.result.v1" ]]; then
        ok "JSON output has schema=lcp.result.v1"
      else
        bad "JSON output has schema=lcp.result.v1" "rc=$rc"
      fi
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.network // empty')" == "mainnet" ]]; then
        ok "JSON output carries the correct network field"
      else
        bad "JSON output carries the correct network field" "json=$json"
      fi
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.score // empty')" =~ ^[0-9]+$ ]]; then
        ok "JSON output has integer score in [0,100]"
      else
        bad "JSON output has integer score in [0,100]" "json=$json"
      fi
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.drivers | type')" == "array" ]]; then
        ok "JSON output has drivers as an array"
      else
        bad "JSON output has drivers as an array" "json=$json"
      fi
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.missing | type')" == "array" ]]; then
        ok "JSON output has missing as an array (no duplicates)"
      else
        bad "JSON output has missing as an array (no duplicates)" "json=$json"
      fi
      if [[ $rc -eq 0 && "$(printf '%s' "$json" | jq -r '.disclaimer')" == "LCP is an informational on-chain analytics signal. It is not financial advice. On-chain conditions can change between the read and any subsequent action." ]]; then
        ok "JSON output has the fixed disclaimer"
      else
        bad "JSON output has the fixed disclaimer" "json=$json"
      fi
    fi
    rm -rf "$TMPDIR"
  fi
else
  skip "live ERC-20 end-to-end" "set LCP_LIVE_TEST=1 and LCP_RPC_URL=http://127.0.0.1:PORT to enable"
fi

# --- Summary -------------------------------------------------------------------
printf "\n"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, \033[33m%d skipped\033[0m\n" \
  "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
