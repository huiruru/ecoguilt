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
FACT_AGE_MINUTES=3
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
# Regenerate when: no cache, tokens grew 1.15x, OR fact is older than FACT_AGE_MINUTES.
# Wall-clock trigger ensures variation during long sessions with slow token growth.
REGEN_FACT=false
if [ ! -f "$FACT_FILE" ] || [ ! -f "$FACT_TOKENS_FILE" ]; then
  REGEN_FACT=true
elif [ "$(find "$FACT_FILE" -mmin +${FACT_AGE_MINUTES} 2>/dev/null)" ]; then
  REGEN_FACT=true
else
  LAST_TOKENS=$(cat "$FACT_TOKENS_FILE" 2>/dev/null || echo "0")
  if (( TOTAL_TOKENS * 100 > LAST_TOKENS * 115 )); then
    REGEN_FACT=true
  fi
fi

if $REGEN_FACT; then
  # Pre-calculate conversions so Haiku doesn't do math.
  # scale=2 on MILES so tiny sessions don't round to 0.0 and kill the CO2 axis.
  MILES=$(printf "%.2f" "$(echo "scale=2; $CO2_G / 400" | bc)")
  BOTTLES=$(printf "%.1f" "$(echo "scale=1; $WATER_ML / 500" | bc)")
  LITERS=$(printf "%.1f" "$(echo "scale=1; $WATER_ML / 1000" | bc)")
  PHONES=$(printf "%.0f" "$(echo "scale=1; $TOTAL_KWH / 0.012" | bc)")
  BULB_HRS=$(printf "%.1f" "$(echo "scale=1; $TOTAL_KWH / 0.06" | bc)")
  FRIDGE_HRS=$(printf "%.1f" "$(echo "scale=1; $TOTAL_KWH / 0.15" | bc)")

  # Force axis AND scenario rotation in shell — LLMs can't randomize reliably.
  # Drop CO2 when miles still rounds to 0.00 (session too small).
  if [ "$MILES" = "0.00" ]; then
    AXIS=$(( (RANDOM % 2) + 1 ))  # water or energy only
  else
    AXIS=$(( RANDOM % 3 ))
  fi

  CO2_SCENES=(
    "a delivery van idling at a red light while the driver scrolls"
    "a pickup truck rolling coal down an empty interstate at 3am"
    "the exhaust plume from one rideshare doing a u-turn"
    "a lawnmower chewing through a front yard no one sits in"
    "a leaf blower moving the same leaves twice"
    "a cruise ship turning its engines over in port"
    "a snowmobile crossing a frozen lake with no one watching"
    "the commute someone drove after a meeting that should have been an email"
    "a moped circling a parking lot looking for a shortcut"
  )
  WATER_SCENES=(
    "water pulled from an aquifer to cool a server rack humming in the nevada desert"
    "a faucet left running in an empty rental"
    "the rinse cycle of a dishwasher run with four forks in it"
    "a lawn sprinkler hitting concrete"
    "an ice machine making ice no one asked for"
    "a cooling tower exhaling steam into a parking lot at noon"
    "a bottled water pallet forgotten in a warehouse"
    "the shower someone forgot to turn off before leaving for work"
    "a fountain in a corporate lobby that closed in 2019"
  )
  ENERGY_SCENES=(
    "a neon 'open' sign burning in a storefront that closed at nine"
    "a laptop left open on a hotel bed, screen on, owner asleep"
    "a vending machine glowing in an office no one works in"
    "a porch light left on for a guest who never came"
    "a freezer full of expired meat in a garage"
    "the hvac in a conference room running for a meeting that got cancelled"
    "a television playing the weather to an empty waiting room"
    "a server rack blinking in a datacenter somewhere in virginia"
    "a hair dryer left running on the bathroom counter"
  )

  case $AXIS in
    0)
      SCENE="${CO2_SCENES[$(( RANDOM % ${#CO2_SCENES[@]} ))]}"
      [ -z "$SCENE" ] && SCENE="${CO2_SCENES[0]}"
      METRICS="Number: ${MILES} miles of driving (equivalent to ${CO2_G}g of CO2 released).
Scene: ${SCENE}.
Write ONE sentence starting with \"this session\" that fuses the number into the scene. Use the miles figure exactly as given. Do not mention grams of CO2 — the miles number IS the fact."
      ;;
    1)
      SCENE="${WATER_SCENES[$(( RANDOM % ${#WATER_SCENES[@]} ))]}"
      [ -z "$SCENE" ] && SCENE="${WATER_SCENES[0]}"
      METRICS="Number: ${BOTTLES} bottles (or ${LITERS} liters, or ${WATER_ML}ml) of water.
Scene: ${SCENE}.
Write ONE sentence starting with \"this session\" that fuses the number into the scene. Pick whichever water unit (bottles, liters, ml) reads most naturally for the scene. Use one unit only."
      ;;
    2)
      SCENE="${ENERGY_SCENES[$(( RANDOM % ${#ENERGY_SCENES[@]} ))]}"
      [ -z "$SCENE" ] && SCENE="${ENERGY_SCENES[0]}"
      METRICS="Number: ${BULB_HRS} hours of a lightbulb (or ${FRIDGE_HRS} hours of a fridge, or ${PHONES} phone charges).
Scene: ${SCENE}.
Write ONE sentence starting with \"this session\" that fuses the number into the scene. Pick whichever energy unit (hours of X, or phone charges) reads most naturally. Use one unit only — do not stitch multiple conversions together."
      ;;
  esac
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
