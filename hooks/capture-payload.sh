#!/bin/sh
# Records the raw hook payload for fixtures. Silent on stdout; exit 0.
set -u; d="${CLAUDE_LIFECYCLE_CAPTURE_DIR:-/tmp/claude-lifecycle-capture}"; mkdir -p "$d" 2>/dev/null || exit 0
input=$(cat 2>/dev/null || true); [ -n "$input" ] || exit 0
ev=$(printf '%s' "$input" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("hook_event_name","unknown"))' 2>/dev/null || echo unknown)
printf '%s\n' "$input" >"$d/$ev.$(date +%s%N).json" 2>/dev/null; exit 0
