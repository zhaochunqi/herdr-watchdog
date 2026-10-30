#!/usr/bin/env python3
"""机械判据：这个还在 `working` 的 agent，这段时间到底有没有在动。

为什么需要它：`ELAPSED` 单独出现是假阳性来源。agent 状态只在「working / idle /
blocked」之间迁移，35 分钟的思考、一次长构建、一个大文件生成都能让状态一动不动
而活干得好好的。只按时间开火，就会在人家正要收尾时把人打断。

能机械测的只有「有没有动」，两处观测面：

1. worktree 里有没有文件被写过（排除 `.git`；HEAD 推进也算动）
2. agent 自己的 transcript（pi 的 session jsonl）有没有在长

两处都静下来，才是真静。第三条约等于人读的判据——context 接近满——读不到，留给
收到通知的主 agent 对着终端确认，本脚本不假装能判它。

输出（键值行，供 shell 解析）::

    VERDICT=PROGRESSING|QUIET|UNKNOWN
    EVIDENCE=<一句话说的是哪个观测面在动 / 为什么判不了>
    SUMMARY=<一行观测面数字，可直接进通知文本>
    QUIET_S=<自 watch 起点起静了多久>
    WORKTREE=<路径>
    WORKTREE_WRITE_AGE_S=<最近一次写入距今>
    TRANSCRIPT=<jsonl 路径>
    TRANSCRIPT_AGE_S=<最近一次写入距今>
    HEAD_AGE_S=<最近一次 commit 距今>

PROGRESSING = 别打断；QUIET = 机械判据两条都成立，可以叫人深查；UNKNOWN = 读不到
transcript 之类，判不了，叫人也要说明判不了。
"""

import argparse
import json
import os
import subprocess
import sys
import time

# 观察起点回退几秒：watch 线程刚起时上一轮收尾的写入不该算成「还在动」。
GRACE_S = 90
# 单次遍历的硬上限，防止在一个巨型 worktree 上把自己挂住。
MAX_ENTRIES = 200000


def agent_entry(payload, name, pane):
    """从 `herdr agent list` 的 JSON 里取这个 agent 的记录。纯函数。"""
    try:
        agents = json.loads(payload).get("result", {}).get("agents") or []
    except (ValueError, AttributeError):
        return None
    for agent in agents:
        if name and agent.get("name") == name:
            return agent
        if not name and pane and agent.get("pane_id") == pane:
            return agent
    for agent in agents:
        if pane and agent.get("pane_id") == pane:
            return agent
    return None


def transcript_path(agent):
    """agent 的 transcript 路径。pi 是 session jsonl；别的 kind 可能没有。纯函数。"""
    session = (agent or {}).get("agent_session") or {}
    if session.get("kind") == "path":
        return session.get("value") or None
    return None


def dispatch_entry(state, name, pane):
    """dispatch-state.json 里这个 agent 的记录；pane 对不上就不认。纯函数。"""
    entry = (state.get("agents") or {}).get(name)
    if not isinstance(entry, dict):
        return None
    if pane and entry.get("pane") and entry.get("pane") != pane:
        return None
    return entry


def newest_write(root, cutoff):
    """root 下 cutoff 之后被写过的最新文件。返回 (mtime, path) 或 None。纯函数。

    只关心「有没有动」，所以一旦命中就返回，不扫完整个树。`.git` 剪掉：herdr 和 git
    自己的记账不该被算成 agent 在干活。
    """
    newest = None
    seen = 0
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            handle = os.scandir(current)
        except OSError:
            continue
        try:
            for item in handle:
                seen += 1
                if seen > MAX_ENTRIES:
                    return newest
                try:
                    if item.is_dir(follow_symlinks=False):
                        if item.name != ".git":
                            stack.append(item.path)
                        continue
                    mtime = item.stat(follow_symlinks=False).st_mtime
                except OSError:
                    continue
                if mtime > cutoff and (newest is None or mtime > newest[0]):
                    newest = (mtime, item.path)
        finally:
            handle.close()
    return newest


def mtime_or_none(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def head_commit_time(worktree):
    """worktree 的 HEAD commit 时间；不是 git 仓或出错都返回 None。纯函数。"""
    try:
        out = subprocess.run(
            ["git", "-C", worktree, "log", "-1", "--format=%ct"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return float(out.stdout.strip())
    except ValueError:
        return None


def age(now, timestamp):
    """距今多少秒，读不到就是「—」。纯函数。"""
    if timestamp is None:
        return "—"
    return f"{int(max(0, now - timestamp))}s 前"


def summary(now, worktree_write, transcript_time, head_time):
    """一行观测面数字，直接进通知文本。纯函数。"""
    worktree_age = age(now, worktree_write[0] if worktree_write else None)
    return (
        f"worktree 最近写入 {worktree_age}；transcript 最近写入 {age(now, transcript_time)}；"
        f"HEAD {age(now, head_time)}"
    )


def judge(now, cutoff, worktree_write, head_time, transcript_time, transcript_known):
    """把观测面折成 VERDICT。纯函数，返回值是 (verdict, evidence)。"""
    if worktree_write is not None and worktree_write[0] > cutoff:
        age = int(now - worktree_write[0])
        return "PROGRESSING", f"worktree 有写入 {worktree_write[1]}（{age}s 前）"
    if head_time is not None and head_time > cutoff:
        return "PROGRESSING", f"HEAD 有新 commit（{int(now - head_time)}s 前）"
    if transcript_time is not None and transcript_time > cutoff:
        return "PROGRESSING", f"transcript 还在长（{int(now - transcript_time)}s 前）"
    if not transcript_known:
        return "UNKNOWN", "读不到 agent transcript（非 pi 或 session 路径缺失），只有 worktree 一面观测"
    return "QUIET", "worktree 无写入、HEAD 未推进、transcript 不涨"


def main(argv):
    parser = argparse.ArgumentParser(description="给 working 的 agent 判有没有在动")
    parser.add_argument("--agent", default="", help="agent 名（list 里的 name）")
    parser.add_argument("--pane", default="", help="pane id，agent 名对不上时用它")
    parser.add_argument("--state", default=os.path.expanduser("~/.herdr/dispatch-state.json"))
    parser.add_argument("--since", type=float, default=None, help="watch 起点 epoch；默认 15 分钟前")
    parser.add_argument("--herdr", default=os.environ.get("HERDR_BIN_PATH", "herdr"))
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args(argv)

    now = time.time()
    since = args.since if args.since is not None else now - 900
    cutoff = since - GRACE_S

    try:
        payload = subprocess.run(
            [args.herdr, "agent", "list"],
            capture_output=True,
            text=True,
            timeout=args.timeout,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        print("VERDICT=UNKNOWN")
        print(f"EVIDENCE=herdr agent list 失败（{exc}），判不了")
        return 0

    agent = agent_entry(payload, args.agent, args.pane)
    try:
        with open(args.state) as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        state = {}
    entry = dispatch_entry(state, args.agent, args.pane)

    worktree = ""
    if entry:
        worktree = entry.get("worktree") or ""
    if not worktree and agent:
        worktree = agent.get("cwd") or ""

    worktree_write = newest_write(worktree, cutoff) if worktree and os.path.isdir(worktree) else None
    head_time = head_commit_time(worktree) if worktree and os.path.isdir(worktree) else None

    transcript = transcript_path(agent)
    transcript_time = mtime_or_none(transcript) if transcript else None
    if transcript is None and agent:
        # 没给路径但可能给了 session id：不猜，按「读不到」处理。
        transcript_known = False
    else:
        transcript_known = transcript is not None and transcript_time is not None

    verdict, evidence = judge(now, cutoff, worktree_write, head_time, transcript_time, transcript_known)

    print(f"VERDICT={verdict}")
    print(f"EVIDENCE={evidence}")
    print(f"SUMMARY={summary(now, worktree_write, transcript_time, head_time)}")
    print(f"QUIET_S={int(max(0, now - since))}")
    print(f"WORKTREE={worktree}")
    if worktree_write is not None:
        print(f"WORKTREE_WRITE_AGE_S={int(now - worktree_write[0])}")
    print(f"TRANSCRIPT={transcript or ''}")
    if transcript_time is not None:
        print(f"TRANSCRIPT_AGE_S={int(now - transcript_time)}")
    if head_time is not None:
        print(f"HEAD_AGE_S={int(now - head_time)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
