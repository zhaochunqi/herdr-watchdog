# herdr-watchdog

A [herdr](https://herdr.dev) native plugin that closes the last gap in fire-and-forget
dispatch: **the main agent can't check heartbeats while it is idle**, because pi and
other coding agents only wake on input. If a dispatched child agent wedges
(interactive rebase, refused ask, screen-watching a dead prompt), nobody notices
until the user looks.

## How it works

Event-driven, no polling:

1. `[[events]] on = "pane.agent_status_changed"` fires when any agent enters a state.
2. On `working`, the hook reads `~/.herdr/dispatch-state.json` (written by
   [herdr-dispatch](https://github.com/zhaochunqi/skills)'s `dispatch_check.py dispatch`,
   which records each child's pane and the dispatching main pane as `owner_pane`).
   Only dispatched children get a watcher.
3. The watcher runs `herdr agent wait --until idle --until done --until blocked
   --timeout 900000` (15 min, same threshold as `dispatch_check.py list`).
   - Status changes in time → exit, log, done.
   - Timeout → double-check `herdr agent list` still says `working` →
     `herdr agent prompt <owner_pane> "[herdr-watchdog] …"` injects heartbeat
     deep-check instructions into the main agent's session.

Works for every agent kind herdr manages (pi, opencode, kimi, cline, …), not just pi.

## Install

```bash
herdr plugin link /path/to/this/repo        # local authoring
herdr plugin install zhaochunqi/herdr-watchdog   # from GitHub
```

## Tuning

| Env | Default | Meaning |
| --- | --- | --- |
| `HERDR_WATCHDOG_OVERDUE_MS` | `900000` | watcher timeout (keep in sync with dispatch_check.py `OVERDUE_MINUTES`) |
| `HERDR_WATCHDOG_STATE` | `~/.herdr/dispatch-state.json` | dispatch state file |
| `HERDR_WATCHDOG_RUNTIME` | `~/.herdr/watchdog` | PID files and log |

Log: `~/.herdr/watchdog/watchdog.log`. Server-side command log: `herdr plugin log list`.

## Guarantees

- **Only dispatched children are watched**: agents not in the dispatch state file are skipped.
- **One watcher per child**: PID file dedup; a second `working` event for the same
  agent doesn't spawn another watcher.
- **Watchers always die**: they are bounded by `agent wait --timeout`; the startup hook
  (`cleanup_stale.sh`) clears PID files after a server restart. No daemon.
- **Double confirmation before prompting**: timeout alone isn't enough — the agent must
  still be `working` in a fresh `herdr agent list`.

## Contract with herdr-dispatch

`dispatch_check.py dispatch` writes `owner_pane` into the agent's entry in
`~/.herdr/dispatch-state.json` (resolved via cwd → agent list → `HERDR_PANE_ID`
fallback). This plugin reads it to know where to inject. If `owner_pane` is absent
(dispatched by an agent outside herdr), the child is not watched.

## Known quirk

macOS `/bin/sh` (bash 3.2) under `set -u` merges a non-ASCII byte following `$VAR`
into the variable name (`$AGENT_TARGET」` → variable `AGENT_TARGET」`), so all variables
adjacent to CJK text use `${VAR}` braces. Keep that convention when editing the scripts.
