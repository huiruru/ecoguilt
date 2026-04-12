#!/bin/bash
# Fetch pricing from Not Diamond and build the enriched model cache.
# Usage: bash sync-models.sh [--quiet]
# Writes to /tmp/ecoguilt-models.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_FILE="$PLUGIN_DIR/models.json"
CACHE_FILE="/tmp/ecoguilt-models.json"
QUIET="${1:-}"

if [ ! -f "$MODELS_FILE" ]; then
  [ "$QUIET" != "--quiet" ] && echo "error: models.json not found at $MODELS_FILE" >&2
  exit 1
fi

API_KEY="${NOTDIAMOND_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  [ "$QUIET" != "--quiet" ] && echo "warning: NOTDIAMOND_API_KEY not set, using models.json without pricing" >&2
  # Write a basic cache with no pricing
  jq '[.[] | . + {input_price: null, output_price: null, energy_per_token: null, display: (.id | gsub("^claude-"; "") | gsub("-20[0-9]+$"; "") | gsub("Meta-Llama-3.1-405B-Instruct-Turbo"; "llama-405b") | gsub("DeepSeek-R1"; "deepseek-r1"))}]' "$MODELS_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
  exit 0
fi

# Fetch all models from Not Diamond
ND_MODELS=$(curl -s -X GET "https://api.notdiamond.ai/v2/models" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" 2>/dev/null)

if [ -z "$ND_MODELS" ] || ! echo "$ND_MODELS" | jq -e '.models' >/dev/null 2>&1; then
  [ "$QUIET" != "--quiet" ] && echo "error: failed to fetch models from Not Diamond API" >&2
  exit 1
fi

# Energy model: estimate kWh per token based on pricing.
# Reference: claude-opus-4-20250514 at $15/$75 = ~0.0000012 kWh/input, ~0.0000048 kWh/output
# We scale linearly: a model at $3/$15 uses roughly 1/5 the compute.
# Reference average price (input+output)/2 for scaling:
REF_AVG_PRICE=45.0  # (15+75)/2 for opus-4-0
REF_INPUT_KWH="0.0000012"
REF_OUTPUT_KWH="0.0000048"

# Enrich each model from models.json with Not Diamond data
RESULT=$(jq -n \
  --argjson user_models "$(cat "$MODELS_FILE")" \
  --argjson nd_models "$(echo "$ND_MODELS" | jq '.models')" \
  --arg ref_avg "$REF_AVG_PRICE" \
  --arg ref_in_kwh "$REF_INPUT_KWH" \
  --arg ref_out_kwh "$REF_OUTPUT_KWH" \
  '
  ($ref_avg | tonumber) as $ref_avg |
  ($ref_in_kwh | tonumber) as $ref_in_kwh |
  ($ref_out_kwh | tonumber) as $ref_out_kwh |
  [
    $user_models[] |
    . as $um |
    ($nd_models | map(select(.provider == $um.provider and .model == $um.id)) | first // null) as $nd |
    if $nd then
      # Compute energy estimate from pricing ratio
      (($nd.input_price + $nd.output_price) / 2) as $avg_price |
      ($avg_price / $ref_avg) as $ratio |
      {
        id: $um.id,
        provider: $um.provider,
        display: ($um.display // $um.id),
        input_price: $nd.input_price,
        output_price: $nd.output_price,
        input_kwh_per_token: ($ref_in_kwh * $ratio),
        output_kwh_per_token: ($ref_out_kwh * $ratio),
        available: true
      }
    else
      {
        id: $um.id,
        provider: $um.provider,
        display: ($um.display // $um.id),
        input_price: null,
        output_price: null,
        input_kwh_per_token: null,
        output_kwh_per_token: null,
        available: false
      }
    end
  ]
  ')

# Convert scientific notation to decimal strings (bc can't handle 4E-7)
echo "$RESULT" | awk '{
  while (match($0, /[0-9]+(\.[0-9]+)?[eE][+-]?[0-9]+/)) {
    sci = substr($0, RSTART, RLENGTH)
    cmd = "printf \"%.10f\" " sci
    cmd | getline dec
    close(cmd)
    # Strip trailing zeros but keep at least one decimal
    while (dec ~ /0$/ && dec !~ /\.0$/) sub(/0$/, "", dec)
    gsub(/[.]$/, ".0", dec)
    $0 = substr($0, 1, RSTART-1) "\"" dec "\"" substr($0, RSTART+RLENGTH)
  }
  print
}' > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"

# Report warnings for unavailable models
WARNINGS=$(echo "$RESULT" | jq -r '.[] | select(.available == false) | "warning: \(.provider)/\(.id) not found on Not Diamond"')
if [ -n "$WARNINGS" ] && [ "$QUIET" != "--quiet" ]; then
  echo "$WARNINGS" >&2
fi

VALID=$(echo "$RESULT" | jq '[.[] | select(.available == true)] | length')
TOTAL=$(echo "$RESULT" | jq 'length')
[ "$QUIET" != "--quiet" ] && echo "synced $VALID/$TOTAL models to $CACHE_FILE" >&2
