#!/bin/sh
# pane.agent_status_changed 事件钩子：agent 进入 working 时起一个有界后台观察者，
# 超时未变状态就向 dispatch-state.json 里记录的主 pane 注入 heartbeat 深查指令。
#
# 设计约束（来自 herdr 插件文档）：
# - 插件必须保证后台进程随后台命令/pane 退出而终止 → 观察者自带超时，必然自灭
# - 事件没有 agent name，只有 pane_id → 反查 herdr agent list
# - 主 pane 从 dispatch-state.json 读（dispatch_check.py dispatch 时记录的 owner_pane）

set -u

STATE_FILE="${HERDR_WATCHDOG_STATE:-$HOME/.herdr/dispatch-state.json}"
OVERDUE_MS="${HERDR_WATCHDOG_OVERDUE_MS:-900000}"   # 15 分钟，与 dispatch_check.py OVERDUE_MINUTES 对齐
RUNTIME_DIR="${HERDR_WATCHDOG_RUNTIME:-$HOME/.herdr/watchdog}"
LOG="$RUNTIME_DIR/watchdog.log"

mkdir -p "$RUNTIME_DIR"

log() { echo "$(date +%s) $*" >> "$LOG"; }

EVENT_JSON="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$EVENT_JSON" ] || exit 0

# 只关心进入 working
STATUS=$(printf '%s' "$EVENT_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("agent_status",""))' 2>/dev/null || echo "")
[ "$STATUS" = "working" ] || exit 0
PANE_ID=$(printf '%s' "$EVENT_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("pane_id",""))' 2>/dev/null || echo "")
[ -n "$PANE_ID" ] || exit 0

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"

# 哪个 agent 在这个 pane 上 + 它是不是被派出的子 agent（主 pane 是谁）。
# 一次 herdr agent list + 一次读 state 同时定：事件里只有 pane_id，没有 name。
read -r AGENT_TARGET MAIN_PANE <<EOF
$(printf '%s' "$EVENT_JSON" | /usr/bin/python3 -c '
import json, subprocess, os, sys

event = json.load(sys.stdin)
pane = event.get("data", {}).get("pane_id", "")
herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
state_file = os.environ.get("HERDR_WATCHDOG_STATE", os.path.expanduser("~/.herdr/dispatch-state.json"))

try:
    listing = json.loads(subprocess.run([herdr, "agent", "list"], capture_output=True, text=True, timeout=15).stdout)
    agents = listing.get("result", {}).get("agents", [])
except Exception:
    agents = []
mine = next((a for a in agents if a.get("pane_id") == pane), None)
if not mine:
    sys.exit(0)
name = mine.get("name") or pane

try:
    with open(state_file) as f:
        entries = json.load(f).get("agents", {})
except Exception:
    entries = {}
entry = entries.get(name) if isinstance(entries.get(name), dict) else None
owner = ""
if entry and entry.get("pane") == pane and entry.get("owner_pane") and entry.get("owner_pane") != pane:
    owner = entry["owner_pane"]
print(name, owner)
' "$EVENT_JSON")
EOF

if [ -z "${MAIN_PANE:-}" ]; then
    log "$AGENT_TARGET not a dispatched child, skip"
    exit 0
fi

# 防重复：同 agent 已有观察者在跑就跳过
PIDFILE="$RUNTIME_DIR/watch-$AGENT_TARGET.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "$AGENT_TARGET watcher already running (pid $(cat "$PIDFILE"))"
    exit 0
fi

# 后台观察者：agent wait --timeout OVERDUE_MS。退出码 0 = 状态变了；非 0（超时）= 疑似卡死。
(
    "$HERDR_BIN" agent wait "$AGENT_TARGET" --until idle --until done --until blocked --timeout "$OVERDUE_MS" >/dev/null 2>&1
    RC=$?
    rm -f "$PIDFILE"
    if [ $RC -ne 0 ]; then
        log "$AGENT_TARGET stuck: wait timeout rc=$RC"
        # 双重确认：真卡死时 agent 仍是 working
        STILL=$("$HERDR_BIN" agent list 2>/dev/null | /usr/bin/python3 -c '
import json,sys
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
    a = next((x for x in d.get("result",{}).get("agents",[]) if x.get("name")==name or x.get("pane_id")==name), None)
    print(a.get("agent_status","") if a else "")
except Exception:
    print("")
' "$AGENT_TARGET")
        if [ "$STILL" = "working" ]; then
            log "$AGENT_TARGET confirmed working past overdue, prompting main pane $MAIN_PANE"
            "$HERDR_BIN" agent prompt "$MAIN_PANE" "[herdr-watchdog] 派出的 agent「${AGENT_TARGET}」已 working 超过 $((OVERDUE_MS/60000)) 分钟没变状态，疑似卡死。请跑 dispatch_check.py list 确认 OVERDUE_AGENT=，然后按 heartbeat 流程深查：worktree git status 是否推进 + herdr agent read ${AGENT_TARGET} 的 Elapsed；零改动且不涨就 send-keys esc esc c-c 打断，send --file 给明确解法。处理完这条消息可以继续之前的工作。" >/dev/null 2>&1 \
                && log "$AGENT_TARGET prompt sent to $MAIN_PANE" \
                || log "$AGENT_TARGET prompt FAILED to $MAIN_PANE"
        else
            log "$AGENT_TARGET left working before overdue (now $STILL), no action"
        fi
    else
        log "$AGENT_TARGET status changed in time, ok"
    fi
) >/dev/null 2>&1 &
echo $! > "$PIDFILE"
log "watcher armed for $AGENT_TARGET (pid $(cat "$PIDFILE")), main pane $MAIN_PANE, timeout ${OVERDUE_MS}ms"
exit 0
