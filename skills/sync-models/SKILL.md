---
name: sync-models
description: Refresh the ecoguilt model cache — fetch latest pricing from Not Diamond and validate model availability.
user-invocable: true
allowed-tools: Bash Read
---

Sync the ecoguilt model list with Not Diamond's API.

Run:
```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/sync-models.sh
```

This fetches pricing for every model in `models.json`, estimates energy consumption from pricing ratios, and validates that each model is available on Not Diamond's router.

After it runs, show the user:
- How many models synced successfully
- Any warnings about unavailable models
- The full model list with display names and pricing

Then read and display the cached model data:
```bash
cat /tmp/ecoguilt-models.json 2>/dev/null || echo '[]'
```

Format as a clean table: display name, provider, input $/1M, output $/1M, available.

$ARGUMENTS
