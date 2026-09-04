#!/bin/sh
# Feeds synthetic hook payloads; asserts state file + stdout silence + exit 0. herdr absent.
set -u; R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); H="$R/hooks/claude-lifecycle.py"
T=$(mktemp -d); export XDG_STATE_HOME="$T"; unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
S="$T/omarchy/claude-lifecycle"; pass=0; fail=0
t(){ # name  payload  expected_state|IGNORED
  out=$(printf '%s' "$2" | python3 "$H"); rc=$?
  st=$(python3 -c 'import json,sys,os;p=sys.argv[1];print(json.load(open(p))["state"] if os.path.exists(p) else "NONE")' "$S/current.json" 2>/dev/null)
  ok=1; [ $rc -eq 0 ] || ok=0; [ -z "$out" ] || ok=0
  if [ "$3" = IGNORED ]; then [ "$st" = "$4" ] || ok=0; else [ "$st" = "$3" ] || ok=0; fi
  if [ $ok = 1 ]; then pass=$((pass+1)); printf '  ok   %-28s rc=%s stdout=%d state=%s\n' "$1" $rc ${#out} "$st"
  else fail=$((fail+1)); printf '  FAIL %-28s rc=%s stdout=%d state=%s (want %s)\n' "$1" $rc ${#out} "$st" "$3"; fi
}
SID=abc-123
t SessionStart      "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"version\":\"2.1.257\"}" idle
t UserPromptSubmit  "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\"}" working
t PreToolUse        "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$SID\",\"tool_name\":\"Bash\"}" working
t PermissionRequest "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$SID\",\"tool_name\":\"Bash\"}" blocked
t Notif-idle-ignored "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"notification_type\":\"idle_prompt\"}" IGNORED blocked
t Notif-permission  "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"notification_type\":\"permission_prompt\"}" blocked
t Stop-with-bg      "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[{\"id\":\"t1\",\"type\":\"MCP task\",\"status\":\"running\",\"server\":\"codex\",\"tool\":\"review\"}],\"session_crons\":[]}" working
echo "  bg payload slimmed: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["background_tasks"])' "$S/current.json")"
t Stop-empty-bg     "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[],\"session_crons\":[]}" idle
t Stop-monitor+work  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[{\"id\":\"m1\",\"type\":\"monitor\",\"status\":\"running\"},{\"id\":\"t1\",\"type\":\"MCP task\",\"status\":\"running\"}],\"session_crons\":[]}" working
t Stop-monitor-only  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[{\"id\":\"m1\",\"type\":\"monitor\",\"status\":\"running\",\"description\":\"live updates for artifact (auto-armed on publish)\"}],\"session_crons\":[]}" idle
t SubagentStop-ign  "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID\"}" IGNORED idle
t subagent-ign      "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"agent_id\":\"sub-1\"}" IGNORED idle
t garbage           "not json at all" IGNORED idle
t SessionEnd        "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\"}" release
echo "  bg payload slimmed: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["background_tasks"])' "$S/current.json")"
echo "  seq monotonic: $(cat "$S"/.seq-* | head -1)"
[ -f "$S/$SID.json" ] && { echo "  FAIL session file should be removed on release"; fail=$((fail+1)); } || echo "  ok   session file removed on release"
echo "── $pass passed, $fail failed"; rm -rf "$T"; [ $fail -eq 0 ]
