# herdr-claude-lifecycle

Hook-first **Claude Code lifecycle for [herdr](https://herdr.dev)** — `working` / `blocked` / `idle` reported from Claude Code's own hooks instead of screen-scraping, with `Stop.background_tasks` deciding idle vs still-working. Ships a `verify` you run after every Claude Code update, and a state file an Omarchy bar widget can watch.

**Status:** reporter proven on herdr 0.8.2 (fresh pane, all states read back), e2e-green on Claude Code 2.1.252 and 2.1.257. See [CONTRACT.md](CONTRACT.md) for the design and the measured facts.

## How it works
- `hooks/claude-lifecycle.py` — one Python process per hook event (~30–50 ms; the tool events run `async`). Silent on stdout, exit 0 always. Maps
  `SessionStart→idle · UserPromptSubmit/PreToolUse/PostToolUse→working · PermissionRequest/Notification(permission_prompt…)→blocked · Stop→idle iff background_tasks==[] · SessionEnd→release`, ignores `SubagentStop` and subagent hooks.
- Inside a herdr pane (`HERDR_ENV=1`) it calls `pane.report_agent` as source `daocoding:claude`; always writes `$XDG_STATE_HOME/omarchy/claude-lifecycle/current.json`.
- `bin/claude-lifecycle` — `install-hooks` · `uninstall-hooks` · `verify` · `capture` · `e2e` · `status`.

## Install
```sh
git clone https://github.com/daocoding/herdr-claude-lifecycle ~/Dev/herdr-claude-lifecycle
cd ~/Dev/herdr-claude-lifecycle
python3 bin/claude-lifecycle e2e            # throwaway claude -p through the real reporter; must print E2E OK
python3 bin/claude-lifecycle install-hooks  # writes 14 hook wirings into ~/.claude/settings.json (backup alongside)
python3 bin/claude-lifecycle verify         # wiring + fixtures + version drift; run after every Claude Code update
herdr plugin link .                         # optional: expose the actions inside herdr
```
**If `herdr integration install claude` is installed:** its `SessionStart` hook makes every Claude pane owned by `herdr:claude`, and herdr then ignores all other sources. Run `herdr integration uninstall claude`, then exit and relaunch `claude` once in each existing pane. You lose herdr's `claude --resume` restore for those panes.

## Remove
```sh
python3 bin/claude-lifecycle uninstall-hooks   # removes only our wirings
herdr plugin unlink daocoding.claude-lifecycle  # if linked
rm -rf ~/.local/state/omarchy/claude-lifecycle
```

## Verify after a Claude Code update
`python3 bin/claude-lifecycle verify` fails loudly if the installed version differs from the one the fixtures were captured from, if `Stop` stops carrying `background_tasks`, if any event's mapping changes, or if the reporter ever writes to stdout. `capture` re-baselines the fixtures.

## Tests
`sh tests/run.sh` (unit, herdr absent) · `sh tests/herdr-live.sh <pane>` (real herdr, throwaway pane only) · `sh tests/fresh-pane.sh <base_pane>` (splits a fresh pane, runs the live table, closes it).

MIT — daocoding.
