#!/bin/sh
# startup 钩子：清掉上一次 server 会话遗留的观察者 PID 文件。
# 观察者进程本身自带超时必自灭；server 重启后 PID 可能被复用，这里只清文件记录。

set -u
RUNTIME_DIR="${HERDR_WATCHDOG_RUNTIME:-$HOME/.herdr/watchdog}"
mkdir -p "$RUNTIME_DIR"
# 只删 PID 文件；在跑的旧观察者最多再活一个超时周期（15 分钟），无害
rm -f "$RUNTIME_DIR"/watch-*.pid
exit 0
