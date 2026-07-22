# herdr ≥ 0.7.5 live-agent CLI facade — facts herd.nvim relies on

Live-verified 2026-07-22 against herdr 0.7.5. The plugin's spawn/send/watch
paths are built on these; re-verify before touching them.

- `agent start <name> --kind <kind> --pane <id> [-- native-args]` starts a
  validated agent kind in an EXISTING pane at a shell prompt, after a
  server-side readiness handshake. It cannot run arbitrary commands, create
  topology, or set cwd/env — those belong to `tab create`
  (`--cwd/--env/--label/--workspace/--no-focus`, response carries
  `result.tab.tab_id` + `result.root_pane.pane_id`).
- The agent runs inside the pane's shell: **on agent exit the pane SURVIVES**
  at a shell prompt and the tab is never auto-reaped. This is why
  bin/herd-run.sh (in-pane pre-death focus check) was deleted — post-exit the
  pane's `focused` flag still answers "was the user looking at it", so
  lua/herd/watch.lua owns the whole return-and-reap now.
- `agent wait <pane> --until unknown` is the exit-detection idiom:
  blocks while the agent lives; agent exits → rc 1 + `agent_not_running`;
  no agent in the pane → rc 1 + `agent_not_found` (immediately); a transient
  `unknown` state match → rc 0 (re-arm). Plain `agent wait` (no --until)
  matches idle/done/blocked and returns instantly on an idle agent — useless
  for exit detection.
- Agent commands target a unique live agent NAME or the hosting PANE ID only;
  names are cleared when the occupant exits. Removed commands: `agent send`
  (literal text is `pane send-text <pane> <text>`; `agent send-keys` takes
  key names like `ctrl+c`, `esc`, `enter`), top-level `wait output`
  (→ `pane wait-output`).
- `tab create --env K=V` reaches the pane shell and everything `agent start`
  launches in it (verified with a nushell `$env` probe — note POSIX
  `$VAR`-style probes silently fail in nushell panes).
- New atomic `agent prompt <target> <text> [--wait --until <state>]` exists —
  candidate for replacing round-trip polling someday.
- Still true from the 0.7.4 era (kept from the retired
  herdr-tab-removal-on-pane-death.md): there is NO focus-history API
  (`herdr api` = snapshot/schema only) — any "where was the user before"
  question must be answered from live `focused` flags at decision time.
