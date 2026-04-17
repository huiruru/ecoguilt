---
name: history
description: Show cumulative environmental and cost impact across all sessions — today, this week, all time — plus a session log and anomaly summary.
user-invocable: true
allowed-tools: Bash
model: haiku
---

Show the cross-session environmental and cost history.

## Step 1: Load history and merge live session state

```bash
HISTORY_FILE="$HOME/.ecoguilt/history.jsonl"

# Load persisted records (may be empty or missing for a brand-new session)
if [ -f "$HISTORY_FILE" ]; then
  HISTORY_JSON=$(tac "$HISTORY_FILE" | jq -sc '
    group_by(.session_id) |
    map(max_by(.last_updated))
  ')
else
  HISTORY_JSON='[]'
fi

# Find the current session's live state file via CWD hash
CWD_HASH=$(echo -n "$PWD" | md5 2>/dev/null || echo -n "$PWD" | md5sum 2>/dev/null | cut -d' ' -f1)
LIVE_SESSION_ID=$(cat "/tmp/ecoguilt-cwd-${CWD_HASH}.txt" 2>/dev/null)
if [ -z "$LIVE_SESSION_ID" ]; then
  LIVE_SESSION_ID=$(ls -t /tmp/ecoguilt-*.json 2>/dev/null | grep -v 'models\|test\|recommend\|cwd\|anomaly\|fact' | head -1 | sed 's|/tmp/ecoguilt-||; s|\.json||')
fi
LIVE_STATE=""
if [ -n "$LIVE_SESSION_ID" ]; then
  LIVE_STATE=$(cat "/tmp/ecoguilt-${LIVE_SESSION_ID}.json" 2>/dev/null)
fi

# Merge: if live state exists and has more tokens than what's in history, replace that session's entry.
# This ensures the current session always reflects up-to-date numbers, even mid-turn.
if [ -n "$LIVE_STATE" ] && [ "$(echo "$LIVE_STATE" | jq '.total_tokens // 0')" -gt 0 ]; then
  TODAY=$(date -u +%Y-%m-%d)
  LIVE_RECORD=$(echo "$LIVE_STATE" | jq --arg sid "$LIVE_SESSION_ID" --arg date "$TODAY" --arg cwd "$PWD" '{
    session_id: $sid,
    date: $date,
    cwd: $cwd,
    last_updated: "live",
    model: .model,
    cost_usd: (.cost_usd | tonumber),
    total_tokens: .total_tokens,
    input_tokens: .input_tokens,
    output_tokens: .output_tokens,
    total_kwh: (.total_kwh | tonumber),
    co2_g: (.co2_g | tonumber),
    water_ml: .water_ml,
    total_cache_read: .total_cache_read,
    total_cache_write: .total_cache_write,
    turn_tokens: 0,
    turn_cost_usd: 0,
    anomaly: null
  }')
  # Replace or prepend the live session entry
  SESSIONS=$(echo "$HISTORY_JSON" | jq --argjson live "$LIVE_RECORD" '
    [.[] | select(.session_id != $live.session_id)] + [$live] |
    sort_by(.date) | reverse
  ')
else
  SESSIONS=$(echo "$HISTORY_JSON" | jq 'sort_by(.date) | reverse')
fi
echo "$SESSIONS"
```

If `SESSIONS` is empty (`[]`) and there's no live state, tell the user no history exists yet.

## Step 2: Compute aggregates

Use `$SESSIONS` from Step 1 directly. Do NOT re-run the history load.

```bash
TODAY=$(date -u +%Y-%m-%d)
WEEK_AGO=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo "")

# Today
echo "$SESSIONS" | jq --arg d "$TODAY" '[.[] | select(.date == $d)] | {
  cost: ([.[].cost_usd] | add // 0),
  tokens: ([.[].total_tokens] | add // 0),
  co2_g: ([.[].co2_g] | add // 0),
  water_ml: ([.[].water_ml] | add // 0),
  count: length
}'

# This week
echo "$SESSIONS" | jq --arg d "$WEEK_AGO" '[.[] | select(.date >= $d)] | {
  cost: ([.[].cost_usd] | add // 0),
  tokens: ([.[].total_tokens] | add // 0),
  co2_g: ([.[].co2_g] | add // 0),
  water_ml: ([.[].water_ml] | add // 0),
  count: length
}'

# All time
echo "$SESSIONS" | jq '{
  cost: ([.[].cost_usd] | add // 0),
  tokens: ([.[].total_tokens] | add // 0),
  co2_g: ([.[].co2_g] | add // 0),
  water_ml: ([.[].water_ml] | add // 0),
  count: length
}'
```

## Step 3: Collect anomalies (this week)

From the deduplicated sessions, find all anomalous turns in the raw history (not deduplicated — we want individual turns):

```bash
tac "$HOME/.ecoguilt/history.jsonl" | jq -sc --arg d "$WEEK_AGO" '
  [.[] | select(.date >= $d and .anomaly != null)] |
  sort_by(.last_updated) | reverse | .[0:10]
'
```

## Step 4: Present

**Tone:** Deadpan. Numbers do the talking. No softening.

**Section 1 — Totals:**

Format each time window as one line. Use `k` for thousands of tokens, `L` for litres of water when ≥1000ml. Include a one-line CO2 visual for all-time only.

```
today       $3.90  21.7g CO₂  100ml water  70k tokens
this week   $18.42  103g CO₂  473ml water  331k tokens
all time    $94.17  527g CO₂  2.4L water  1.7M tokens
            → enough CO₂ to drive 1.3 miles going nowhere
```

Then anomaly summary if any exist this week:

```
⚠ 3 anomalies this week
  output_spike  "write a comprehensive test suite for..."  out:8,234 / in:412  +$0.18
  cache_break   "can you refactor this entire module..."   82% → 12%           +$0.31
  input_spike   "paste the full logs below:"              in:9,102 / out:380   +$0.09
```

For each anomaly record, show the direction breakdown from `turn_input_tokens` and `turn_output_tokens` for input/output spikes, and efficiency drop from `prev_cache_efficiency` → `turn_cache_efficiency` for cache breaks.

**Section 2 — Session log (most recent first, up to 20 sessions):**

One line per session. Mark sessions that had any anomalous turn with `⚠`. Use the project directory basename for brevity.

```
2026-04-16  ecoguilt    $3.90  21.7g  70k tok  sonnet-4.6  ⚠
2026-04-15  myapp       $7.22  40.1g  142k tok  opus-4.6
2026-04-14  myapp       $1.14   6.3g  23k tok   haiku-4.5
```

For the anomaly flag: check if any record in history.jsonl for that session_id has a non-null anomaly field. Use `type == "object"` to handle old records where anomaly was serialized as the string `"null"` rather than JSON null:

```bash
SESSION_ID="<session_id>"
HAS_ANOMALY=$(grep "\"session_id\":\"${SESSION_ID}\"" "$HOME/.ecoguilt/history.jsonl" | jq -r 'select(.anomaly | type == "object") | .session_id' | head -1)
```

**Footer:** `*session costs update at the end of each turn. the current session's live totals are always included.*`

$ARGUMENTS
