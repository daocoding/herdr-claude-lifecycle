#!/bin/sh
# Live acceptance against a REAL herdr pane. Row 0 = readback BEFORE any feed (positive control for the instrument).
# usage: tests/herdr-live.sh <pane_id>   — ONLY on a throwaway pane; it authors state and releases at the end.
set -u; P="${1:?pane_id}"; R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); H="$R/hooks/claude-lifecycle.py"
SOCK="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"; [ -S "$SOCK" ] || { echo "no herdr socket at $SOCK"; exit 2; }
export HERDR_ENV=1 HERDR_PANE_ID="$P" HERDR_SOCKET_PATH="$SOCK" CLAUDE_LIFECYCLE_SKIP_GATE=1   # fed from outside the pane: bypass the owner gate on purpose XDG_STATE_HOME="${XDG_STATE_HOME:-$(mktemp -d)}"
rb(){ python3 - "$P" <<'PYRB'
import socket,sys,json,os
p=sys.argv[1]; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(os.environ["HERDR_SOCKET_PATH"])
s.sendall((json.dumps({"id":"rb","method":"agent.get","params":{"target":p}})+"\n").encode()); b=b""
while not b.endswith(b"\n"):
    c=s.recv(65536)
    if not c: break
    b+=c
a=json.loads(b).get("result",{}).get("agent",{}); ses=a.get("agent_session") or {}
print("%-8s agent=%s seq=%s session_src=%s labels=%s" % (a.get("agent_status","?"),a.get("agent"),a.get("state_change_seq"),ses.get("source"),a.get("state_labels")))
PYRB
}
feed(){ printf '%s' "$2" | python3 "$H"; sleep 0.25; got=$(rb); st=${got%% *}
  # herdr renders a reported idle as `done` on a pane not viewed since it went idle — its presentation, not ours
  if [ "$st" = "$3" ] || { [ "$3" = idle ] && [ "$st" = done ]; }; then echo "  ok   $1 → $got"; else echo "  FAIL $1 → $got   (want $3)"; fail=$((fail+1)); fi; }
fail=0; SID="live-$$"
echo "  row0 BEFORE            → $(rb)"
feed UserPromptSubmit  "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\"}" working
feed PermissionRequest "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$SID\",\"tool_name\":\"Bash\"}" blocked
feed PostToolUse       "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"tool_name\":\"Bash\"}" working
feed Stop+bg           "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[{\"id\":\"t\",\"type\":\"MCP task\",\"status\":\"running\"}]}" working
feed Stop              "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"background_tasks\":[]}" idle
feed Notif:permission  "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"notification_type\":\"permission_prompt\"}" blocked
printf '%s' "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\"}" | python3 "$H"; sleep 0.25
got=$(rb); st=${got%% *}
case "$st" in unknown|\?*) echo "  ok   SessionEnd/release → $got";; *) echo "  FAIL SessionEnd/release → $got   (want unknown: authored state cleared)"; fail=$((fail+1));; esac
echo "── herdr-live: $fail failed"; [ $fail -eq 0 ]
