#!/bin/bash
# ecoguilt status line — calculate impact, write state, render one line.
# Background jobs (Haiku facts, Not Diamond) are handled by the PostToolUse hook.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_CACHE="/tmp/ecoguilt-models.json"
INPUT=$(cat)

# Extract cumulative session token counts and current model
INPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')
CURRENT_MODEL=$(echo "$INPUT" | jq -r '.model.id // "unknown"')
SESSION_COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // empty')
INPUT_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
INPUT_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

TOTAL_TOKENS=$((INPUT_TOKENS + OUTPUT_TOKENS))

if (( TOTAL_TOKENS < 100 )); then
  echo ""
  exit 0
fi

# --- Ensure model cache exists ---
if [ ! -f "$MODEL_CACHE" ]; then
  bash "$SCRIPT_DIR/sync-models.sh" --quiet 2>/dev/null
fi

# --- Look up current model from cache ---
lookup_model() {
  jq -r --arg id "$1" '.[] | select(.id == $id)' "$MODEL_CACHE" 2>/dev/null
}

CUR_MODEL_DATA=$(lookup_model "$CURRENT_MODEL")
if [ -z "$CUR_MODEL_DATA" ]; then
  CUR_MODEL_DATA=$(jq -r --arg id "$CURRENT_MODEL" '[.[] | select(.id | startswith($id[0:15]))] | first // empty' "$MODEL_CACHE" 2>/dev/null)
fi

CUR_IN_KWH=$(echo "$CUR_MODEL_DATA" | jq -r '.input_kwh_per_token // "0.0000012"')
CUR_OUT_KWH=$(echo "$CUR_MODEL_DATA" | jq -r '.output_kwh_per_token // "0.0000048"')
CUR_IN_PRICE=$(echo "$CUR_MODEL_DATA" | jq -r '.input_price // 15')
CUR_OUT_PRICE=$(echo "$CUR_MODEL_DATA" | jq -r '.output_price // 75')

clean() { echo "$1" | sed 's/\.0$//'; }

# --- Session state ---
SESSION_ID="${INPUT_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
STATE_FILE="/tmp/ecoguilt-${SESSION_ID}.json"
RECOMMEND_FILE="/tmp/ecoguilt-${SESSION_ID}-recommend.json"
FACT_FILE="/tmp/ecoguilt-${SESSION_ID}-fact.txt"

# --- Incremental energy tracking ---
# Energy must accumulate across model switches. If you used 600k tokens on opus
# then switched to haiku, we can't recalculate all tokens at haiku's rate.
# Instead: compute delta tokens since last render, apply current model's rate.
PREV_INPUT=0
PREV_OUTPUT=0
PREV_KWH="0"
if [ -f "$STATE_FILE" ]; then
  PREV_INPUT=$(jq -r '.input_tokens // 0' "$STATE_FILE" 2>/dev/null)
  PREV_OUTPUT=$(jq -r '.output_tokens // 0' "$STATE_FILE" 2>/dev/null)
  PREV_KWH=$(jq -r '.total_kwh // "0"' "$STATE_FILE" 2>/dev/null)
  [ -z "$PREV_KWH" ] && PREV_KWH="0"
fi

DELTA_IN=$((INPUT_TOKENS - PREV_INPUT))
DELTA_OUT=$((OUTPUT_TOKENS - PREV_OUTPUT))
# Guard against negative deltas (e.g. session restart)
if (( DELTA_IN < 0 )); then DELTA_IN=$INPUT_TOKENS; PREV_KWH="0"; fi
if (( DELTA_OUT < 0 )); then DELTA_OUT=$OUTPUT_TOKENS; PREV_KWH="0"; fi

DELTA_KWH=$(echo "scale=10; $DELTA_IN * $CUR_IN_KWH + $DELTA_OUT * $CUR_OUT_KWH" | bc)
TOTAL_KWH=$(echo "scale=10; $PREV_KWH + $DELTA_KWH" | bc)

CO2_G=$(printf "%.1f" "$(echo "scale=4; $TOTAL_KWH * 0.39 * 1000" | bc)")
WATER_ML=$(printf "%.0f" "$(echo "scale=2; $TOTAL_KWH * 1800" | bc)")
CO2_G=$(clean "$CO2_G")

CUR_COST=$(printf "%.2f" "$(echo "scale=4; $INPUT_TOKENS * $CUR_IN_PRICE / 1000000 + $OUTPUT_TOKENS * $CUR_OUT_PRICE / 1000000" | bc)")
if [ -n "$SESSION_COST" ]; then CUR_COST=$(printf "%.2f" "$SESSION_COST"); fi

# Write state — single source of truth for /impact and the hook
jq -n \
  --argjson input_tokens "$INPUT_TOKENS" \
  --argjson output_tokens "$OUTPUT_TOKENS" \
  --argjson total_tokens "$TOTAL_TOKENS" \
  --arg total_kwh "$TOTAL_KWH" \
  --arg co2_g "$CO2_G" \
  --argjson water_ml "$WATER_ML" \
  --arg model "$CURRENT_MODEL" \
  --arg cost_usd "$CUR_COST" \
  --arg input_kwh_per_token "$CUR_IN_KWH" \
  --arg output_kwh_per_token "$CUR_OUT_KWH" \
  '{input_tokens: $input_tokens, output_tokens: $output_tokens, total_tokens: $total_tokens, total_kwh: $total_kwh, co2_g: $co2_g, water_ml: $water_ml, model: $model, cost_usd: $cost_usd, input_kwh_per_token: $input_kwh_per_token, output_kwh_per_token: $output_kwh_per_token}' \
  > "$STATE_FILE" 2>/dev/null || true

# Write a per-cwd pointer so /impact finds the right session
if [ -n "$INPUT_CWD" ]; then
  CWD_HASH=$(echo -n "$INPUT_CWD" | md5 2>/dev/null || echo -n "$INPUT_CWD" | md5sum 2>/dev/null | cut -d' ' -f1)
  echo "$SESSION_ID" > "/tmp/ecoguilt-cwd-${CWD_HASH}.txt" 2>/dev/null || true
fi

# --- Clean up stale state files (older than 7 days) ---
find /tmp -name "ecoguilt-*" -mtime +7 -delete 2>/dev/null || true

# --- Read cached recommendation + calculate savings ---
RECOMMEND=""
SAVINGS=""
if [ -f "$RECOMMEND_FILE" ] && [ -f "$MODEL_CACHE" ]; then
  REC_MODEL=$(jq -r '.model // empty' "$RECOMMEND_FILE" 2>/dev/null)
  if [ -n "$REC_MODEL" ] && [ "$REC_MODEL" != "$CURRENT_MODEL" ]; then
    REC_DATA=$(lookup_model "$REC_MODEL")
    if [ -n "$REC_DATA" ]; then
      RECOMMEND=$(echo "$REC_DATA" | jq -r '.display')
      REC_IN_PRICE=$(echo "$REC_DATA" | jq -r '.input_price')
      REC_OUT_PRICE=$(echo "$REC_DATA" | jq -r '.output_price')
      REC_IN_KWH=$(echo "$REC_DATA" | jq -r '.input_kwh_per_token')
      REC_OUT_KWH=$(echo "$REC_DATA" | jq -r '.output_kwh_per_token')

      # Scale actual session cost by pricing ratio — more accurate than token-based estimate
      # because context caching means token counts don't reflect true cost
      CUR_AVG_PRICE=$(echo "scale=6; ($CUR_IN_PRICE + $CUR_OUT_PRICE) / 2" | bc)
      REC_AVG_PRICE=$(echo "scale=6; ($REC_IN_PRICE + $REC_OUT_PRICE) / 2" | bc)
      REC_COST=$(printf "%.2f" "$(echo "scale=4; $CUR_COST * $REC_AVG_PRICE / $CUR_AVG_PRICE" | bc)")

      if [ "$(echo "$REC_COST < $CUR_COST" | bc)" = "1" ]; then
        # Cheaper — show savings
        SAVED_COST=$(printf "%.2f" "$(echo "scale=4; $CUR_COST - $REC_COST" | bc)")
        SAVED_COST=$(echo "$SAVED_COST" | sed 's/^\./0./')

        REC_TOTAL_KWH=$(echo "scale=10; $TOTAL_KWH * $REC_AVG_PRICE / $CUR_AVG_PRICE" | bc)
        REC_WATER=$(printf "%.0f" "$(echo "scale=2; $REC_TOTAL_KWH * 1800" | bc)")
        SAVED_WATER=$((WATER_ML - REC_WATER))

        SAVINGS="not diamond: ${RECOMMEND} would save \$${SAVED_COST}"
        if [ "$SAVED_WATER" -ge 500 ]; then
          SAVED_BOTTLES=$(clean "$(echo "scale=1; $SAVED_WATER / 500" | bc)")
          SAVINGS="${SAVINGS} and ${SAVED_BOTTLES} bottles of water"
        elif [ "$SAVED_WATER" -gt 0 ]; then
          SAVINGS="${SAVINGS} and ${SAVED_WATER}ml of water"
        fi
      else
        # More expensive — not diamond thinks accuracy requires it, flag as tradeoff
        EXTRA_COST=$(printf "%.2f" "$(echo "scale=4; $REC_COST - $CUR_COST" | bc)")
        EXTRA_COST=$(echo "$EXTRA_COST" | sed 's/^\./0./')
        SAVINGS="not diamond: ${RECOMMEND} would be more accurate (+\$${EXTRA_COST})"
      fi
    fi
  fi
fi

# --- Read cached fact ---
FACT=""
if [ -f "$FACT_FILE" ]; then
  FACT=$(cat "$FACT_FILE" 2>/dev/null)
fi
if [ -z "$FACT" ]; then
  BOTTLES=$(clean "$(echo "scale=1; $WATER_ML / 500" | bc)")
  PHONES=$(printf "%.0f" "$(echo "scale=0; $TOTAL_KWH / 0.012" | bc)")
  FACT="this session used enough energy to charge ${PHONES} phones and ${BOTTLES} bottles of water cooling a datacenter."
fi

# --- Output ---
if [ -n "$SAVINGS" ]; then
  echo "\$${CUR_COST} spent. ${FACT} (${SAVINGS})"
elif [ -n "$RECOMMEND" ]; then
  echo "\$${CUR_COST} spent. ${FACT} (not diamond: use ${RECOMMEND})"
else
  echo "\$${CUR_COST} spent. ${FACT}"
fi
