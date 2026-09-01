# CONTRACT — herdr-claude-lifecycle

Written first, before any code. Every component below is a consumer or producer of this contract;
a change here is a breaking change and bumps `contract_version`.

## 1. The primitive: the reporter

One script, `hooks/claude-lifecycle.sh`, invoked by Claude Code hooks. It reads the hook JSON on
stdin, derives one lifecycle state, and publishes it to every consumer that is present.

**Invariants**
- **Silent on stdout. Always.** Claude Code injects plain stdout as context on `UserPromptSubmit`
  and `SessionStart`, and shows a `hook error` for non-JSON stdout on decision events (≥ v2.1.248).
  Diagnostics go to stderr only, and only when `CLAUDE_LIFECYCLE_DEBUG=1`.
- **Exit 0. Always.** A reporter failure must never block, slow, or alter Claude. Socket down,
  herdr absent, malformed JSON — all exit 0 within the hook timeout.
- **Fast.** Budget 100 ms. No network. One socket write, one file rename.
- **Idempotent and ordered.** Per-source monotonic `seq` (ns since epoch, max(prev+1, now)),
  persisted so a reporter restart never issues a lower seq (herdr silently drops lower seqs from
  the same source — issue #3184 footgun). Serialised with a `mkdir` lock (Cline pattern).

## 2. State map (Claude Code hook event → lifecycle state)

| Claude hook event | payload used | → state |
|---|---|---|
| `SessionStart` | `session_id`, `transcript_path` | `idle` + session identity |
| `UserPromptSubmit` | — | `working` |
| `PreToolUse` | — | `working` |
| `PostToolUse` / `PostToolUseFailure` | — | `working` (turn continues) |
| `PermissionRequest` | `tool_name` | `blocked` (immediate) |
| `Notification` | `notification_type ∈ {permission_prompt, elicitation_dialog, elicitation_url_dialog, agent_needs_input}` | `blocked` |
| `Notification` | other types | ignored |
| `Elicitation` / `ElicitationResult` | — | `blocked` / `working` |
| `Stop` | `background_tasks` | **`idle` iff `background_tasks == []`, else `working`** (this is the #3090 fix) |
| `SubagentStop` | — | **ignored** (herdr #198: fires after the main turn; never revive an idle pane) |
| `TaskCompleted` | — | re-evaluate: if no other background task, `idle` |
| `SessionEnd` | — | `release` |

Reportable states are exactly herdr's `PaneAgentState`: `idle | working | blocked | unknown`.
`done` is derived by herdr (idle + unseen), never reported.

## 3. Consumers

### 3a. herdr (present iff `HERDR_ENV=1 && HERDR_PANE_ID && HERDR_SOCKET_PATH`)
- Method `pane.report_agent`, params `{pane_id, source, agent:"claude", state, seq, message?}`.
- **`source = "daocoding:claude"`** — never in the `herdr:` namespace (reserved/official space;
  `herdr:claude` is routed to identity-only by `agent_resume::is_reserved_native_state_source`).
- Session identity: NOT reported via `pane.report_agent_session` — `session_ref_from_report`
  refuses non-official sources, and an official-source session ref would make the pane OWNED and
  reject our state (Route A trade-off, accepted by Tony 2026-09-01).
- `SessionEnd` → `pane.release_agent {pane_id, source, agent}`.
- Expected tier: **partial** — `screen_detection_skipped` stays `false`; screen-detected approval
  UIs override our state via `visible_blocker_overrides_hook`. That is correct and desired.

### 3b. State file (always written)
`$XDG_STATE_HOME/omarchy/claude-lifecycle/<session_id>.json` (default `~/.local/state/...`),
written atomically (tmp + rename), plus `current.json` → the most recently updated session.
```json
{ "contract_version": 1, "session_id": "…", "state": "working|blocked|idle|released",
  "since": "<ISO-8601>", "updated_at": "<ISO-8601>", "pane_id": "w2:p1|null",
  "background_tasks": [{"type":"MCP task","server":"…","tool":"…"}], "block_reason": "permission_prompt|null",
  "claude_version": "2.1.251", "reporter_version": "0.1.0" }
```
Consumers must treat `updated_at` older than 15 min as stale → hide.

## 4. `verify` — the update discipline
`claude-lifecycle verify` runs on demand and MUST be run after every Claude Code update:
1. Confirms hook wiring present in `~/.claude/settings.json` for every event in §2, none extra.
2. Feeds recorded fixture payloads (`fixtures/<event>.json`, captured from the installed version)
   through the parser; asserts each mapped state.
3. **Live probe:** starts `claude -p` in a throwaway session with a hook that captures raw payloads,
   diffs field presence against the fixtures (`background_tasks`, `notification_type`,
   `hook_event_name`, `session_id`). Any missing field = FAIL, exit 1, named field.
4. Reports the installed `claude --version` and the fixture version side by side.

## 5. Sequencing (Route A)
1. Build + `verify` green on M5 and on matebook using a **throwaway pane** (never Mate's).
2. `herdr integration uninstall claude` on matebook (removes the official SessionStart hook).
3. Install ours; confirm on a fresh Claude pane: `working` within one tick of a prompt, `blocked`
   within one tick of `PermissionRequest`, `idle` only after `Stop` with empty `background_tasks`.
4. Then, and only then, tell Mate to start new sessions.


## 6. Measured on herdr 0.8.2 (matebook, 2026-09-01) — facts the design now rests on

- **`{"result":{"type":"ok"}}` is a transport receipt, not an application receipt.** Seven reports + a release to an owned pane all returned `ok` and moved `state_change_seq` by zero. `agent.explain` cannot see authored-state decisions (screen detector only). **The only verdict is `agent.get {target:<pane>}` read back after the report** — `tests/herdr-live.sh` does this with row 0 = before any feed.
- **Discriminator = `agent_session.source`.** Fresh pane (no persisted identity): `daocoding:claude` reports land — working / blocked / idle / working-with-background-tasks all read back (0 failed). Pane whose persisted identity is `herdr:claude`: every foreign source is inert by design (`state.rs current_session_owner_conflicts`, both report paths); takeover requires `agent_resume::plan()` to accept the source, which it refuses for non-official sources. Only that Claude's own exit clears its ref (`process_exit_clears_matching_persisted_session_ref`); a foreign release cannot.
- **A release must carry `seq`** — herdr's per-source ordering guard drops a seq-less release as stale.
- **herdr renders a reported `idle` as `done` on a pane not viewed since** — its presentation; this reporter never emits `done`.
- **`claude --settings <file>` MERGES** with `~/.claude/settings.json`; `capture`/`e2e` therefore scrub `HERDR_*` so an installed herdr hook cannot claim a real pane for a throwaway session (it did, once — w2:p2, session 2793a917).
- **`Stop.background_tasks` is present** in real payloads on 2.1.251, 2.1.252 and 2.1.257. **No hook payload carries `version`** — the version is stamped by `install-hooks`/`verify` (never spawned inside a hook). `PermissionRequest`/`Notification` do not fire under `claude -p`; their fixtures come from an interactive session.
- **Route A migration:** after `herdr integration uninstall claude`, existing panes keep their `herdr:claude` identity until that Claude exits ⇒ exit and relaunch `claude` once per pane; if a stale ref survives (pane was a bare shell), close and recreate the pane. New panes need nothing.


## 7. Decision (2026-09-01, Cody; raised by Mate's handoff): pane-owner gate + identity under our source

**Rule:** inside herdr, a hook may speak for a pane **only if the Claude that spawned it is in that pane's foreground process set** — `pane.process_info {target}` → `foreground_processes[].pid` ∩ the hook's ancestor pids, or `foreground_process_group_id == getpgrp()`. Verdict is cached per session (`pane_owner` in the session file) from `SessionStart`; if herdr cannot answer, nothing is cached and the next event retries — never fail open, never cache a failure.

**What the gate buys:**
- **Identity is back without the hazard.** On `SessionStart`, an owning session reports `pane.report_agent_session` under `daocoding:claude` (`agent_session_id` = Claude's `session_id`, `session_start_source` = the payload's `source`), so `agent_session` is populated for Claude panes again and the herd's documented readback route (session id from `agent_session`) keeps its anchor. herdr's `claude --resume` restore still refuses non-official sources — no new loss versus Route A.
- **The pane-env foot-gun is closed for our source.** A `claude -p` started from a pane's shell inherits `HERDR_PANE_ID` but is not the pane's foreground process ⇒ it writes its own session file only: no herdr report, no identity, and it never overwrites `current.json`.
- `CLAUDE_LIFECYCLE_SKIP_GATE=1` exists for tests/harnesses that feed fixtures from outside a pane (`tests/herdr-live.sh` uses it); the installed hooks never set it.

**Cost:** one extra socket round-trip per session (not per event). Tested: `tests/gate.sh` (fake herdr: positive, negative, herdr-down) and live on matebook (SSH feed = negative, `herdr pane run` feed = positive).

**Measured after Route A (2026-09-01, herdr 0.8.2 + Claude Code 2.1.257):** the installed hooks alone drove a real `claude -p` in a fresh pane through `unknown → idle (1 s) → working (3 s) → done (6 s) → unknown (7 s)`, read from `herdr pane get`. **herdr ignores `pane.report_agent_session` from a non-official source** (same param shape as the official v8 script; `ok` receipt, `agent_session` stays empty) — so identity for Claude panes lives in **our state file**: `claude-lifecycle status --pane <id>` returns the live `session_id` for a pane. The identity report stays in the hook (exercised every SessionStart, currently inert) so identity appears the day herdr accepts it.
