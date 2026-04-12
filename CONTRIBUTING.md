# Contributing to Ecoguilt

## Setup

```bash
git clone <repo-url>
cd ecoguilt
```

No build step. The plugin is pure bash — just `bash`, `jq`, `curl`, and the `claude` CLI.

## Testing locally

Point Claude Code at your local copy. Add the status line to `~/.claude/settings.json`:

```bash
# In ~/.claude/settings.json
"statusLine": {
  "type": "command",
  "command": "bash /path/to/ecoguilt/scripts/statusline.sh"
}
```

Then launch with the plugin flag to load skills and hooks:

```bash
claude --plugin-dir /path/to/ecoguilt
```

Test the status line manually:

```bash
echo '{"context_window":{"total_input_tokens":5000,"total_output_tokens":2000},"model":{"id":"claude-opus-4-6"},"cost":{"total_cost_usd":0.50},"session_id":"test-123"}' | bash scripts/statusline.sh
```

Test the recommend script (requires `NOTDIAMOND_API_KEY`):

```bash
bash scripts/recommend.sh ~/.claude/projects/<project>/<session>.jsonl
```

Sync models:

```bash
bash scripts/sync-models.sh
```

## Adding models

Add entries to `models.json` and run `/sync-models` or `bash scripts/sync-models.sh`. Each entry needs `id` and `provider`. Optional `display` overrides the status line name.

## Project structure

- `scripts/` — All executable logic. Status line, hook, recommend, sync.
- `skills/` — Skill definitions (`/impact`, `/sync-models`). These are prompts, not code.
- `hooks/` — Hook config for PostToolUse.
- `models.json` — User-editable model list.
- `.claude-plugin/plugin.json` — Plugin manifest.

## Guidelines

- Keep it bash. No Python, no Node, no package managers.
- The status line must be fast. No network calls, no background jobs — those go in the hook.
- State lives in `/tmp/ecoguilt-{session}.json`.
- Energy estimates are derived from pricing. If you have better data, open an issue.

## Submitting changes

1. Fork the repo and create a branch.
2. Test with a live Claude Code session.
3. Open a PR with a description of what changed and why.

## Maintainers

- **Huiru** ([@huiruru](https://github.com/huiruru)) — creator, primary maintainer

I'm a software engineer at Not Diamond which is why this plugin uses the Not Diamond API to recommend lower cost models. Growing up as an immigrant and also as someone who tries (T_T) to care about the environment, LLM model routing definitely appealed this side of me and a big part of why I joined the team. However, this is strictly a side project that was mostly vibed and not affiliated with Not Diamond.

**PRs are welcome and will be reviewed, but response times may vary. If something is urgent, open an issue and tag me.** 
