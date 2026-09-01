#!/usr/bin/env python3
"""claude-lifecycle reporter — Claude Code hook (JSON on stdin) → herdr pane state + Omarchy state file.
CONTRACT.md §1: silent on stdout, exit 0 always, <100 ms, per-key monotonic seq. One process, no subshells."""
import json, os, socket, sys, time
REPORTER_VERSION = "0.1.0"
BLOCK_NOTIF = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}
WORKING = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "ElicitationResult", "PreCompact"}

def decide(h):
    ev = str(h.get("hook_event_name") or "")
    if h.get("agent_id"): return None                      # subagent hooks never speak for the pane
    if ev == "SessionStart": return "idle", "", []
    if ev in WORKING: return "working", "", []
    if ev == "PermissionRequest": return "blocked", "permission_request:" + str(h.get("tool_name") or ""), []
    if ev == "Elicitation": return "blocked", "elicitation", []
    if ev == "Notification":
        nt = str(h.get("notification_type") or "")
        return ("blocked", nt, []) if nt in BLOCK_NOTIF else None
    if ev == "Stop":
        bg = [t for t in (h.get("background_tasks") or []) if isinstance(t, dict)]
        return ("working" if bg else "idle"), "", bg
    if ev == "TaskCompleted": return "idle", "", []          # a task finished; Stop will re-assert if others remain
    if ev == "SessionEnd": return "release", "", []
    return None                                              # SubagentStop (#198) and unknown events: ignored

def main():
    raw = sys.stdin.read()
    if not raw.strip(): return
    try: h = json.loads(raw)
    except Exception: return
    d = decide(h)
    if not d: return
    state, reason, bg = d
    ev = str(h.get("hook_event_name") or ""); sid = str(h.get("session_id") or "unknown")
    pane = os.environ.get("HERDR_PANE_ID") or ""
    source = os.environ.get("CLAUDE_LIFECYCLE_SOURCE", "daocoding:claude")
    root = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "omarchy", "claude-lifecycle")
    os.makedirs(root, exist_ok=True)
    key = "".join(c if c.isalnum() or c in "_.-" else "_" for c in (pane or sid))
    seqf = os.path.join(root, ".seq-" + key); lock = seqf + ".lock"
    # ── lock (mkdir is atomic on every POSIX fs) + monotonic seq ──
    for _ in range(200):
        try: os.mkdir(lock); break
        except FileExistsError:
            try:
                pid = int(open(os.path.join(lock, "pid")).read() or 0); os.kill(pid, 0)
            except (ValueError, FileNotFoundError, ProcessLookupError):
                try: os.remove(os.path.join(lock, "pid"))
                except FileNotFoundError: pass
                try: os.rmdir(lock)
                except OSError: pass
            except PermissionError: pass
            time.sleep(0.005)
    else: return
    try:
        open(os.path.join(lock, "pid"), "w").write(str(os.getpid()))
        try: prev = int(open(seqf).read().strip() or 0)
        except (FileNotFoundError, ValueError): prev = 0
        seq = max(time.time_ns(), prev + 1)
        tmp = seqf + f".tmp.{os.getpid()}"; open(tmp, "w").write(str(seq)); os.replace(tmp, seqf)
        # ── consumer 3b: state file ──
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()); f = os.path.join(root, sid + ".json"); since = ts
        try:
            p = json.load(open(f))
            if p.get("state") == state: since = p.get("since") or ts
        except Exception: pass
        slim = [{k: t.get(k) for k in ("type", "status", "server", "tool", "agent_type", "name") if t.get(k) is not None} for t in bg]
        rec = {"contract_version": 1, "session_id": sid, "state": state, "since": since, "updated_at": ts, "pane_id": pane or None,
               "background_tasks": slim, "block_reason": reason or None, "last_event": ev,
               "claude_version": h.get("version") or None, "reporter_version": REPORTER_VERSION}
        for path in (f, os.path.join(root, "current.json")):
            tmp = path + f".tmp.{os.getpid()}"; open(tmp, "w").write(json.dumps(rec, separators=(",", ":"))); os.replace(tmp, path)
        if state == "release":
            try: os.remove(f)
            except FileNotFoundError: pass
    finally:
        try: os.remove(os.path.join(lock, "pid"))
        except FileNotFoundError: pass
        try: os.rmdir(lock)
        except OSError: pass
    # ── consumer 3a: herdr, only inside a herdr pane ──
    sock = os.environ.get("HERDR_SOCKET_PATH") or ""
    if os.environ.get("HERDR_ENV") != "1" or not pane or not sock: return
    if state == "release":
        req = {"id": f"{source}:{seq}", "method": "pane.release_agent", "params": {"pane_id": pane, "source": source, "agent": "claude"}}
    else:
        params = {"pane_id": pane, "source": source, "agent": "claude", "state": state, "seq": seq}
        if reason: params["message"] = reason
        req = {"id": f"{source}:{seq}", "method": "pane.report_agent", "params": params}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(0.5)
    try:
        s.connect(sock); s.sendall((json.dumps(req, separators=(",", ":")) + "\n").encode())
        try: resp = s.recv(4096)
        except Exception: resp = b""
        if os.environ.get("CLAUDE_LIFECYCLE_DEBUG") == "1": sys.stderr.write(f"claude-lifecycle: {ev} -> {state} seq={seq} pane={pane} resp={resp[:200]!r}\n")
    except Exception as e:
        if os.environ.get("CLAUDE_LIFECYCLE_DEBUG") == "1": sys.stderr.write(f"claude-lifecycle: socket error {e}\n")
    finally: s.close()

if __name__ == "__main__":
    try: main()
    except Exception as e:
        if os.environ.get("CLAUDE_LIFECYCLE_DEBUG") == "1": sys.stderr.write(f"claude-lifecycle: {e!r}\n")
    sys.exit(0)
