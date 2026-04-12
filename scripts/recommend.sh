#!/bin/bash
# Ask Not Diamond for the cheapest model that could handle this session's task.
# Usage: bash recommend.sh <transcript_path>
# Outputs JSON: {"model": "...", "provider": "...", "messages_sent": N}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_CACHE="/tmp/ecoguilt-models.json"

API_KEY="${NOTDIAMOND_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  echo '{"error": "no_api_key"}'
  exit 0
fi

# Ensure model cache exists
if [ ! -f "$MODEL_CACHE" ]; then
  bash "$SCRIPT_DIR/sync-models.sh" --quiet 2>/dev/null
fi

TRANSCRIPT="${1:-}"

# --- Extract messages from transcript JSONL ---
# Stratified sampling: first 3 + 10 evenly spaced middle + last 5
extract_messages() {
  local path="$1"
  [ -f "$path" ] || return

  # Pull user/assistant messages, truncate content to 1000 chars
  ALL=$(jq -c '
    select(.type == "user" or .type == "assistant")
    | {
        role: .type,
        content: (
          if (.message.content | type) == "array" then
            [.message.content[] | select(.type == "text") | .text] | join(" ")
          else
            (.message.content // "")
          end
        )[:1000]
      }
    | select(.content | length >= 5)
  ' "$path" 2>/dev/null)

  [ -z "$ALL" ] && return

  N=$(echo "$ALL" | wc -l | tr -d ' ')
  HEAD=3; MID_SAMPLES=10; TAIL=5
  MAX_TOTAL=$((HEAD + MID_SAMPLES + TAIL))

  if [ "$N" -le "$MAX_TOTAL" ]; then
    echo "$ALL"
    return
  fi

  # First few
  FIRST=$(echo "$ALL" | head -n "$HEAD")
  # Last few
  LAST=$(echo "$ALL" | tail -n "$TAIL")
  # Middle: evenly spaced samples
  MIDDLE_START=$((HEAD + 1))
  MIDDLE_END=$((N - TAIL))
  MIDDLE_COUNT=$((MIDDLE_END - MIDDLE_START + 1))

  if [ "$MIDDLE_COUNT" -le "$MID_SAMPLES" ]; then
    MID=$(echo "$ALL" | sed -n "${MIDDLE_START},${MIDDLE_END}p")
  else
    MID=""
    for i in $(seq 0 $((MID_SAMPLES - 1))); do
      LINE=$((MIDDLE_START + i * MIDDLE_COUNT / MID_SAMPLES))
      MID="${MID}$(echo "$ALL" | sed -n "${LINE}p")"$'\n'
    done
    MID=$(echo "$MID" | sed '/^$/d')
  fi

  echo "$FIRST"
  echo "$MID"
  echo "$LAST"
}

# Build messages array
MESSAGES="[]"
if [ -n "$TRANSCRIPT" ]; then
  EXTRACTED=$(extract_messages "$TRANSCRIPT")
  if [ -n "$EXTRACTED" ]; then
    MESSAGES=$(echo "$EXTRACTED" | jq -s '.')
  fi
fi

# Fallback
MSG_COUNT=$(echo "$MESSAGES" | jq 'length')
if [ "$MSG_COUNT" = "0" ]; then
  MESSAGES='[{"role": "user", "content": "Help me with a software engineering task."}]'
  MSG_COUNT=1
fi

# --- Call Not Diamond API ---
# Build provider list from model cache (only available models)
LLM_PROVIDERS=$(jq '[.[] | select(.available == true) | {provider: .provider, model: .id}]' "$MODEL_CACHE" 2>/dev/null)
if [ -z "$LLM_PROVIDERS" ] || [ "$LLM_PROVIDERS" = "[]" ]; then
  echo '{"error": "no_models"}'
  exit 0
fi

BODY=$(jq -n \
  --argjson messages "$MESSAGES" \
  --argjson llm_providers "$LLM_PROVIDERS" \
  '{messages: $messages, llm_providers: $llm_providers, tradeoff: "cost"}')

RESPONSE=$(curl -s -X POST "https://api.notdiamond.ai/v2/modelRouter/modelSelect" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$BODY" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
  echo '{"error": "no_response"}'
  exit 0
fi

# Extract model and provider from response
MODEL=$(echo "$RESPONSE" | jq -r '.providers[0].model // .provider.model // .model // empty' 2>/dev/null)
PROVIDER=$(echo "$RESPONSE" | jq -r '.providers[0].provider // .provider.provider // .provider // empty' 2>/dev/null)

if [ -n "$MODEL" ]; then
  jq -n --arg model "$MODEL" --arg provider "$PROVIDER" --argjson messages_sent "$MSG_COUNT" \
    '{model: $model, provider: $provider, messages_sent: $messages_sent}'
else
  # Pass through the raw response as error context
  ERROR=$(echo "$RESPONSE" | jq -r '.detail // .error // .message // "unknown"' 2>/dev/null)
  jq -n --arg error "$ERROR" '{error: $error}'
fi
