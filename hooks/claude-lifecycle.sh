#!/bin/sh
# claude-lifecycle reporter — invoked by Claude Code hooks (JSON on stdin).
# CONTRACT.md §1: silent on stdout, exit 0, <100 ms, ordered by per-source seq.
set -u
REPORTER_VERSION="0.1.0"; CONTRACT_VERSION=1
SOURCE="${CLAUDE_LIFECYCLE_SOURCE:-daocoding:claude}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/claude-lifecycle"
dbg(){ [ "${CLAUDE_LIFECYCLE_DEBUG:-0}" = 1 ] && printf 'claude-lifecycle: %s\n' "$*" >&2; :; }

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# One python pass: parse, map, decide. Prints "state|session_id|block_reason|bg_json|version|hook"
decision=$(CL_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json,os,sys
try: h=json.loads(os.environ["CL_INPUT"])
except Exception: sys.exit(0)
ev=str(h.get("hook_event_name") or "")
sid=str(h.get("session_id") or "")
if h.get("agent_id"): sys.exit(0)                     # subagent hooks never speak for the pane
BLOCK_NOTIF={"permission_prompt","elicitation_dialog","elicitation_url_dialog","agent_needs_input"}
state=None; reason=""; bg=[]
if ev=="SessionStart": state="idle"
elif ev in ("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","ElicitationResult","PreCompact"): state="working"
elif ev=="PermissionRequest": state="blocked"; reason="permission_request:"+str(h.get("tool_name") or "")
elif ev=="Elicitation": state="blocked"; reason="elicitation"
elif ev=="Notification":
    nt=str(h.get("notification_type") or "")
    if nt in BLOCK_NOTIF: state="blocked"; reason=nt
    else: sys.exit(0)
elif ev=="Stop":
    bg=[t for t in (h.get("background_tasks") or []) if isinstance(t,dict)]
    state="working" if bg else "idle"
elif ev=="TaskCompleted":
    state="reeval"                                     # consumer re-reads Stop's bg list; treat as idle only if none known
elif ev=="SessionEnd": state="release"
elif ev=="SubagentStop": sys.exit(0)                   # herdr #198: fires after the main turn; never revive a pane
else: sys.exit(0)
slim=[{k:t.get(k) for k in ("type","status","server","tool","agent_type","name") if t.get(k) is not None} for t in bg]
print("|".join([state,sid,reason,json.dumps(slim,separators=(",",":")),str(h.get("version") or ""),ev]))
PY
)
[ -n "$decision" ] || exit 0
state=${decision%%|*}; rest=${decision#*|}
sid=${rest%%|*}; rest=${rest#*|}
reason=${rest%%|*}; rest=${rest#*|}
bg=${rest%%|*}; rest=${rest#*|}
cver=${rest%%|*}; ev=${rest#*|}
[ "$state" = reeval ] && state=idle

# ── seq + lock (per source, per pane-or-session) ─────────────────
key=$(printf '%s' "${HERDR_PANE_ID:-$sid}" | tr -c '[:alnum:]_.-' '_')
mkdir -p "$STATE_ROOT" 2>/dev/null || exit 0
seqf="$STATE_ROOT/.seq-$key"; lock="$seqf.lock"; n=0
while ! mkdir "$lock" 2>/dev/null; do
  o=$(cat "$lock/pid" 2>/dev/null || true); [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null && rmdir "$lock" 2>/dev/null
  n=$((n+1)); [ $n -ge 200 ] && exit 0; sleep 0.01
done
printf '%s' "$$" >"$lock/pid" 2>/dev/null || true
trap 'rm -f "$lock/pid" 2>/dev/null; rmdir "$lock" 2>/dev/null' EXIT HUP INT TERM
prev=$(tr -dc 0-9 <"$seqf" 2>/dev/null || true); now=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(time.time_ns())')
case "$prev" in ''|*[!0-9]*) prev=0;; esac
seq=$now; [ "$seq" -le "$prev" ] 2>/dev/null && seq=$((prev+1))
printf '%s\n' "$seq" >"$seqf.tmp.$$" && mv "$seqf.tmp.$$" "$seqf"

# ── consumer 3b: state file (always) ──────────────────────────────
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -n "$sid" ] || sid="unknown"
f="$STATE_ROOT/$sid.json"; since=$ts
if [ -f "$f" ]; then
  ps=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("state",""),d.get("since",""))' "$f" 2>/dev/null || true)
  [ "${ps%% *}" = "$state" ] && since=${ps#* }
fi
CL_F="$f" CL_STATE="$state" CL_SID="$sid" CL_SINCE="$since" CL_TS="$ts" CL_PANE="${HERDR_PANE_ID:-}" CL_BG="$bg" CL_REASON="$reason" CL_CVER="$cver" CL_EV="$ev" \
python3 - <<'PY' 2>/dev/null || true
import json,os
e=os.environ; f=e["CL_F"]
d={"contract_version":1,"session_id":e["CL_SID"],"state":e["CL_STATE"],"since":e["CL_SINCE"],"updated_at":e["CL_TS"],
   "pane_id":e["CL_PANE"] or None,"background_tasks":json.loads(e["CL_BG"] or "[]"),"block_reason":e["CL_REASON"] or None,
   "last_event":e["CL_EV"],"claude_version":e["CL_CVER"] or None,"reporter_version":"0.1.0"}
tmp=f+".tmp."+str(os.getpid()); open(tmp,"w").write(json.dumps(d,separators=(",",":"))); os.replace(tmp,f)
cur=os.path.join(os.path.dirname(f),"current.json"); tmp2=cur+".tmp."+str(os.getpid()); open(tmp2,"w").write(json.dumps(d,separators=(",",":"))); os.replace(tmp2,cur)
PY
[ "$state" = release ] && rm -f "$f" 2>/dev/null

# ── consumer 3a: herdr (only inside a herdr pane) ──────────────────
[ "${HERDR_ENV:-}" = 1 ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -S "$HERDR_SOCKET_PATH" ] || exit 0
if [ "$state" = release ]; then method=pane.release_agent; params="{\"pane_id\":\"$HERDR_PANE_ID\",\"source\":\"$SOURCE\",\"agent\":\"claude\"}"
else msg=""; [ -n "$reason" ] && msg=",\"message\":\"$reason\""
  params="{\"pane_id\":\"$HERDR_PANE_ID\",\"source\":\"$SOURCE\",\"agent\":\"claude\",\"state\":\"$state\",\"seq\":$seq$msg}"; method=pane.report_agent; fi
req="{\"id\":\"$SOURCE:$seq\",\"method\":\"$method\",\"params\":$params}"
CL_SOCK="$HERDR_SOCKET_PATH" CL_REQ="$req" python3 - <<'PY' 2>/dev/null || true
import os,socket
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(0.5)
try:
    s.connect(os.environ["CL_SOCK"]); s.sendall((os.environ["CL_REQ"]+"\n").encode())
    try: s.recv(4096)
    except Exception: pass
finally: s.close()
PY
dbg "$ev -> $state seq=$seq pane=${HERDR_PANE_ID:-}"
exit 0
