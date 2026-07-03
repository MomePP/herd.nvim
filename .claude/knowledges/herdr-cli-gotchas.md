# herdr CLI gotchas (verified live against 0.7.1, 2026-07-02/03)

Facts the native round-trip work established empirically. Re-verify against
release notes on major herdr upgrades — several are undocumented behavior.

## State discovery

- `pane list` / `tab list` mark **exactly one** entry `focused:true`
  globally. A detached script (herd-return) can always answer "where am I"
  from a plain list call — no env vars, no client context needed.
- `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_ENV=1`,
  `HERDR_SOCKET_PATH` are set on every pane herdr spawns.
- Pane `cwd` is the **spawn** cwd (static); `foreground_cwd` tracks the
  live foreground process. Match on `cwd` for origin resolution.

## Focus semantics

- `agent focus <pane_id>` switches the visible tab AND flips the focused
  workspace when the agent lives elsewhere — behaviorally identical to
  `tab focus <tab_id>` (gate-probed cross-workspace before we switched).
- `tab focus <id>` is a real state change (updates `active_tab_id`), not
  just a sidebar highlight.

## Hard limits

- **No CLI primitive triggers a keybind action.** A `[[keys.command]]`
  script cannot re-dispatch the key's shadowed default; the only honest
  fallback is notify + no-op.
- `pane focus` is directional-only (`--direction left|right|up|down`) —
  there is no focus-pane-by-id. Jumping to a pane means focusing its tab
  (or `agent focus` for agent panes).

## Keybinding config

- `[[keys.command]]` entries must come after all plain `key = value` pairs
  of `[keys]` (TOML array-of-tables ends the parent's inline keys).
- `key = 'prefix+\'` parses and works despite backslash being absent from
  the documented punctuation list (reload-config: zero diagnostics; keypress
  verified live). Use a TOML literal string to avoid escaping.
- A `[[keys.command]]` binding shadows the herdr default on that chord on
  EVERY tab (e.g. `prefix+s` would shadow `settings`).

## Shelling out from Lua (herd's own client code)

- `vim.system():wait()` **throws synchronously** when the binary can't be
  spawned (ENOENT) — wrap in `pcall` anywhere a stack trace is unacceptable
  (keybind scripts). A non-zero exit does NOT throw; only spawn failure.
- `vim.json.decode('null')` succeeds and returns `vim.NIL` (userdata);
  indexing it throws. Guard with `type(decoded) == 'table'` before
  `.result`. (`Herdr.api` in lua/herd/herdr.lua still has the unguarded
  pattern — known deferred hardening from the final branch review, along
  with a missing `vim.system` timeout in bin/herd-return.lua.)
- `agent read <pane> --source visible --format text` returns the JSON
  envelope `result.read.text`, not raw text on stdout.
