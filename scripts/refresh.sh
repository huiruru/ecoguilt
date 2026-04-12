#!/bin/bash
# ecoguilt PostToolUse hook — refresh Haiku fact + Not Diamond recommendation.
# Reads session state (written by statusline.sh), kicks off background jobs when needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

[ -z "$SESSION_ID" ] && exit 0

STATE_FILE="/tmp/ecoguilt-${SESSION_ID}.json"
FACT_FILE="/tmp/ecoguilt-${SESSION_ID}-fact.txt"
FACT_TOKENS_FILE="/tmp/ecoguilt-${SESSION_ID}-fact-tokens.txt"
RECOMMEND_FILE="/tmp/ecoguilt-${SESSION_ID}-recommend.json"

# Wait for status line to write state (it runs on the same cycle)
[ ! -f "$STATE_FILE" ] && exit 0

# Read current metrics from state
TOTAL_TOKENS=$(jq -r '.total_tokens // 0' "$STATE_FILE" 2>/dev/null)
TOTAL_KWH=$(jq -r '.total_kwh // "0"' "$STATE_FILE" 2>/dev/null)
CO2_G=$(jq -r '.co2_g // "0"' "$STATE_FILE" 2>/dev/null)
WATER_ML=$(jq -r '.water_ml // 0' "$STATE_FILE" 2>/dev/null)

(( TOTAL_TOKENS < 100 )) && exit 0

# --- Haiku fact regeneration ---
REGEN_FACT=false
if [ ! -f "$FACT_FILE" ] || [ ! -f "$FACT_TOKENS_FILE" ]; then
  REGEN_FACT=true
else
  LAST_TOKENS=$(cat "$FACT_TOKENS_FILE" 2>/dev/null || echo "0")
  if (( TOTAL_TOKENS > LAST_TOKENS * 3 / 2 )); then
    REGEN_FACT=true
  fi
fi

if $REGEN_FACT; then
  # Pre-calculate conversions so Haiku doesn't do math
  MILES=$(printf "%.1f" "$(echo "scale=1; $CO2_G / 400" | bc)")
  BOTTLES=$(printf "%.1f" "$(echo "scale=1; $WATER_ML / 500" | bc)")
  LITERS=$(printf "%.1f" "$(echo "scale=1; $WATER_ML / 1000" | bc)")
  PHONES=$(printf "%.0f" "$(echo "scale=1; $TOTAL_KWH / 0.012" | bc)")
  BULB_HRS=$(printf "%.1f" "$(echo "scale=1; $TOTAL_KWH / 0.06" | bc)")

  METRICS="This coding session has used:
- ${CO2_G}g of CO2 (${MILES} miles driven in a car)
- ${WATER_ML}ml of water (${BOTTLES} bottles, or ${LITERS} liters)
- ${TOTAL_KWH} kWh of energy (${PHONES} phone charges, or ${BULB_HRS} hours of a lightbulb)

Pick the most impactful comparison and write ONE sentence using the pre-calculated numbers above. Do NOT do any math yourself — use the numbers exactly as given."
  FACT_PROMPT=$(cat "$SCRIPT_DIR/fact-prompt.txt")

  (
    TMPFILE=$(mktemp)
    if claude -p --model haiku --system-prompt "$FACT_PROMPT" "$METRICS" > "$TMPFILE" 2>/dev/null && [ -s "$TMPFILE" ]; then
      mv "$TMPFILE" "$FACT_FILE"
      echo "$TOTAL_TOKENS" > "$FACT_TOKENS_FILE"
    else
      rm -f "$TMPFILE"
    fi
  ) &
fi

# --- Not Diamond recommendation refresh ---
REFRESH=false
if [ ! -f "$RECOMMEND_FILE" ]; then
  REFRESH=true
elif [ "$(find "$RECOMMEND_FILE" -mmin +5 2>/dev/null)" ]; then
  REFRESH=true
fi

if $REFRESH; then
  # Use transcript_path from hook input (provided by Claude Code)
  TRANSCRIPT="$TRANSCRIPT_PATH"
  if [ -z "$TRANSCRIPT" ] && [ -n "$CWD" ]; then
    # Fallback: derive from session_id + project dir
    PROJECT_DIR=$(echo "$CWD" | sed 's|^/|-|; s|/|-|g')
    TRANSCRIPT=$(ls -t ~/.claude/projects/"${PROJECT_DIR}"/"${SESSION_ID}".jsonl 2>/dev/null | head -1)
    [ -z "$TRANSCRIPT" ] && TRANSCRIPT=$(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
  fi
  if [ -n "$TRANSCRIPT" ]; then
    (bash "$SCRIPT_DIR/recommend.sh" "$TRANSCRIPT" > "$RECOMMEND_FILE" 2>/dev/null) &
  fi
fi

exit 0
