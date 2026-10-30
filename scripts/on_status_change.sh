#!/bin/sh
# pane.agent_status_changed 事件钩子：agent 进入 working 时起一个有界后台观察者，
# 超时未变状态就先按机械判据确认它是不是还在动，再决定要不要叫醒派发主 pane。
#
# 设计约束（来自 herdr 插件文档）：
# - 插件必须保证后台进程随后台命令/pane 退出而终止 → 观察者自带超时，必然自灭
# - 事件没有 agent name，只有 pane_id → 反查 herdr agent list
# - 主 pane 从 dispatch-state.json 读（dispatch_check.py dispatch 时记录的 owner_pane）
#
# 判据分层（2026-10-30 教训：ELAPSED 单独出现是假阳性，误报过正在干活的 agent）：
# - 机械层（本脚本 + stall_evidence.py）：worktree 有无写入、HEAD 有无推进、agent
#   transcript 是否还在长。任一面在动 = PROGRESSING = 不叫人。
# - 人审层（收到通知的主 agent）：零文件改动 + 文件 mtime 冻结在 checkout 那一刻 +
#   context 接近满，三条同时成立才算卡死。脚本只报证据，不下「卡死」结论。

set -u

STATE_FILE="${HERDR_WATCHDOG_STATE:-$HOME/.herdr/dispatch-state.json}"
OVERDUE_MS="${HERDR_WATCHDOG_OVERDUE_MS:-900000}"   # 15 分钟，与 dispatch_check.py OVERDUE_MINUTES 对齐
ROUNDS_MAX="${HERDR_WATCHDOG_ROUNDS:-12}"           # 轮数上限
MAX_TOTAL_S="${HERDR_WATCHDOG_MAX_SECONDS:-14400}"  # 总墙钟上限 4 小时；观察者必然自灭
RUNTIME_DIR="${HERDR_WATCHDOG_RUNTIME:-$HOME/.herdr/watchdog}"
LOG="$RUNTIME_DIR/watchdog.log"
PY="${HERDR_WATCHDOG_PYTHON:-/usr/bin/python3}"
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
EVIDENCE_PY="$PLUGIN_DIR/scripts/stall_evidence.py"

mkdir -p "$RUNTIME_DIR"

log() { echo "$(date +%s) $*" >> "$LOG"; }

EVENT_JSON="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$EVENT_JSON" ] || exit 0

# 只关心进入 working
STATUS=$(printf '%s' "$EVENT_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("agent_status",""))' 2>/dev/null || echo "")
[ "$STATUS" = "working" ] || exit 0
PANE_ID=$(printf '%s' "$EVENT_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("pane_id",""))' 2>/dev/null || echo "")
[ -n "$PANE_ID" ] || exit 0

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"

# 哪个 agent 在这个 pane 上 + 它是不是被派出的子 agent（主 pane 是谁）。
# 一次 herdr agent list + 一次读 state 同时定：事件里只有 pane_id，没有 name。
read -r AGENT_TARGET MAIN_PANE <<EOF
$(printf '%s' "$EVENT_JSON" | "$PY" -c '
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

# 后台观察者：循环 = 有界 wait + 证据判据。每一轮最多等 WAIT_MS，状态一变就退出。
(
    ARM_EPOCH=$(date +%s)
    ROUND=1
    WAIT_MS="$OVERDUE_MS"
    while [ "$ROUND" -le "$ROUNDS_MAX" ]; do
        if [ $(( $(date +%s) - ARM_EPOCH )) -ge "$MAX_TOTAL_S" ]; then
            log "$AGENT_TARGET watcher hit max wall clock (${MAX_TOTAL_S}s), stop"
            break
        fi
        "$HERDR_BIN" agent wait "$AGENT_TARGET" --until idle --until done --until blocked --timeout "$WAIT_MS" >/dev/null 2>&1
        RC=$?
        if [ "$RC" -eq 0 ]; then
            log "$AGENT_TARGET status changed in time, ok (round ${ROUND})"
            break
        fi

        # 双重确认：状态真还停在 working
        STILL=$("$HERDR_BIN" agent list 2>/dev/null | "$PY" -c '
import json,sys
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
    a = next((x for x in d.get("result",{}).get("agents",[]) if x.get("name")==name or x.get("pane_id")==name), None)
    print(a.get("agent_status","") if a else "")
except Exception:
    print("")
' "$AGENT_TARGET")
        if [ "$STILL" != "working" ]; then
            log "$AGENT_TARGET left working before overdue (now ${STILL}), no action"
            break
        fi

        # 机械判据：这段时间它到底有没有动
        EVIDENCE_OUT=$("$PY" "$EVIDENCE_PY" --agent "$AGENT_TARGET" --pane "$PANE_ID" \
            --state "$STATE_FILE" --since "$ARM_EPOCH" --herdr "$HERDR_BIN" 2>/dev/null)
        VERDICT=$(printf '%s\n' "$EVIDENCE_OUT" | sed -n 's/^VERDICT=//p')
        WHY=$(printf '%s\n' "$EVIDENCE_OUT" | sed -n 's/^EVIDENCE=//p')
        SUMMARY=$(printf '%s\n' "$EVIDENCE_OUT" | sed -n 's/^SUMMARY=//p')
        QUIET_MIN=$((WAIT_MS / 60000))

        case "$VERDICT" in
            PROGRESSING)
                # 还在动：不叫人，继续挂同一轮的观察（不升等待时间）。
                log "$AGENT_TARGET overdue but moving (${WHY}), keep watching"
                ROUND=$((ROUND + 1))
                continue
                ;;
            QUIET|UNKNOWN)
                if [ "$VERDICT" = "QUIET" ]; then
                    HEADLINE="机械判据两条都静了：${WHY}"
                else
                    HEADLINE="机械判据判不了：${WHY}"
                fi
                log "$AGENT_TARGET quiet (${VERDICT}) after ${WAIT_MS}ms, prompting main pane ${MAIN_PANE}: ${WHY}"
                "$HERDR_BIN" agent prompt "$MAIN_PANE" "[herdr-watchdog] 派出的 agent「${AGENT_TARGET}」working 超过 ${QUIET_MIN} 分钟没状态迁移，${HEADLINE}。观测：${SUMMARY}
时间和「状态没变」都不构成卡死证据——长思考、长构建、大文件生成同样不改状态。真卡死要三条同时成立：零文件改动 + 文件 mtime 冻结在 checkout 那一刻 + context 接近满。
请只读核对现场：herdr agent read ${AGENT_TARGET}（Elapsed 是否不涨、是否停在一条等输入的交互式 git 命令、context 百分比）。三条不全部成立就别打断，继续等；三条都成立才 send-keys ${AGENT_TARGET} esc esc c-c 打断，空闲后 send --file 给明确解法。处理完这条消息可以继续之前的工作。" >/dev/null 2>&1 \
                    && log "$AGENT_TARGET prompt sent to $MAIN_PANE" \
                    || log "$AGENT_TARGET prompt FAILED to $MAIN_PANE"
                # 已经叫过一次还静着：下一轮把等待时间翻倍再问，避免每 15 分钟喊一次
                WAIT_MS=$((WAIT_MS * 2))
                ;;
            *)
                log "$AGENT_TARGET evidence unreadable (verdict='${VERDICT}'), no prompt"
                break
                ;;
        esac
        ROUND=$((ROUND + 1))
    done
    rm -f "$PIDFILE"
) >/dev/null 2>&1 &
echo $! > "$PIDFILE"
log "watcher armed for $AGENT_TARGET (pid $(cat "$PIDFILE")), main pane $MAIN_PANE, timeout ${OVERDUE_MS}ms"
exit 0
