# herd.nvim — nvim-host float manager over a herdr backend

## Premise

Today herd.nvim is a **spawner for a herdr-hosted layout**: nvim lives in one
herdr pane, CLI agents (`claude`, `opencode`, …) live in *sibling herdr panes*,
and "fullscreen" means `herdr pane zoom`. Navigation between nvim and an agent
belongs to herdr (`Ctrl-a h/l`). The README's own FAQ documents the cost of
this: once an agent pane is focused, `<leader>` no longer reaches nvim, so the
round-trip is asymmetric and you must context-switch between two keybind
worlds.

This design **inverts the premise** to match how `sidekick.nvim` uses tmux:

> **nvim is the top-level host/driver. herdr is an invisible backend daemon**
> that owns each agent's PTY. Each agent is shown inside an **nvim floating
> `:terminal`** that runs `herdr agent attach <name>`. All navigation is nvim
> keybinds — focus never leaves nvim.

This is precisely "sidekick's nvim-host model with **herdr swapped in for tmux**
as the mux backend" — except herdr additionally provides the agent status hooks
and the grouped agent dashboard that tmux cannot.

### Why this works (empirically verified)

A spike against `herdr` 0.7.1 confirmed the four load-bearing properties:

1. **Clean stream.** `herdr agent attach <name>` emits *only the agent's own
   PTY* (alt-screen, mouse, kitty-keyboard setup) — **no herdr session chrome
   and no `Ctrl-a` prefix bar bleeding into the float.** So the "two keybind
   worlds" problem does not reappear inside nvim.
2. **Renders in nvim.** A clean PTY stream is handled trivially by nvim's
   `:terminal` vterm.
3. **Detach ≠ kill.** Killing the attach *client* by signal (the equivalent of
   nvim closing the terminal job) **left the agent running** in herdr. So
   "hide the float" never kills your agent.
4. **herdr owns the process.** The attached agent is the same entry in
   `herdr agent list`, so status hooks and the grouped dashboard stay intact.

## Goals

- Drive agents with **nvim keybinds only** — spawn, toggle, hide, cycle, send.
- Keep **herdr as the backend** so its hooks and the grouped agent dashboard
  keep working.
- Preserve the **toggleterm-style ergonomics** the user already built on top of
  sidekick: a cwd-scoped current target, count-addressable slots, numbered
  clones per project, and a polished float footer.
- Agents **persist across nvim restarts** (herdr is the daemon) and are
  rediscoverable via `herdr agent list`.

## Non-goals

- No second multiplexer and no embedded tmux/zellij — herdr is the only backend.
- No NES / next-edit-suggestion features (that was sidekick-specific; out of
  scope here).
- No change to herdr itself; herd.nvim only shells out to the `herdr` CLI.

## Architecture

nvim is the host UI. herd.nvim talks to the running herdr **server** over its
socket via the `herdr` CLI (the server runs whether or not an interactive herdr
client is attached). Agents are spawned into the herdr server and shown by
attaching an nvim floating terminal to them.

```
          nvim (host UI, all keybinds)
            │
   ┌────────┴─────────┐
   │ floating :terminal│  ── runs ──▶  herdr agent attach <name>
   │  (one per agent)  │                       │
   └───────────────────┘                       ▼
            │ CLI (socket)            herdr server (daemon)
            ├─ herdr agent list ───────▶  owns agent PTYs
            ├─ herdr agent start …        emits status hooks
            ├─ herdr agent send  …        feeds grouped dashboard
            └─ herdr (attach session) ─▶  escape-hatch TUI
```

### Module layout (`lua/herd/`)

| file          | role                                                                                                 | status   |
| ------------- | ---------------------------------------------------------------------------------------------------- | -------- |
| `init.lua`    | `setup`, keymaps, `:Herd` command, public API (`toggle`/`select`/`send`/`spawn`/`dashboard`)         | rewrite  |
| `config.lua`  | `tools`, `keys`, `win` (float opts); **drop `zoom`**                                                  | revise   |
| `herdr.lua`   | CLI client: keep `agents`/`spawn`/`next_name`; **add** `attach_argv(name)`, `agent_send(name,text)`, `dashboard_argv()`; **drop** pane `focus`/`zoom` | revise   |
| `terminal.lua`| **NEW** — float manager: registry `name → {buf,win,job}`; `open`/`hide`/`toggle`/`is_open`/`current` | new      |
| `picker.lua`  | **NEW** — nvim float built from `herdr agent list`, grouped by project + status; `+ spawn` entries; key to pop herdr TUI | new      |
| `health.lua`  | update checks (server reachable, tools on PATH) for the new model                                    | revise   |

Each module has one purpose and a narrow interface:
`herdr.lua` is pure CLI I/O (no UI state); `terminal.lua` owns nvim windows/jobs
(no herdr knowledge beyond an argv); `picker.lua` is selection UI; `init.lua`
wires them together and holds the target state.

## Components

### `herdr.lua` — CLI client (thin, pure)

- Retained: `run`, `api`, `installed`, `server_running`, `agents(cwd)`,
  `next_name(tool)`, `spawn(name, cwd, def)`.
- `spawn` changes: **drop `--split right`** (no tiling next to nvim). Spawn as
  `herdr agent start <name> --cwd <cwd> --no-focus -- <argv>` plus `--env`
  pairs. herdr hosts the pane server-side; herd.nvim only ever attaches to it.
- `attach_argv(name) -> string[]` returns `{ 'herdr', 'agent', 'attach', name }`
  for `terminal.lua` to `termopen`/`jobstart`.
- `agent_send(name, text)` runs `herdr agent send <name> <text>` (literal text,
  no Enter).
- `dashboard_argv() -> string[]` returns the argv that opens herdr's full TUI
  (e.g. `{ 'herdr' }` / `herdr session attach default`) for the escape hatch.
- Removed: pane-centric `focus`/`zoom` helpers (the old herdr-host model).

### `terminal.lua` — float manager (NEW)

Owns a per-nvim-session registry mapping `agent_name → { buf, win, job }`.

- `open(name)` — ensure a terminal buffer running `attach_argv(name)` exists,
  then show it in a float per `config.win`.
- `hide()` — `nvim_win_hide` the current float. **Keeps the buffer + terminal
  job alive** (the attach client stays connected but invisible), so re-show is
  instant and the agent is undisturbed.
- `toggle(name)` — if `name`'s float is visible, hide; else open.
- `is_open(name)`, `current()` — introspection for `init.lua`.
- Lifecycle: quitting nvim or `:bdelete!` detaches the attach client; the agent
  **survives in herdr** (verified). Reopening nvim re-attaches on demand.
- Float styling: large/fullscreen-ish (`width`/`height ≈ 0.9`, configurable),
  bordered, with a **footer** like `Herd: <agent> on <cwd>` (porting the
  sidekick footer aesthetic), `winhighlight` mapped to terminal colors.

### `picker.lua` — grouped agent picker (NEW)

- Built from `herdr agent list`, **grouped by project (cwd) and showing status**
  (idle/working/blocked) — the view in the reference screenshot.
- Selecting a running agent attaches it in a float (`terminal.open`).
- `+ <tool>` entries spawn a configured tool (numbered clone if the base name is
  taken), then attach.
- A key inside the picker (and a top-level keymap) **pops herdr's full TUI** via
  `dashboard_argv()` in a float — the "Both" dashboard decision: nvim picker is
  the default, herdr's real TUI is the escape hatch.
- Initial implementation may use `vim.ui.select` with a grouped formatter; a
  custom float can follow if needed. cwd-scoping logic is ported from the
  existing `live_target`/sidekick picker work.

### `init.lua` — orchestration & state

State (toggleterm-style, ported from the sidekick layer):

- **Current target** agent name, **cwd-scoped**: actions hit *this project's*
  agent. Opening nvim in project A never toggles project B's agent.
- **Slot/count addressing**: `<count><leader><Tab>` targets clone slot `count`
  (`claude`, `claude_2`, …), matching the old `target_cli_id`. With no live
  agent for the target, fall through to the picker.

Public API: `toggle()`, `select()`, `send()`, `spawn(tool)`, `dashboard()`,
exposed also as `:Herd [toggle|select|send|spawn|dashboard]`.

## Keymaps (defaults; all configurable, `false` disables)

| key                 | mode     | action                                                          |
| ------------------- | -------- | --------------------------------------------------------------- |
| `<leader><Tab>`     | normal   | toggle current agent float; none → picker. `<count>` = slot     |
| `<leader><Tab>`     | visual   | `herdr agent send` the selection (no Enter), then show the float |
| `<leader><Tab>`     | terminal | hide the float from inside (buffer-local)                        |
| `<leader>;`¹        | normal   | picker (grouped agent list + spawn)                              |
| `<leader>\`¹        | normal   | escape-hatch: pop herdr's full TUI in a float                    |

¹ Placeholder keys — final bindings chosen during implementation; all live in
`config.keys` and can be set to `false`.

## Configuration (proposed shape)

```lua
require('herd').setup({
  -- Spawnable agents. Key = tool name, cmd = argv, env = extra environment.
  tools = {
    claude   = { cmd = { 'claude' } },
    opencode = { cmd = { 'opencode', '--continue' }, env = { ... } },
  },

  -- Keymaps. Set any to false to disable.
  keys = {
    toggle    = '<leader><Tab>', -- normal: toggle current agent (count = slot)
    send      = '<leader><Tab>', -- visual: send selection
    hide      = '<leader><Tab>', -- terminal: hide float from inside
    select    = '<leader>;',     -- normal: grouped picker
    dashboard = '<leader>\\',    -- normal: pop herdr's full TUI
  },

  -- Floating window.
  win = {
    width    = 0.9,
    height   = 0.9,
    border   = 'rounded',
    footer   = true,            -- "Herd: <agent> on <cwd>"
    winblend = 0,
  },
})
```

## Data flow

- **Spawn**: keymap → `init.spawn(tool)` → `herdr.spawn` (`agent start … -- argv`)
  → `terminal.open(name)` (`termopen herdr agent attach <name>`) → float shown.
- **Toggle**: keymap → resolve cwd-scoped target → `terminal.toggle(name)`.
- **Send**: visual keymap → capture selection (`getregion`) → `herdr.agent_send`
  → `terminal.open(name)` so the user lands in the agent to submit.
- **Pick**: keymap → `picker` reads `herdr agent list` → select → attach.
- **Dashboard**: keymap → float running `dashboard_argv()`.

## Error handling

- Reuse `ensure_server()`: if no herdr server, notify "launch herdr/server
  first" and abort. Health check verifies the binary + server.
- Unknown tool name → notify + abort.
- Spawn failure (non-zero CLI) → error already surfaced by `herdr.run`; abort.
- Empty selection on send → no-op.
- Attaching to an agent that died between `list` and `attach` → the terminal job
  exits immediately; surface a notice and drop it from the registry.

## Testing / verification

- Manual acceptance against a real herdr server (the spike harness):
  1. Spawn `claude` → float opens, agent visible, no `Ctrl-a` chrome.
  2. Hide (`<leader><Tab>`) → float gone, `herdr agent list` still shows it
     working; re-toggle → same session, content intact.
  3. `2<leader><Tab>` → spawns/targets `claude_2`; slot addressing works.
  4. Visual `<leader><Tab>` → text appears in the agent prompt unsent.
  5. Picker shows agents grouped by project with status; selecting attaches.
  6. Dashboard key pops herdr's TUI.
  7. `:q` nvim, reopen → `herdr agent list` unchanged; re-attach works.
- `:checkhealth herd` validates binary, server, and configured tools.

## Open items (resolve during implementation; not blockers)

- **Multi-line `herdr agent send`**: confirm newline handling for a multi-line
  visual selection (old code used `pane send-text` with multiline as one argv).
- ~~**Spawn placement with no attached herdr client**~~ **RESOLVED**: agents
  are placed in a dedicated, found-or-created herdr workspace (label
  `workspace`, default `'herd'`) via `agent start --workspace <id>
  --no-focus`. herdr auto-closes emptied tabs; the workspace is reused across
  spawns. This keeps agents off nvim's pane when nvim runs inside a herdr
  session.
- **Attach reflow**: confirm the attached agent reflows to the nvim float's size
  on `VimResized` / window resize.
- **Double-attach mirroring**: viewing the same agent in the popped herdr TUI
  while a float is attached produces two mirrors — cosmetic; `--takeover` if it
  matters.

## Documentation

README and `doc/herd.txt` are **rewritten**, not tweaked: the current text
argues the opposite premise ("herdr is the host, nvim is a pane"). New docs
describe the nvim-host / herdr-backend model, the keymaps, and the persistence
behavior.

## As-built changes

The following shipped behaviour differs from or extends the original design:

### dashboard_argv removed; dashboard = workspace focus
`dashboard_argv()` was never added to `herdr.lua`. The `dashboard` action
(`M.dashboard()` in `init.lua`) instead calls `Herdr.ensure_workspace(label)`
(→ `herdr workspace list` / `herdr workspace create --no-focus --label <label>`)
and then `Herdr.focus_workspace(id)` (→ `herdr workspace focus <id>`).
**No float is opened.** The herdr client comes to the foreground showing the
dedicated herd workspace. Anywhere the design says "float running `dashboard_argv()`"
or "pop herdr's full TUI in a float", read instead: "focus the dedicated herd
workspace in herdr".

### Dedicated workspace placement (resolved open item, now shipped)
Agents are spawned with `herdr agent start <name> --cwd <cwd> --no-focus
--workspace <ws_id> -- <argv>`. The workspace id is obtained from
`ensure_workspace(label)` which does a list-then-create round trip. The
`workspace` config option (default `'herd'`) controls the label. This keeps
all herd-spawned agents off the user's project workspaces/tabs.

### Additional config options shipped
- `keys.newline` (default `'<S-CR>'`) — terminal-mode buffer-local map that
  sends kitty Shift-Enter (`\27[13;2u`) to the agent without submitting.
  Registered via a `TermOpen` autocmd alongside `keys.hide`.
- `win.winhighlight` (default `''`) — winhighlight string applied to the
  float window (`vim.wo[win].winhighlight`), enabling a transparent or
  terminal-styled overlay (mirrors sidekick.nvim by mapping float highlight
  groups to terminal background groups).
- `workspace` (default `'herd'`) — see above.

### spawn-on-empty-slot (toggle with count)
When `<count><toggle>` addresses a slot with no live agent, `Target.infer_base`
determines which configured tool to spawn:
1. Current target's base (strip trailing `_<n>` suffix) if it is a configured tool.
2. Else the first cwd-scoped agent's base if it is a configured tool.
3. Else the sole configured tool if exactly one is configured.
4. Else fall to the picker.
This is implemented in `lua/herd/target.lua` (`infer_base`).

### cwd-scoped picker with trimmed row labels
`picker.lua` calls `Herdr.agents(vim.fs.normalize(vim.fn.getcwd()))`, so the
picker is scoped to the **current project cwd**. Row labels are `name  [status]`
(no cwd column — redundant after scoping). The design's "grouped by cwd"
presentation and cwd column are superseded.

### send/show defer the float open via vim.schedule
`M.send()` calls `Herdr.agent_send(a.pane_id, text)` synchronously (the CLI
call), then opens the float in a `vim.schedule` callback so the text delivery
and the Esc key-feed have flushed before the window changes. The shared
`show()` helper (used by spawn and picker-select) likewise defers
`Terminal.open` via `vim.schedule` — opening a float synchronously inside a
`vim.ui.select` (snacks) callback is unreliable.

### Target agents by pane id, not name
`herdr agent attach/send <name>` is **ambiguous** when herdr also detects
same-tool processes in other panes (`agent_target_ambiguous` — a bare `claude`
matches the herd-named agent AND every detected "claude"). So herd targets the
unique **pane id** for both attach and send: `Terminal.open(name, { pane })`
attaches `Herdr.attach_argv(opts.pane)`, and `M.send` calls
`Herdr.agent_send(a.pane_id, text)`. The terminal registry stays keyed by name
(herd's identity); only the herdr CLI calls use the pane id.

### Skip nameless detected agents
`Herdr.agents()` filters out entries with no `name` — herdr lists *detected*
coding-agent processes (no assigned name) which herd cannot target by name and
which would crash `next_name` (`taken[nil]`) and the picker labels.

### Per-agent project-labelled tab
`Herdr.spawn(name, cwd, def, workspace, tab_label)` creates the agent's own tab
in the dedicated workspace (`herdr tab create --workspace <ws> --label
<project>`) and starts it with `--tab <id>`. `tab_label` is the focused
workspace's label (`Herdr.focused_workspace_label`, the user's project at spawn
time), falling back to the cwd folder. Result: the herdr sidebar reads
`<workspace> · <project>` (e.g. `herd · dotfiles-config`). With no `tab_label`,
spawn falls back to `--workspace <ws>`.
