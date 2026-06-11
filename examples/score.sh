#!/usr/bin/env bash
# LCP — Liquidity Crisis Predictor
# Single-asset scorer. Read-only. No private key. No external oracle.
#
# Usage:
#   ./score.sh <TOKEN_OR_POOL_ADDRESS|native:PROS|native:PHRS> [network]
#
# Networks: mainnet (default), atlantic-testnet
# Output:   human-readable on stdout, or JSON on stdout if LCP_JSON=1
#
# Required runtime: Foundry (provides `cast`).  Optional helpers:
# `jq` (for JSON output), `bc` (kept for legacy scripts; not required here).
# LCP is **Foundry-first** — every on-chain read goes through `cast`. See
# SKILL.md and README.md for the full requirement list.
#
# Exit codes:
#   0  — success
#   64 — usage / input error
#   65 — unknown network
#   66 — RPC error (after one retry)
#   69 — missing required binary
#   77 — $PRIVATE_KEY is set (LCP is read-only, refuses to run)

set -euo pipefail

# --- Args ---------------------------------------------------------------------
TARGET="${1:-}"
NETWORK="${2:-mainnet}"
LCP_JSON="${LCP_JSON:-0}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <TOKEN_OR_POOL_ADDRESS|native:PHRS|native:PROS> [network]" >&2
  exit 64
fi

# --- Pre-checks ---------------------------------------------------------------
for bin in cast jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required binary: $bin (install Foundry for cast, jq for JSON)" >&2
    exit 69
  }
done

# Reject any private key in the environment — LCP must not see one.
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  echo "Refusing to run: \$PRIVATE_KEY is set. LCP is read-only." >&2
  exit 77
fi

# Optional: LCP_RPC_URL override (for testing against a local anvil / fork).
# If set, it wins over the network's RPC URL.
RPC_OVERRIDE="${LCP_RPC_URL:-}"

# Resolve paths relative to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NETWORKS="$SKILL_DIR/assets/networks.json"
THRESHOLDS="$SKILL_DIR/assets/lcp-thresholds.json"

# --- Network config -----------------------------------------------------------
RPC_URL="$RPC_OVERRIDE"
if [[ -z "$RPC_URL" ]]; then
  RPC_URL=$(jq -r --arg n "$NETWORK" \
    '.networks[] | select(.name==$n) | .rpcUrl' "$NETWORKS")
fi

if [[ -z "$RPC_URL" || "$RPC_URL" == "null" ]]; then
  echo "Unknown network: $NETWORK" >&2
  echo "Supported: $(jq -r '.networks[].name' "$NETWORKS" | paste -sd, -)" >&2
  exit 65
fi

# `cast block-number` with a one-shot retry. Use --rpc-url and capture stdout.
RPC_BLOCK() { cast block-number --rpc-url "$RPC_URL" 2>/dev/null; }
LATEST="$(RPC_BLOCK || true)"
if [[ -z "$LATEST" || "$LATEST" == "0" ]]; then
  sleep 2
  LATEST="$(RPC_BLOCK || true)"
fi
if [[ -z "$LATEST" || ! "$LATEST" =~ ^[0-9]+$ ]]; then
  echo "RPC unreachable: $RPC_URL" >&2
  exit 66
fi

WINDOW="${LCP_WINDOW_BLOCKS:-5000}"
if (( LATEST < WINDOW )); then
  FROM=0
else
  FROM=$((LATEST - WINDOW))
fi

# --- Validate target ----------------------------------------------------------
is_native=0
if [[ "$TARGET" == native:* ]]; then
  is_native=1
elif [[ ! "$TARGET" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Invalid address: $TARGET" >&2
  exit 64
fi

# --- Helper: cast call with output sanitized for arithmetic. ------------------
# Foundry's `cast` returns uint256 values in a human-friendly form like
# `1000000000000000000000000 [1e24]`. We strip the bracketed suffix and any
# whitespace, leaving a clean decimal string suitable for `awk` arithmetic.
CAST_CALL() {
  # CAST_CALL <addr> <sig>
  cast call --rpc-url "$RPC_URL" "$1" "$2" 2>/dev/null \
    | sed -E 's/[[:space:]]+\[[^]]+\]$//' \
    | tr -d ' '
}
CAST_CALL_BLOCK() {
  # CAST_CALL_BLOCK <addr> <sig> <block>
  cast call --rpc-url "$RPC_URL" --block "$3" "$1" "$2" 2>/dev/null \
    | sed -E 's/[[:space:]]+\[[^]]+\]$//' \
    | tr -d ' '
}

# --- Collect signals (with safe defaults) -------------------------------------
reserve_depth=""
outflow_velocity=""
holder_concentration=""
pool_imbalance=""
gas_stress=""
liquidity_age=""
supply_growth=""
missing=()

TRANSFER_TOPIC=0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef

if [[ $is_native -eq 0 ]]; then
  # ERC-20 path
  SUPPLY="$(CAST_CALL "$TARGET" 'totalSupply()(uint256)' || true)"
  if [[ -z "$SUPPLY" || "$SUPPLY" == "0x" ]]; then
    missing+=("totalSupply")
    SUPPLY="0"
  fi

  TRANSFERS=$(cast logs --rpc-url "$RPC_URL" \
    --from-block "$FROM" --to-block "$LATEST" \
    --address   "$TARGET" \
    "$TRANSFER_TOPIC" \
    --json 2>/dev/null || echo "[]")

  if [[ -n "$SUPPLY" && "$SUPPLY" != "0" ]]; then
    # Sum the `data` field of each Transfer log. `jq` 1.6+ supports
    # `fromhex` but Debian-stable `jq` does not; we use `cast --to-dec`
    # which is part of the Foundry runtime and always available.
    VOL=0
    while IFS= read -r hex; do
      [[ -z "$hex" || "$hex" == "null" ]] && continue
      dec=$(cast --to-dec "$hex" 2>/dev/null || echo 0)
      VOL=$(awk -v a="$VOL" -v b="$dec" 'BEGIN{ printf "%.0f", a + b }')
    done < <(printf '%s' "$TRANSFERS" | jq -r '.[].data // empty' 2>/dev/null)
    # Use awk for floating-point — pure bash can't do it portably.
    outflow_velocity=$(awk -v v="$VOL" -v s="$SUPPLY" 'BEGIN{
      if (s == 0) { print "0"; exit }
      printf "%.18f", v / s
    }')
  else
    missing+=("outflow_velocity")
  fi

  SUPPLY_PAST="$(CAST_CALL_BLOCK "$TARGET" 'totalSupply()(uint256)' "$FROM" || true)"
  if [[ -n "$SUPPLY_PAST" && "$SUPPLY_PAST" != "0" && -n "$SUPPLY" && "$SUPPLY" != "0" ]]; then
    supply_growth=$(awk -v n="$SUPPLY" -v p="$SUPPLY_PAST" 'BEGIN{
      if (p == 0) { print "0"; exit }
      printf "%.18f", (n - p) / p
    }')
  else
    missing+=("supply_growth")
  fi
else
  # Native path: reserve_depth, pool_imbalance, liquidity_age are
  # structurally unavailable, and the ERC-20-only signals (outflow,
  # supply_growth, holder_concentration) are also missing.
  missing+=("reserve_depth" "pool_imbalance" "liquidity_age" \
            "outflow_velocity" "holder_concentration" "supply_growth")
fi

# Gas stress: ratio of current gas price to the median of the last 200 blocks.
# We deliberately avoid bc — awk is sufficient.
GAS_NOW=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo 0)
if [[ -n "$GAS_NOW" && "$GAS_NOW" != "0" ]]; then
  # Clamp start block to 0.
  GAS_START=$(( LATEST > 200 ? LATEST - 200 : 0 ))
  SAMPLES=$(for b in $(seq "$GAS_START" "$LATEST"); do
    cast block "$b" --field baseFeePerGas --rpc-url "$RPC_URL" 2>/dev/null
  done | sort -n)
  MEDIAN=$(printf '%s\n' "$SAMPLES" | awk '
    { a[NR]=$1 }
    END { if (NR==0) print 0; else print a[int((NR+1)/2)] }
  ')
  if [[ -n "$MEDIAN" && "$MEDIAN" != "0" ]]; then
    gas_stress=$(awk -v n="$GAS_NOW" -v m="$MEDIAN" 'BEGIN{ printf "%.4f", n / m }')
  else
    gas_stress="0"
  fi
else
  gas_stress="0"
fi

# --- Pull weights and thresholds from lcp-thresholds.json --------------------
w_reserve=$(jq -r '.weights.reserve_depth'        "$THRESHOLDS")
w_outflow=$(jq -r '.weights.outflow_velocity'     "$THRESHOLDS")
w_holder=$(jq  -r '.weights.holder_concentration' "$THRESHOLDS")
w_imbal=$(jq    -r '.weights.pool_imbalance'       "$THRESHOLDS")
w_gas=$(jq      -r '.weights.gas_stress'           "$THRESHOLDS")
w_age=$(jq      -r '.weights.liquidity_age'        "$THRESHOLDS")
w_growth=$(jq   -r '.weights.supply_growth'        "$THRESHOLDS")

# --- Normalize each present signal into [0,1] --------------------------------
# We use simple two-threshold linear mapping. Thresholds in
# lcp-thresholds.json follow the convention:
#   lower-is-risky:  { healthy_above, watch_above, critical_below }
#   higher-is-risky: { healthy_below, watch_below, critical_above }
# We default to higher-is-risky for everything except reserve_depth and
# liquidity_age. Per-signal direction is explicit in the calls below.
#
# The awk ternary is on a single line for portability across mawk/gawk.
norm() {
  # norm <raw> <healthy> <watch> <critical> <direction>
  # direction: 1 = higher-is-risky, -1 = lower-is-risky
  local raw="$1" healthy="$2" watch="$3" critical="$4" dir="$5"
  awk -v r="$raw" -v h="$healthy" -v w="$watch" -v c="$critical" -v d="$dir" 'BEGIN{
    if (r == "" || r == "0") { print "0"; exit }
    # When watch == critical, the threshold collapses; use the "watch"
    # boundary as a step: x <= watch -> 0, x > watch -> 1.
    if (w == c) { print (d == 1) ? ((r > w) ? 1 : 0) : ((r < w) ? 1 : 0); exit }
    n = (d == 1) ? ((r - w) / (c - w)) : ((w - r) / (w - c))
    if (n < 0) n = 0
    if (n > 1) n = 1
    printf "%.4f", n
  }'
}

# Read thresholds once.
read_t() { jq -r ".signals.$1.$2 // empty" "$THRESHOLDS"; }

# An empty `raw` value means the CLI did not collect that signal. Treat it
# as missing (not as 0) so the downweight policy actually triggers.
n_reserve=$( [[ -n "$reserve_depth"  ]] && norm "$reserve_depth"     "$(read_t reserve_depth healthy_above)" \
                                       "$(read_t reserve_depth watch_above)" \
                                       "$(read_t reserve_depth critical_below)" -1 || echo "")
n_outflow=$( [[ -n "$outflow_velocity" ]] && norm "$outflow_velocity"  "$(read_t outflow_velocity healthy_below)" \
                                       "$(read_t outflow_velocity watch_below)" \
                                       "$(read_t outflow_velocity critical_above)"  1 || echo "")
n_holder=$( [[ -n "$holder_concentration" ]] && norm "$holder_concentration" \
                                       "$(read_t holder_concentration healthy_below)" \
                                       "$(read_t holder_concentration watch_below)" \
                                       "$(read_t holder_concentration critical_above)"  1 || echo "")
n_imbal=$(  [[ -n "$pool_imbalance" ]] && norm "$pool_imbalance"    "$(read_t pool_imbalance healthy_below)" \
                                       "$(read_t pool_imbalance watch_below)" \
                                       "$(read_t pool_imbalance critical_above)"  1 || echo "")
n_gas=$(    norm "$gas_stress"        "$(read_t gas_stress healthy_below)" \
                                       "$(read_t gas_stress watch_below)" \
                                       "$(read_t gas_stress critical_above)"  1)
n_age=$(    [[ -n "$liquidity_age" ]] && norm "$liquidity_age"     "$(read_t liquidity_age healthy_above)" \
                                       "$(read_t liquidity_age watch_above)" \
                                       "$(read_t liquidity_age critical_below)" -1 || echo "")
n_growth=$( [[ -n "$supply_growth" ]] && norm "$supply_growth"     "$(read_t supply_growth healthy_below)" \
                                       "$(read_t supply_growth watch_below)" \
                                       "$(read_t supply_growth critical_above)"  1 || echo "")

# --- Drop missing, rescale weights, accumulate --------------------------------
present=()
weights=()
norms=()
contribs=()
ids=()

add_if_present() {
  local id="$1" n="$2" w="$3"
  if [[ -n "$n" && "$n" != "NaN" && "$n" != "nan" ]]; then
    present+=("$id")
    norms+=("$n")
    weights+=("$w")
    ids+=("$id")
  else
    missing+=("$id")
  fi
}

add_if_present reserve_depth       "$n_reserve" "$w_reserve"
add_if_present outflow_velocity    "$n_outflow" "$w_outflow"
add_if_present holder_concentration "$n_holder"  "$w_holder"
add_if_present pool_imbalance      "$n_imbal"   "$w_imbal"
add_if_present gas_stress          "$n_gas"     "$w_gas"
add_if_present liquidity_age       "$n_age"     "$w_age"
add_if_present supply_growth       "$n_growth"  "$w_growth"

# If every signal is missing (e.g. native path with no usable data), we
# return a PARTIAL result. The skill spec defines this as band=WATCH,
# p_crisis=0.5, drivers=[], missing filled.
if [[ ${#present[@]} -eq 0 ]]; then
  score_int=0
  band="WATCH"
  p_crisis="0.50"
  rec="reduce exposure"
  partial=1
else
  partial=0
  # Rescale weights to sum to 1.
  sum_w=$(printf "%s\n" "${weights[@]}" | awk '{s+=$1} END{printf "%.6f", s}')
  score="0"
  for i in "${!present[@]}"; do
    w=$(awk -v x="${weights[$i]}" -v s="$sum_w" 'BEGIN{printf "%.6f", x/s}')
    contrib=$(awk -v w="$w" -v n="${norms[$i]}" 'BEGIN{printf "%.6f", w*n}')
    contribs+=("$contrib")
    score=$(awk -v s="$score" -v c="$contrib" 'BEGIN{printf "%.6f", s+c}')
  done
  score_int=$(awk -v s="$score" 'BEGIN{printf "%d", s*100 + 0.5}')
fi

# --- Band + p_crisis ----------------------------------------------------------
healthy_max=$(jq -r '.bands.healthy_max' "$THRESHOLDS")
watch_max=$(  jq -r '.bands.watch_max'   "$THRESHOLDS")
crit_min=$(   jq -r '.bands.critical_min' "$THRESHOLDS")
k=$(jq -r    '.crisis_probability.k'  "$THRESHOLDS")
x0=$(jq -r   '.crisis_probability.x0' "$THRESHOLDS")

if [[ $partial -eq 0 ]]; then
  if   [[ $score_int -le $healthy_max ]]; then band="HEALTHY"
  elif [[ $score_int -le $watch_max ]];   then band="WATCH"
  else                                      band="CRITICAL"
  fi

  # p_crisis via logistic. awk's exp() handles small |x|; for the
  # score range [0..100] the exponent k*(s-x0) stays in [-7.2, +4.8].
  p_crisis=$(awk -v s="$score_int" -v k="$k" -v x0="$x0" \
    'BEGIN{ printf "%.2f", 1/(1+exp(-k*(s-x0))) }')

  case "$band" in
    HEALTHY)  rec="hold" ;;
    WATCH)    rec="reduce exposure" ;;
    CRITICAL) rec="do not enter" ;;
  esac
fi

DISCLAIMER=$(jq -r '.disclaimer' "$THRESHOLDS")

# Deduplicate the missing list (order preserved, first occurrence wins).
if [[ ${#missing[@]} -gt 0 ]]; then
  _seen=" "
  _new_missing=()
  for m in "${missing[@]}"; do
    case " $_seen " in *" $m "*) ;; *) _new_missing+=("$m"); _seen+="$m " ;; esac
  done
  missing=("${_new_missing[@]}")
fi

# --- Render -------------------------------------------------------------------
if [[ "$LCP_JSON" == "1" ]]; then
  if [[ $partial -eq 0 ]]; then
    drivers_json="["
    for i in "${!present[@]}"; do
      [[ $i -gt 0 ]] && drivers_json+=","
      drivers_json+=$(printf '{"signal":"%s","raw":"%s","norm":%s,"contrib":%s}' \
        "${present[$i]}" "${norms[$i]}" "${norms[$i]}" "${contribs[$i]:-0}")
    done
    drivers_json+="]"
  else
    drivers_json="[]"
  fi

  missing_json=$(printf '"%s",' "${missing[@]}")
  missing_json="[${missing_json%,}]"
  # If missing is empty, the join above leaves "[]" with a trailing comma.
  # Normalize: strip trailing comma inside the array.
  missing_json=$(printf '%s' "$missing_json" | sed 's/,]/]/g')

  cat <<JSON
{
  "schema": "lcp.result.v1",
  "network": "$NETWORK",
  "target": "$TARGET",
  "score": $score_int,
  "band": "$band",
  "p_crisis": $p_crisis,
  "drivers": $drivers_json,
  "missing": $missing_json,
  "recommendation": "$rec",
  "disclaimer": "$DISCLAIMER"
}
JSON
else
  cat <<EOF
LCP — Liquidity Crisis Predictor
Network:   $NETWORK
Target:    $TARGET
Score:     $score_int / 100
Band:      $band
P(crisis): $p_crisis
EOF

  if [[ $partial -eq 0 ]]; then
    # Sort drivers by contribution descending. Simple bubble sort — n <= 7.
    for i in "${!present[@]}"; do
      for j in "${!present[@]}"; do
        a="${contribs[$i]:-0}"; b="${contribs[$j]:-0}"
        awk -v a="$a" -v b="$b" 'BEGIN{exit !(a > b)}' && {
          tmp_id="${present[$i]}";   present[$i]="${present[$j]}";   present[$j]="$tmp_id"
          tmp_n="${norms[$i]}";      norms[$i]="${norms[$j]}";      norms[$j]="$tmp_n"
          tmp_c="${contribs[$i]:-0}"; contribs[$i]="${contribs[$j]:-0}"; contribs[$j]="$tmp_c"
        }
      done
    done

    echo "Top drivers:"
    n=0
    for i in "${!present[@]}"; do
      [[ $n -ge 3 ]] && break
      n=$((n+1))
      printf "  %d. %-22s norm=%s contrib=%s\n" \
        "$n" "${present[$i]}" "${norms[$i]}" "${contribs[$i]:-0}"
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf "\nMissing: %s\n" "$(IFS=, ; echo "${missing[*]}")"
  fi
  printf "\nRecommendation: %s\n\n" "$rec"
  printf "Disclaimer: %s\n" "$DISCLAIMER"
fi
