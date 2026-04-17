#!/bin/bash
# flush.sh — fires on every Stop hook. Reads the current session's /tmp state,
# detects anomalies, and appends a record to ~/.ecoguilt/history.jsonl.
set -uo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

[ -z "$SESSION_ID" ] && exit 0

STATE_FILE="/tmp/ecoguilt-${SESSION_ID}.json"
[ -f "$STATE_FILE" ] || exit 0

STATE=$(cat "$STATE_FILE")

HISTORY_DIR="$HOME/.ecoguilt"
HISTORY_FILE="$HISTORY_DIR/history.jsonl"
ANOMALY_FILE="/tmp/ecoguilt-${SESSION_ID}-anomaly.txt"

mkdir -p "$HISTORY_DIR"

# --- Current cumulative totals ---
TOTAL_TOKENS=$(echo "$STATE" | jq -r '.total_tokens // 0')
INPUT_TOKENS=$(echo "$STATE" | jq -r '.input_tokens // 0')
OUTPUT_TOKENS=$(echo "$STATE" | jq -r '.output_tokens // 0')
TOTAL_KWH=$(echo "$STATE" | jq -r '.total_kwh // "0"')
CO2_G=$(echo "$STATE" | jq -r '.co2_g // "0"')
WATER_ML=$(echo "$STATE" | jq -r '.water_ml // 0')
MODEL=$(echo "$STATE" | jq -r '.model // "unknown"')
COST_USD=$(echo "$STATE" | jq -r '.cost_usd // "0"')
TOTAL_CACHE_READ=$(echo "$STATE" | jq -r '.total_cache_read // 0')
TOTAL_CACHE_WRITE=$(echo "$STATE" | jq -r '.total_cache_write // 0')

# --- Compute per-turn deltas from previous record ---
PREV_TOTAL_TOKENS=0
PREV_INPUT_TOKENS=0
PREV_OUTPUT_TOKENS=0
PREV_COST="0"
PREV_CACHE_READ=0
PREV_CACHE_WRITE=0
# Count existing records for this session — more reliable than turn_number from
# the hook input, which resets to 0 on context window continuation.
PREV_TURN=0

if [ -f "$HISTORY_FILE" ]; then
  PREV=$(grep "\"session_id\":\"${SESSION_ID}\"" "$HISTORY_FILE" 2>/dev/null | tail -1)
  if [ -n "$PREV" ]; then
    PREV_TOTAL_TOKENS=$(echo "$PREV" | jq -r '.total_tokens // 0')
    PREV_INPUT_TOKENS=$(echo "$PREV" | jq -r '.input_tokens // 0')
    PREV_OUTPUT_TOKENS=$(echo "$PREV" | jq -r '.output_tokens // 0')
    PREV_COST=$(echo "$PREV" | jq -r '.cost_usd // "0"')
    PREV_CACHE_READ=$(echo "$PREV" | jq -r '.total_cache_read // 0')
    PREV_CACHE_WRITE=$(echo "$PREV" | jq -r '.total_cache_write // 0')
  fi
  PREV_TURN=$(grep -c "\"session_id\":\"${SESSION_ID}\"" "$HISTORY_FILE" 2>/dev/null || true)
fi

TURN=$((PREV_TURN + 1))

TURN_TOKENS=$((TOTAL_TOKENS - PREV_TOTAL_TOKENS))
[ "$TURN_TOKENS" -lt 0 ] && TURN_TOKENS=$TOTAL_TOKENS

DELTA_IN=$((INPUT_TOKENS - PREV_INPUT_TOKENS))
DELTA_OUT=$((OUTPUT_TOKENS - PREV_OUTPUT_TOKENS))
[ "$DELTA_IN" -lt 0 ] && DELTA_IN=$INPUT_TOKENS
[ "$DELTA_OUT" -lt 0 ] && DELTA_OUT=$OUTPUT_TOKENS

TURN_COST=$(echo "scale=6; $COST_USD - $PREV_COST" | bc 2>/dev/null || echo "0")
TURN_COST=$(echo "$TURN_COST" | sed 's/^\./0./;s/^-\./0./')
if (( $(echo "$TURN_COST < 0" | bc 2>/dev/null || echo 0) )); then
  TURN_COST=$(echo "$COST_USD" | bc 2>/dev/null || echo "0")
fi

# Cache efficiency this turn
CACHE_TOTAL=$((TOTAL_CACHE_READ + TOTAL_CACHE_WRITE))
if (( CACHE_TOTAL > 0 )); then
  TURN_CACHE_EFF=$(echo "scale=4; $TOTAL_CACHE_READ / $CACHE_TOTAL" | bc)
else
  TURN_CACHE_EFF="0"
fi

PREV_CACHE_TOTAL=$((PREV_CACHE_READ + PREV_CACHE_WRITE))
if (( PREV_CACHE_TOTAL > 0 )); then
  PREV_CACHE_EFF=$(echo "scale=4; $PREV_CACHE_READ / $PREV_CACHE_TOTAL" | bc)
else
  PREV_CACHE_EFF="$TURN_CACHE_EFF"
fi

# --- Anomaly detection (requires ≥3 prior turns) ---
ANOMALY="null"
ANOMALY_TYPES=()

if (( PREV_TURN >= 3 )) && [ -f "$HISTORY_FILE" ]; then
  # Per-direction averages — use stored per-turn fields, not cumulative/count,
  # because the session may start with a large inherited token count from prior context.
  SESSION_AVG_IN=$(grep "\"session_id\":\"${SESSION_ID}\"" "$HISTORY_FILE" \
    | jq -r '.turn_input_tokens // 0' \
    | awk '{sum+=$1} END {if (NR>0) print int(sum/NR); else print 0}')
  SESSION_AVG_OUT=$(grep "\"session_id\":\"${SESSION_ID}\"" "$HISTORY_FILE" \
    | jq -r '.turn_output_tokens // 0' \
    | awk '{sum+=$1} END {if (NR>0) print int(sum/NR); else print 0}')

  # input_spike: user sent >3x avg input AND at least 500 tokens absolute.
  # Floor prevents false positives when session avg is low from many short messages.
  if (( SESSION_AVG_IN > 0 )) && (( DELTA_IN > SESSION_AVG_IN * 3 )) && (( DELTA_IN > 500 )); then
    ANOMALY_TYPES+=("input_spike")
  fi

  # output_spike: AI generated >3x avg output (very verbose response)
  if (( SESSION_AVG_OUT > 0 )) && (( DELTA_OUT > SESSION_AVG_OUT * 3 )); then
    ANOMALY_TYPES+=("output_spike")
  fi

  # Cache break: efficiency dropped >25 points
  EFF_DROP=$(echo "scale=2; ($PREV_CACHE_EFF - $TURN_CACHE_EFF) * 100" | bc 2>/dev/null || echo "0")
  if (( $(echo "$EFF_DROP > 25" | bc 2>/dev/null || echo 0) )); then
    ANOMALY_TYPES+=("cache_break")
  fi

  # Cost spike: turn cost >3x session average — use turn_cost_usd field for same reason
  SESSION_AVG_COST=$(grep "\"session_id\":\"${SESSION_ID}\"" "$HISTORY_FILE" \
    | jq -r '.turn_cost_usd // 0' \
    | awk '{sum+=$1} END {if (NR>0) printf "%.6f", sum/NR; else print "0"}')
  if (( $(echo "$SESSION_AVG_COST > 0" | bc 2>/dev/null || echo 0) )); then
    if (( $(echo "$TURN_COST > $SESSION_AVG_COST * 3" | bc 2>/dev/null || echo 0) )); then
      ANOMALY_TYPES+=("cost_spike")
    fi
  fi
fi

# Extract last user message from transcript for anomaly context
ANOMALY_MSG=""
if [ ${#ANOMALY_TYPES[@]} -gt 0 ] && [ -f "$TRANSCRIPT" ]; then
  # Find last user message that contains actual text (not just tool_results)
  ANOMALY_MSG=$(jq -r '
    select(.type == "user") |
    .message.content |
    if type == "array" then
      [.[] | select(.type == "text") | .text] | join(" ")
    else . end |
    select(length > 0)
  ' "$TRANSCRIPT" 2>/dev/null | tail -1 | cut -c1-100)
fi

# Build anomaly JSON
if [ ${#ANOMALY_TYPES[@]} -gt 0 ]; then
  TYPES_JSON=$(printf '%s\n' "${ANOMALY_TYPES[@]}" | jq -R . | jq -sc .)
  ANOMALY=$(jq -n \
    --argjson types "$TYPES_JSON" \
    --argjson turn_tokens "$TURN_TOKENS" \
    --argjson turn_input_tokens "$DELTA_IN" \
    --argjson turn_output_tokens "$DELTA_OUT" \
    --arg turn_cache_eff "$TURN_CACHE_EFF" \
    --arg prev_cache_eff "$PREV_CACHE_EFF" \
    --arg message "$ANOMALY_MSG" \
    --arg turn_cost "$TURN_COST" \
    '{types: $types, turn_tokens: $turn_tokens, turn_input_tokens: $turn_input_tokens, turn_output_tokens: $turn_output_tokens, turn_cost_usd: ($turn_cost | tonumber), turn_cache_efficiency: ($turn_cache_eff | tonumber), prev_cache_efficiency: ($prev_cache_eff | tonumber), message: $message}')

  # Write anomaly notification for status line
  echo "${ANOMALY_TYPES[*]}" | tr ' ' '/' > "$ANOMALY_FILE"
else
  # Clear any previous anomaly notification
  rm -f "$ANOMALY_FILE"
fi

# --- Append record to history ---
DATE=$(date -u +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -nc \
  --arg session_id "$SESSION_ID" \
  --argjson turn "$TURN" \
  --arg date "$DATE" \
  --arg cwd "$CWD" \
  --arg last_updated "$TIMESTAMP" \
  --arg model "$MODEL" \
  --arg cost_usd "$COST_USD" \
  --argjson total_tokens "$TOTAL_TOKENS" \
  --argjson input_tokens "$INPUT_TOKENS" \
  --argjson output_tokens "$OUTPUT_TOKENS" \
  --arg total_kwh "$TOTAL_KWH" \
  --arg co2_g "$CO2_G" \
  --argjson water_ml "$WATER_ML" \
  --argjson total_cache_read "$TOTAL_CACHE_READ" \
  --argjson total_cache_write "$TOTAL_CACHE_WRITE" \
  --argjson turn_tokens "$TURN_TOKENS" \
  --argjson turn_input_tokens "$DELTA_IN" \
  --argjson turn_output_tokens "$DELTA_OUT" \
  --arg turn_cost "$TURN_COST" \
  --arg turn_cache_eff "$TURN_CACHE_EFF" \
  --argjson anomaly "$ANOMALY" \
  '{
    session_id: $session_id,
    turn: $turn,
    date: $date,
    cwd: $cwd,
    last_updated: $last_updated,
    model: $model,
    cost_usd: ($cost_usd | tonumber),
    total_tokens: $total_tokens,
    input_tokens: $input_tokens,
    output_tokens: $output_tokens,
    total_kwh: ($total_kwh | tonumber),
    co2_g: ($co2_g | tonumber),
    water_ml: $water_ml,
    total_cache_read: $total_cache_read,
    total_cache_write: $total_cache_write,
    turn_tokens: $turn_tokens,
    turn_input_tokens: $turn_input_tokens,
    turn_output_tokens: $turn_output_tokens,
    turn_cost_usd: ($turn_cost | tonumber),
    turn_cache_efficiency: ($turn_cache_eff | tonumber),
    anomaly: $anomaly
  }' >> "$HISTORY_FILE"
