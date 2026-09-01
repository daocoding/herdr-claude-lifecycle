# Draft — herdr issue (bug template), re: #3090 — NOT POSTED

**Title:** Claude Code: `Stop.background_tasks` gives a hook-authoritative idle/working signal; official integration stays identity-only and blocks third-party lifecycle sources

## Summary
`herdr integration install claude` (v8/v9 `herdr-agent-state.sh`) reports identity on `SessionStart` only, so Claude panes are still screen-detected for `working`/`blocked`/`idle`. Claude Code's hooks now carry enough to author state directly, and the piece that made `Stop` ambiguous is solved upstream: the `Stop` payload includes `background_tasks: [...]` (measured on 2.1.251, 2.1.252, 2.1.257), so a turn that ended while MCP tasks / background agents are still running is distinguishable from a genuinely idle pane.

## What we measured (herdr 0.8.2, Linux)
1. A non-official source (`daocoding:claude`, agent `claude`) reporting `pane.report_agent` on a **fresh pane** is applied: working / blocked / idle / release all read back via `agent.get` (`state_change_seq` advances). Full table: <link to tests/herdr-live.sh output>.
2. On a pane whose persisted `agent_session.source` is `herdr:claude`, the same reports return `{"result":{"type":"ok"}}` and change nothing (`state_change_seq` frozen). `state.rs current_session_owner_conflicts` + `agent_resume::plan()` refusing non-official sources means no third-party source can ever author state on a pane the official integration has touched — even with the Claude process in the foreground.
3. `agent.explain` reports only the screen-detection path — in **both** directions: a dropped authored report is invisible to it, and so is an applied one (on a live Claude pane with an authored `blocked` in force, explain still said `rule: osc_title_working`, priority 1100). It is not a diagnostic for authored-vs-scraped. (An OpenCode pane shows `screen_detection_skip_reason: full_lifecycle_hook_authority`, which is the honest shape.)
   Authored state from a non-official source on an un-owned live pane does apply and holds against a contradicting scrape (measured: blocked held 12+ s under a spinning OSC title).
4. `pane.release_agent` without `seq` is dropped as stale (no error).
5. `pane.report_agent_session` from a non-official source (identical params to the official script) returns `ok` and sets nothing — third-party lifecycle sources cannot populate `agent_session`.
6. `pane.process_info` ignores an unknown param name (`target`) and answers for the **focused** pane instead of erroring — a wrong-pane answer that looks right.

## Ask (any of)
- A. Make `("herdr:claude","claude")` a full-lifecycle-hook authority source and have the official script report `working` on `UserPromptSubmit`/`PreToolUse`/`PostToolUse`, `blocked` on `PermissionRequest` / `Notification{permission_prompt,elicitation_*,agent_needs_input}`, `idle` on `Stop` **iff** `background_tasks == []` else `working`, release on `SessionEnd`; ignore `SubagentStop` (#198) and any payload with `agent_id`.
- B. Or: return an explicit error (not `ok`) when a report is dropped for owner conflict, and let `agent.explain` show the authored-state decision, so third-party integrations can detect the block.
- C. Or: document that `herdr integration install claude` makes panes unreachable by any other source, so users can choose.

## Environment
herdr 0.8.2 · Claude Code 2.1.252/2.1.257 · Omarchy 4.0.1 (Arch) · reference implementation: https://github.com/daocoding/herdr-claude-lifecycle (contract + tests)
