#!/bin/sh
# Pane-owner gate on a REAL herdr: splits a fresh pane off <base>, then
#   NEGATIVE — feeds SessionStart+UserPromptSubmit from THIS shell (not the pane's foreground) → herdr must stay unknown
#   POSITIVE — feeds the same via `herdr pane run` (runs inside the pane's foreground job) → herdr must show working, identity under our source
#   RELEASE  — SessionEnd via pane run → back to unknown; then closes the pane.
# usage: tests/gate-live.sh <base_pane_id>
set -u; BASE="${1:?base pane}"; R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); cd "$R"; fail=0
SOCK="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"; W=$(mktemp -d)
get(){ herdr pane get "$1" 2>/dev/null | python3 -c 'import json,sys;p=json.load(sys.stdin)["result"]["pane"];s=p.get("agent_session") or {};print("%s agent=%s session_src=%s sid=%s"%(p.get("agent_status"),p.get("agent"),s.get("source"),s.get("value")))'; }
chk(){ got=$(get "$NEW"); st=${got%% *}; if [ "$st" = "$2" ]; then echo "  ok   $1 → $got"; else echo "  FAIL $1 → $got   (want $2)"; fail=$((fail+1)); fi; }
NEW=$(herdr pane split "$BASE" --direction down --no-focus --cwd "$HOME" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'); [ -n "$NEW" ] || { echo "split failed"; exit 2; }
echo "fresh pane $NEW"; sleep 3; chk "row 0" unknown
SID="gate-$$"
for ev in SessionStart UserPromptSubmit; do printf '%s' "{\"hook_event_name\":\"$ev\",\"session_id\":\"$SID-neg\",\"source\":\"startup\"}" | HERDR_ENV=1 HERDR_PANE_ID="$NEW" HERDR_SOCKET_PATH="$SOCK" XDG_STATE_HOME="$W" python3 hooks/claude-lifecycle.py; done
sleep 0.5; chk "NEGATIVE (fed from outside the pane)" unknown
cat >"$W/feed.sh" <<FEED
cd '$R'; export XDG_STATE_HOME='$W' CLAUDE_LIFECYCLE_DEBUG=1
for ev in SessionStart UserPromptSubmit; do printf '%s' "{\"hook_event_name\":\"\$ev\",\"session_id\":\"$SID-pos\",\"source\":\"startup\"}" | python3 hooks/claude-lifecycle.py 2>>'$W/pos.log'; done
FEED
herdr pane run "$NEW" sh "$W/feed.sh" >/dev/null 2>&1; sleep 4; chk "POSITIVE (fed via herdr pane run)" working
got=$(get "$NEW"); case "$got" in *"session_src=daocoding:claude sid=$SID-pos"*) echo "  ok   identity under daocoding:claude = $SID-pos";; *) echo "  FAIL identity not set: $got"; fail=$((fail+1));; esac
own=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pane_owner"))' "$W/omarchy/claude-lifecycle/$SID-pos.json" 2>/dev/null); [ "$own" = True ] && echo "  ok   pane_owner=True cached" || { echo "  FAIL pane_owner=$own"; fail=$((fail+1)); }
printf '%s\n' "cd '$R'; export XDG_STATE_HOME='$W'; printf '%s' '{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID-pos\"}' | python3 hooks/claude-lifecycle.py" >"$W/end.sh"
herdr pane run "$NEW" sh "$W/end.sh" >/dev/null 2>&1; sleep 2; chk "RELEASE (SessionEnd via pane run)" unknown
herdr pane close "$NEW" >/dev/null 2>&1; rm -rf "$W"; echo "── gate-live: $fail failed"; [ $fail -eq 0 ]
