#!/usr/bin/env bash
# LCP — Liquidity Crisis Predictor
# Single-asset scorer. Read-only. No private key. No external oracle.
#
# Usage:
#   ./score.sh <TOKEN_OR_POOL_ADDRESS> [network]
#   ./score.sh native:PROS [network]
#
# Networks: mainnet (default), atlantic-testnet
# Output:   human-readable report on stdout, JSON on stdout if LCP_JSON=1

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
for bin in cast forge jq bc; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required binary: $bin" >&2
    exit 69
  }
done

# Reject any private key in the environment — LCP must not see one.
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  echo "Refusing to run: \$PRIVATE_KEY is set. LCP is read-only." >&2
  exit 77
fi

# Resolve paths relative to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NETWORKS="$SKILL_DIR/assets/networks.json"
THRESHOLDS="$SKILL_DIR/assets/lcp-thresholds.json"

# --- Network config -----------------------------------------------------------
RPC_URL=$(jq -r --arg n "$NETWORK" \
  '.networks[] | select(.name==$n) | .rpcUrl' "$NETWORKS")

if [[ -z "$RPC_URL" || "$RPC_URL" == "null" ]]; then
  echo "Unknown network: $NETWORK" >&2
  echo "Supported: $(jq -r '.networks[].name' "$NETWORKS" | paste -sd, -)" >&2
  exit 65
fi

LATEST=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null) || {
  echo "RPC unreachable: $RPC_URL" >&2
  exit 69
}
WINDOW=5000
FROM=$((LATEST - WINDOW))

# --- Validate target ----------------------------------------------------------
is_native=0
if [[ "$TARGET" == native:* ]]; then
  is_native=1
elif [[ ! "$TARGET" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Invalid address: $TARGET" >&2
  exit 64
fi

# --- Collect signals (with safe defaults) -------------------------------------
reserve_depth=""
outflow_velocity=""
holder_concentration=""
pool_imbalance=""
gas_stress=""
liquidity_age=""
supply_growth=""
missing=()

if [[ $is_native -eq 0 ]]; then
  # ERC-20 path
  SUPPLY=$(cast call "$TARGET" "totalSupply()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null) \
    || { missing+=("totalSupply"); SUPPLY=0; }

  TRANSFER_TOPIC=0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef

  TRANSFERS=$(cast logs --rpc-url "$RPC_URL" \
    --from-block "$FROM" --to-block "$LATEST" \
    --address   "$TARGET" \
    --topic0    "$TRANSFER_TOPIC" \
    --json 2>/dev/null || echo "[]")

  if [[ -n "$SUPPLY" && "$SUPPLY" != "0" ]]; then
    VOL=$(echo "$TRANSFERS" | jq '[.[].data | fromhex | select(.). ] | add // 0' 2>/dev/null || echo 0)
    outflow_velocity=$(echo "scale=6; $VOL / $SUPPLY" | bc -l)
  else
    missing+=("outflow_velocity")
  fi

  SUPPLY_PAST=$(cast call "$TARGET" "totalSupply()(uint256)" \
    --rpc-url "$RPC_URL" --block "$FROM" 2>/dev/null) || SUPPLY_PAST="$SUPPLY"
  if [[ -n "$SUPPLY_PAST" && "$SUPPLY_PAST" != "0" ]]; then
    supply_growth=$(echo "scale=6; ($SUPPLY - $SUPPLY_PAST) / $SUPPLY_PAST" | bc -l)
  else
    missing+=("supply_growth")
  fi
else
  missing+=("reserve_depth" "pool_imbalance" "liquidity_age")
fi

# Gas stress (cheap on testnet; usually 0 → contributes nothing).
GAS_NOW=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo 0)
if [[ "$GAS_NOW" != "0" && -n "$GAS_NOW" ]]; then
  SAMPLES=$(for b in $(seq $((LATEST-50)) "$LATEST"); do
    cast block "$b" --field baseFeePerGas --rpc-url "$RPC_URL" 2>/dev/null
  done | sort -n)
  MEDIAN=$(echo "$SAMPLES" | awk 'NR==int(NR/2)')
  if [[ -n "$MEDIAN" && "$MEDIAN" != "0" ]]; then
    gas_stress=$(echo "scale=4; $GAS_NOW / $MEDIAN" | bc -l)
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
# We use simple two-threshold linear mapping. The thresholds in
# lcp-thresholds.json are formatted as:
#   lower-is-risky: { healthy_above, watch_above, critical_below }
#   higher-is-risky:{ healthy_below, watch_below, critical_above }
# We default to higher-is-risky for everything except reserve_depth and
# liquidity_age. Override per-signal if you change the JSON shape.

norm() {
  # norm <raw> <healthy> <watch> <critical> <direction>
  # direction: 1 = higher-is-risky, -1 = lower-is-risky
  local raw="$1" healthy="$2" watch="$3" critical="$4" dir="$5"
  awk -v r="$raw" -v h="$healthy" -v w="$watch" -v c="$critical" -v d="$dir" 'BEGIN{
    if (r == "") { print "NaN"; exit }
    n = (d == 1)
        ? (r - w) / (c - w)
        : (w - r) / (w - c)
    if (n < 0) n = 0
    if (n > 1) n = 1
    printf "%.4f", n
  }'
}

# Read thresholds once
read_t() { jq -r ".signals.$1.$2 // empty" "$THRESHOLDS"; }

n_reserve=$(norm "$reserve_depth"     "$(read_t reserve_depth healthy_above)" \
                                       "$(read_t reserve_depth watch_above)" \
                                       "$(read_t reserve_depth critical_below)" -1)
n_outflow=$(norm "$outflow_velocity"  "$(read_t outflow_velocity healthy_below)" \
                                       "$(read_t outflow_velocity watch_below)" \
                                       "$(read_t outflow_velocity critical_above)"  1)
n_holder=$( norm "$holder_concentration" \
                                       "$(read_t holder_concentration healthy_below)" \
                                       "$(read_t holder_concentration watch_below)" \
                                       "$(read_t holder_concentration critical_above)"  1)
n_imbal=$(  norm "$pool_imbalance"    "$(read_t pool_imbalance healthy_below)" \
                                       "$(read_t pool_imbalance watch_below)" \
                                       "$(read_t pool_imbalance critical_above)"  1)
n_gas=$(    norm "$gas_stress"        "$(read_t gas_stress healthy_below)" \
                                       "$(read_t gas_stress watch_below)" \
                                       "$(read_t gas_stress critical_above)"  1)
n_age=$(    norm "$liquidity_age"     "$(read_t liquidity_age healthy_above)" \
                                       "$(read_t liquidity_age watch_above)" \
                                       "$(read_t liquidity_age critical_below)" -1)
n_growth=$( norm "$supply_growth"     "$(read_t supply_growth healthy_below)" \
                                       "$(read_t supply_growth watch_below)" \
                                       "$(read_t supply_growth critical_above)"  1)

# --- Drop missing, rescale weights, accumulate --------------------------------
# n_* may be "NaN" or empty if the raw was missing.
present=()
weights=()
norms=()
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

# Rescale weights to sum to 1
sum_w=$(printf "%s\n" "${weights[@]}" | awk '{s+=$1} END{printf "%.6f", s}')
score=0
for i in "${!present[@]}"; do
  w=$(awk -v x="${weights[$i]}" -v s="$sum_w" 'BEGIN{printf "%.6f", x/s}')
  contrib=$(awk -v w="$w" -v n="${norms[$i]}" 'BEGIN{printf "%.6f", w*n}')
  contribs+=("$contrib")
  score=$(awk -v s="$score" -v c="$contrib" 'BEGIN{printf "%.6f", s+c}')
done
score_int=$(awk -v s="$score" 'BEGIN{printf "%d", s*100 + 0.5}')

# --- Band + p_crisis ----------------------------------------------------------
healthy_max=$(jq -r '.bands.healthy_max' "$THRESHOLDS")
watch_max=$(  jq -r '.bands.watch_max'   "$THRESHOLDS")
crit_min=$(   jq -r '.bands.critical_min' "$THRESHOLDS")
k=$(jq -r    '.crisis_probability.k'  "$THRESHOLDS")
x0=$(jq -r   '.crisis_probability.x0' "$THRESHOLDS")

if   [[ $score_int -le $healthy_max ]]; then band="HEALTHY"
elif [[ $score_int -le $watch_max ]];   then band="WATCH"
else                                      band="CRITICAL"
fi

p_crisis=$(awk -v s="$score_int" -v k="$k" -v x0="$x0" \
  'BEGIN{ printf "%.2f", 1/(1+exp(-k*(s-x0))) }')

# Recommendation
case "$band" in
  HEALTHY)  rec="hold" ;;
  WATCH)    rec="reduce exposure" ;;
  CRITICAL) rec="do not enter" ;;
esac

DISCLAIMER=$(jq -r '.disclaimer' "$THRESHOLDS")

# --- Render -------------------------------------------------------------------
if [[ "$LCP_JSON" == "1" ]]; then
  drivers_json="["
  for i in "${!present[@]}"; do
    [[ $i -gt 0 ]] && drivers_json+=","
    drivers_json+=$(printf '{"signal":"%s","raw":"%s","norm":%s,"contrib":%s}' \
      "${present[$i]}" "${norms[$i]}" "${norms[$i]}" "${contribs[$i]:-0}")
  done
  drivers_json+="]"

  missing_json=$(printf '"%s",' "${missing[@]}")
  missing_json="[${missing_json%,}]"

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

Top drivers:
EOF
  # Top 3 by contribution (simple bubble sort — n is tiny).
  for i in "${!present[@]}"; do
    for j in "${!present[@]}"; do
      a="${contribs[$i]:-0}"; b="${contribs[$j]:-0}"
      awk -v a="$a" -v b="$b" 'BEGIN{exit !(a > b)}' && {
        tmp_id="${present[$i]}"; present[$i]="${present[$j]}"; present[$j]="$tmp_id"
        tmp_n="${norms[$i]}";   norms[$i]="${norms[$j]}";     norms[$j]="$tmp_n"
        tmp_c="${contribs[$i]:-0}"; contribs[$i]="${contribs[$j]:-0}"; contribs[$j]="$tmp_c"
      }
    done
  done
  n=0
  for i in "${!present[@]}"; do
    [[ $n -ge 3 ]] && break
    n=$((n+1))
    printf "  %d. %-22s norm=%s contrib=%s\n" "$n" "${present[$i]}" "${norms[$i]}" "${contribs[$i]:-0}"
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf "\nMissing: %s\n" "$(IFS=, ; echo "${missing[*]}")"
  fi
  printf "\nRecommendation: %s\n\n" "$rec"
  printf "Disclaimer: %s\n" "$DISCLAIMER"
fi
