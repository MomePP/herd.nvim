# herdr 0.7.5 CLI breakage audit (2026-07-22)

herdr 0.7.5 (brew, released 2026-07-21) replaced the agent CLI with a
"live-agent facade". Verified against the installed binary's `--help` output
and `/opt/homebrew/Cellar/herdr/0.7.5/CHANGELOG.md`.

## Broken call sites

### 1. `agent start` — fully redesigned (the reported `unknown option: --cwd`)

Old (what the plugin sends):

    agent start <name> --cwd <cwd> --no-focus [--tab <id>|--workspace <id>]
                [--env K=V]... -- <def.cmd...>

New (0.7.5):

    agent start <NAME> --kind <KIND> --pane <ID> [--timeout <MS>] [-- AGENT_ARG...]

- No longer creates topology: it starts a *known agent kind* in an **existing
  pane sitting at a shell prompt** and runs the kind's canonical executable
  itself. `--cwd/--no-focus/--tab/--workspace/--env` and the arbitrary
  command after `--` are gone (only native agent args survive after `--`).
- `--kind` values: pi, claude, codex, gemini, cursor, devin, agy, cline, omp,
  mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo,
  qodercli, maki.
- Affects `start_args` (lua/herd/herdr.lua:173), `M.spawn` (:195),
  `M.spawn_native` (:293).

Migration shape:

1. `tab create --workspace <ws> --cwd <cwd> --label <label> --no-focus
   [--env K=V]...` — `tab create` (and `workspace create`) now accept
   `--cwd`/`--env`, so cwd+env move here.
2. Reuse the returned `root_pane` as the agent's pane:
   `agent start <name> --kind <kind> --pane <root_pane_id> -- <extra args>`.
3. The spare-pane close dance (herdr.lua:204-215, :301-308) inverts: the tab's
   initial pane IS the agent pane now; nothing to close.
4. herd.Tool needs a `kind` (or derive from `cmd[1]`); `def.cmd` can no longer
   be an arbitrary argv.

Open design question: the bin/herd-run.sh auto-return wrapper can't be
launched via `agent start` anymore (it runs the canonical executable, not a
wrapper). Options: `pane run <pane> <wrapper...>` + agent detection with the
new `HERDR_AGENT=<agent>` env hint (0.7.5, macOS) — env set via
`tab create --env`; or drop the wrapper and rebuild auto-return on
`agent wait`/`pane wait-output`.

### 2. top-level `wait output` — removed

`herdr wait output <pane> --match X --timeout N` (lua/herd/watch.lua:62) →
`herdr pane wait-output <PANE_ID> --match <TEXT> --timeout <MS>`
(also supports `--regex/--source/--lines/--raw`). Re-verify the error tokens
watch.lua matches on (`pane_not_found`, `timed out`) against the new command.

### 3. `agent send` — removed

`agent send <target> <text>` (M.agent_send, lua/herd/herdr.lua:341, called
from init.lua:202) is gone. `agent send-keys` sends *key presses*, not text.
For literal text without Enter (review-then-submit), use
`pane send-text <PANE_ID> <TEXT>` — plugin already targets pane_id.
If submit-and-track is ever wanted: new atomic
`agent prompt <TARGET> <TEXT> [--wait --until <state> --timeout <ms>]`.

## Tightened semantics (currently compatible)

- Agent commands accept only a unique live agent name or the hosting pane ID;
  names are cleared when the occupant exits/is replaced. Plugin already
  prefers pane ids for attach/focus/read/send — fine.
- `agent start` validates a "strict agent name"; `claude`, `claude_2` style
  names from `next_name` should pass.

## Verified unaffected

`agent list`, `agent read <pane> --source visible --format text --lines N`
(note: default source is now `recent`; new `detection` source),
`agent attach <target> [--takeover]`, `agent focus`, `workspace
create/list/focus`, `tab create/get/list/close`, `pane list --workspace`,
`pane close <id>`.

## Possibly useful new surface

- `agent prompt --wait --until idle|working|blocked|done` + server-owned
  `agent wait` (returns `agent_not_running` promptly when the pane dies) —
  could replace round-trip polling.
- `pane run <PANE_ID> <COMMAND>...`, `pane send-keys`, `pane wait-output`.
- CLI now returns machine-readable `protocol_mismatch` when client/server
  versions differ — worth surfacing in Herdr.api error handling.
- 0.7.5 breaking change on herdr-side plugins (global, not per-session) does
  not affect herd.nvim.
