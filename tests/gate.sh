#!/bin/sh
# Pane-owner gate against a fake herdr socket. Positive control: fake says the foreground pid is THIS shell (an ancestor of the hook).
# Negative control: fake says foreground pid is 1. Records what the hook sent.
set -u; R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); H="$R/hooks/claude-lifecycle.py"; T=$(mktemp -d); fail=0
python3 - "$T" <<'PY' &
import socket,os,sys,json,threading
T=sys.argv[1]; path=os.path.join(T,"fake.sock"); srv=socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(8)
fg=int(open(os.path.join(T,"fg")).read()) if os.path.exists(os.path.join(T,"fg")) else 1
log=open(os.path.join(T,"log"),"a")
def handle(c):
    b=b""
    while not b.endswith(b"\n"):
        d=c.recv(65536)
        if not d: break
        b+=d
    try: req=json.loads(b)
    except Exception: c.close(); return
    fg=int(open(os.path.join(T,"fg")).read())
    log.write(json.dumps({"method":req["method"],"params":req["params"]})+"\n"); log.flush()
    if req["method"]=="pane.process_info": res={"type":"pane_process_info","process_info":{"pane_id":req["params"].get("pane_id") or req["params"].get("target") or "t:p1","shell_pid":fg,"foreground_process_group_id":-1,"foreground_processes":[{"pid":fg,"name":"claude"}]}}
    else: res={"type":"ok"}
    c.sendall((json.dumps({"id":req["id"],"result":res})+"\n").encode()); c.close()
while True:
    c,_=srv.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
PY
SRV=$!; sleep 0.4
run(){ printf '%s' "$2" | XDG_STATE_HOME="$T/$1" HERDR_ENV=1 HERDR_PANE_ID=t:p1 HERDR_SOCKET_PATH="$T/fake.sock" python3 "$H"; }
sent(){ n=$(grep -c "\"method\": \"$1\"" "$T/log" 2>/dev/null); echo "${n:-0}"; }
echo "── POSITIVE: fake foreground pid = $$ (this shell, an ancestor of the hook)"; echo $$ >"$T/fg"; : >"$T/log"
run pos '{"hook_event_name":"SessionStart","session_id":"s-pos","source":"startup"}'; run pos '{"hook_event_name":"UserPromptSubmit","session_id":"s-pos"}'
echo "  report_agent_session sent: $(sent pane.report_agent_session)   report_agent sent: $(sent pane.report_agent)   process_info asked: $(sent pane.process_info)"
own=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pane_owner"])' "$T/pos/omarchy/claude-lifecycle/s-pos.json"); cur=$([ -f "$T/pos/omarchy/claude-lifecycle/current.json" ] && echo yes || echo no)
[ "$(sent pane.report_agent_session)" = 1 ] && [ "$(sent pane.report_agent)" = 2 ] && [ "$(sent pane.process_info)" = 1 ] && [ "$own" = True ] && [ "$cur" = yes ] && echo "  ok   owner=True, identity once, state twice, gate asked once (cached), current.json written" || { echo "  FAIL owner=$own current=$cur"; fail=1; }
echo "── NEGATIVE: fake foreground pid = 1"; echo 1 >"$T/fg"; : >"$T/log"
run neg '{"hook_event_name":"SessionStart","session_id":"s-neg","source":"startup"}'; run neg '{"hook_event_name":"UserPromptSubmit","session_id":"s-neg"}'
own=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pane_owner"])' "$T/neg/omarchy/claude-lifecycle/s-neg.json"); cur=$([ -f "$T/neg/omarchy/claude-lifecycle/current.json" ] && echo yes || echo no)
echo "  report_agent_session sent: $(sent pane.report_agent_session)   report_agent sent: $(sent pane.report_agent)   process_info asked: $(sent pane.process_info)"
[ "$(sent pane.report_agent_session)" = 0 ] && [ "$(sent pane.report_agent)" = 0 ] && [ "$own" = False ] && [ "$cur" = no ] && echo "  ok   owner=False, nothing sent to herdr, current.json NOT written, session file still kept" || { echo "  FAIL owner=$own current=$cur"; fail=1; }
echo "── HERDR DOWN at SessionStart: gate must not cache"; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f "$T/fake.sock"
run down '{"hook_event_name":"SessionStart","session_id":"s-down"}'
own=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pane_owner"])' "$T/down/omarchy/claude-lifecycle/s-down.json")
[ "$own" = None ] && echo "  ok   owner=None (undetermined, will retry next event)" || { echo "  FAIL owner=$own"; fail=1; }
rm -rf "$T"; echo "── gate: $([ $fail = 0 ] && echo PASS || echo FAIL)"; exit $fail
