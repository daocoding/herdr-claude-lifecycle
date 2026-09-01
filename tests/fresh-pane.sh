#!/bin/sh
# herdr acceptance on a FRESH pane (no persisted owner): split <base>, row 0, synthetic live table, close.
# usage: tests/fresh-pane.sh <base_pane_id> [existing_pane_id]
# The interactive proof (a real `claude` in the pane driving herdr) is deliberately NOT automated here:
# launch claude normally in a herdr pane with the hooks installed and read `herdr pane get <id>` while it works.
set -u; BASE="${1:?base pane}"; R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); cd "$R"
export HERDR_SOCKET_PATH="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
if [ -n "${2:-}" ]; then NEW="$2"; else
  NEW=$(herdr pane split "$BASE" --direction down --no-focus --cwd "$HOME/Work" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
fi
[ -n "$NEW" ] || { echo "split failed"; exit 2; }; echo "fresh pane: $NEW"
echo "── row 0:"; herdr pane get "$NEW" 2>/dev/null | python3 -c 'import json,sys;p=json.load(sys.stdin)["result"]["pane"];print({k:p.get(k) for k in ("agent","agent_status","agent_session")})'
XDG_STATE_HOME=$(mktemp -d) sh tests/herdr-live.sh "$NEW"; rc=$?
[ -n "${2:-}" ] || { herdr pane close "$NEW" >/dev/null 2>&1 && echo "closed $NEW"; }
exit $rc
