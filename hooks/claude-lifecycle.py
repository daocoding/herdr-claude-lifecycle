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

def _stamp(root):
    try: return open(os.path.join(root, "claude_version")).read().strip() or None
    except Exception: return None

def _rpc(sock_path, method, params, timeout=0.5):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(timeout)
    try:
        s.connect(sock_path); s.sendall((json.dumps({"id": f"cl:{time.time_ns()}", "method": method, "params": params}, separators=(",", ":")) + "\n").encode())
        b = b""
        while not b.endswith(b"\n"):
            c = s.recv(65536)
            if not c: break
            b += c
        return json.loads(b) if b else None
    except Exception:
        return None
    finally: s.close()

def _ancestors(limit=8):
    """pids of this process's ancestors (parent first). Linux via /proc; macOS via ps."""
    out, pid = [], os.getppid()
    for _ in range(limit):
        if pid <= 1: break
        out.append(pid)
        try:
            with open(f"/proc/{pid}/stat") as f: pid = int(f.read().split(")")[-1].split()[1])
        except Exception:
            try:
                import subprocess
                pid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, timeout=0.3).stdout.strip() or 0)
            except Exception: break
    return out

def pane_owner_gate(sock_path, pane):
    """True/False = this hook's Claude is/isn't the pane's foreground process. None = herdr could not answer (do not cache)."""
    r = _rpc(sock_path, "pane.process_info", {"target": pane})
    info = ((r or {}).get("result") or {}).get("process_info") if r else None
    if not info: return None
    fg = {int(p.get("pid")) for p in (info.get("foreground_processes") or []) if p.get("pid") is not None}
    pgid = info.get("foreground_process_group_id")
    if pgid is not None:
        try:
            if os.getpgrp() == int(pgid): return True
        except Exception: pass
    return any(a in fg for a in _ancestors())

def main():
    raw = sys.stdin.read()
    if not raw.strip(): return
    cap = os.environ.get("CLAUDE_LIFECYCLE_CAPTURE_DIR")       # optional: harvest raw payloads from a real session
    if cap:
        try:
            os.makedirs(cap, exist_ok=True); open(os.path.join(cap, f"{time.time_ns()}.json"), "w").write(raw)
        except Exception: pass
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
        prev_rec = {}
        try:
            prev_rec = json.load(open(f))
            if prev_rec.get("state") == state: since = prev_rec.get("since") or ts
        except Exception: pass
        # ── pane-owner gate (herdr only): may this Claude speak for the pane? cached per session; None never cached ──
        sock = os.environ.get("HERDR_SOCKET_PATH") or ""
        in_herdr = os.environ.get("HERDR_ENV") == "1" and bool(pane) and bool(sock)
        owner = prev_rec.get("pane_owner") if isinstance(prev_rec.get("pane_owner"), bool) else None
        if in_herdr and owner is None and os.environ.get("CLAUDE_LIFECYCLE_SKIP_GATE") != "1":
            owner = pane_owner_gate(sock, pane)
        if in_herdr and os.environ.get("CLAUDE_LIFECYCLE_SKIP_GATE") == "1": owner = True
        slim = [{k: t.get(k) for k in ("type", "status", "server", "tool", "agent_type", "name") if t.get(k) is not None} for t in bg]
        rec = {"contract_version": 1, "session_id": sid, "state": state, "since": since, "updated_at": ts, "pane_id": pane or None,
               "pane_owner": owner, "background_tasks": slim, "block_reason": reason or None, "last_event": ev,
               "claude_version": h.get("version") or _stamp(root), "reporter_version": REPORTER_VERSION}
        # current.json = "the" Claude the bar shows: never let a non-owning session inside herdr (e.g. a `claude -p` from a pane shell) overwrite it
        targets = [f] + ([] if (in_herdr and owner is not True) else [os.path.join(root, "current.json")])
        for path in targets:
            tmp = path + f".tmp.{os.getpid()}"; open(tmp, "w").write(json.dumps(rec, separators=(",", ":"))); os.replace(tmp, path)
        if state == "release":
            try: os.remove(f)
            except FileNotFoundError: pass
    finally:
        try: os.remove(os.path.join(lock, "pid"))
        except FileNotFoundError: pass
        try: os.rmdir(lock)
        except OSError: pass
    # ── consumer 3a: herdr, only inside a herdr pane AND only if this Claude is the pane's foreground process ──
    if not in_herdr: return
    if owner is not True:
        if os.environ.get("CLAUDE_LIFECYCLE_DEBUG") == "1": sys.stderr.write(f"claude-lifecycle: {ev} not reported to herdr (pane_owner={owner})\n")
        return
    if ev == "SessionStart" and sid != "unknown":
        _rpc(sock, "pane.report_agent_session", {"pane_id": pane, "source": source, "agent": "claude", "seq": seq,
                                                  "agent_session_id": sid, "session_start_source": str(h.get("source") or "startup")})
    if state == "release":
        req = {"id": f"{source}:{seq}", "method": "pane.release_agent", "params": {"pane_id": pane, "source": source, "agent": "claude", "seq": seq}}  # seq: herdr's ordering guard drops a seq-less release as stale
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
