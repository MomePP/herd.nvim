# 🐑 herd.nvim

> Drive [herdr](https://herdr.dev) coding agents from Neovim — **nvim is the host, herdr is the backend daemon** (default float mode).

`herd.nvim` is a Neovim plugin that makes nvim the top-level UI for your
[herdr](https://herdr.dev) coding agents. herdr runs as a background daemon
that **owns each agent's PTY** — so herdr's status hooks and grouped agent
dashboard keep working — while, in the default `mode = 'float'`, agents are
shown inside **nvim floating terminals** via `herdr agent attach`. All
navigation uses standard nvim keybinds; there is no multiplexer round-trip.
(`mode = 'native'` is the exception — see "Native mode" below.)

> Inspired by [`folke/sidekick.nvim`](https://github.com/folke/sidekick.nvim). Where
> sidekick makes nvim the host with tmux/zellij as the backend, herd uses the same
> nvim-as-host model (in float mode) with **herdr** as the backend — gaining herdr's
> status hooks and grouped agent dashboard.

## ✨ Features

- 🚀 **Spawn + fullscreen float** — picker spawns a tool and shows it in a fullscreen nvim float.
- 🔄 **Toggle** — `<leader>\` (normal) opens/closes this cwd's agent; `count` targets a numbered slot.
- ✂️ **Send selection** — visual `<leader>\` pushes the selection to the active agent (no Enter — review, then submit).
- 🗂 **Grouped picker** — `<leader>s` lists running agents **for the current project** and configured tools. Use the dashboard for a cross-project view.
- 📊 **Dashboard** — `<leader>S` (or `:Herd dashboard`). Float mode focuses the dedicated herd.nvim workspace; native mode opens the global cross-project agent picker.
- 💾 **Persistence** — agents survive closing the float and `:q`; herdr owns the process and rediscovers them via `herdr agent list`.
- 🩺 **`:checkhealth herd`** — verifies herdr, the server, and your tools.
- 🪶 **Tiny** — eight small Lua files, one external dependency (the `herdr` binary).

## 📋 Requirements

- Neovim **≥ 0.10** (uses `vim.fn.getregion()`)
- [herdr](https://herdr.dev/docs/install/) **≥ 0.7.1** on `$PATH` (verified against 0.7.1; uses `agent attach/send`, `workspace list/create/focus`)
- A running herdr server — launch `herdr` as a headless daemon or in any
  terminal; nvim does **not** need to run inside a herdr pane.

## 📦 Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'MomePP/herd.nvim',
  event = 'VeryLazy',
  opts = {
    tools = {
      claude   = { cmd = { 'claude' } },
      opencode = {
        cmd = { 'opencode', '--continue' },
        env = { OPENCODE_EXPERIMENTAL_LSP_TOOL = 'true' },
      },
    },
  },
}
```

`opts` is passed to `require('herd').setup(opts)`.

## ⚡ Quick start

Two display backends — pick one:

### Float mode (default, zero extra setup)

Agents show inside a fullscreen nvim floating terminal. Works anywhere —
nvim does **not** need to run inside a herdr pane, and there is nothing to
configure beyond the Installation snippet above:

```lua
{
  'MomePP/herd.nvim',
  event = 'VeryLazy',
  opts = {
    tools = {
      claude = { cmd = { 'claude' } },
    },
  },
}
```

That's it: `<leader>\` spawns/toggles this project's agent float (and hides
it again from inside), `<leader>s` opens the picker. The whole round trip
stays inside nvim, so no herdr keybind is needed.

### Native mode (herdr tabs + two-key round trip)

Agents live as **sibling herdr tabs** next to nvim — scrolling and
drag-select are native terminal behavior, and herdr's status indicators
attribute each agent to its real project. It needs **one extra step outside
nvim** — the return-trip keybind in herdr's config — because the way *back*
can't be an nvim mapping.

**1. Run nvim inside a herdr pane** — native mode reads `$HERDR_TAB_ID` /
`$HERDR_WORKSPACE_ID` from the environment herdr sets on its panes (without
them, `setup()` warns and falls back to float mode).

**2. Enable native mode** in your plugin spec:

```lua
{
  'MomePP/herd.nvim',
  event = 'VeryLazy',
  opts = {
    mode = 'native',
    tools = {
      claude = { cmd = { 'claude' } },
    },
  },
}
```

**3. Bind the return trip** in `~/.config/herdr/config.toml` — while an
agent's tab is visible, herdr (not nvim) receives your keys, so this side
must be a herdr binding:

```toml
[[keys.command]]
key = 'prefix+\'   # unbound in herdr by default
type = "shell"
command = "nvim -l /path/to/herd.nvim/bin/herd-return.lua"
```

Point `command` at wherever your plugin manager installed herd.nvim (e.g.
lazy.nvim: `~/.local/share/nvim/lazy/herd.nvim/bin/herd-return.lua`), then
apply it with `herdr server reload-config`.

**4. The loop:**

| | Key | |
| --- | --- | --- |
| → | `<leader>\` | spawn/toggle this project's agent (its tab replaces your view) |
| ← | `prefix+\` | jump back to the editor tab that spawned the focused agent |
| ⇱ | `<leader>s` | project picker: switch agents here, or spawn another tool |
| ⇲ | `<leader>S` | dashboard: every agent across all projects, with live preview |

The two legs rhyme on purpose: *leader*-`\` goes to the agent, *prefix*-`\`
comes home — and the return works no matter how you wandered to the agent
(sidebar, tab cycling, workspace hops). See "Native mode" below for how it
resolves the origin editor.

## ⚙️ Configuration

Defaults:

```lua
require('herd').setup({
  -- Spawnable agents. Key = tool name, `cmd` = argv, `env` = extra environment.
  tools = {},

  mode = 'float',  -- 'native' shows agents as herdr tabs instead of nvim floats
                    -- (requires nvim to run inside a herdr pane). See "Native mode" below.

  picker = 'auto', -- global/dashboard picker renderer: 'auto' uses snacks.nvim when installed
                    -- (full layout + live agent preview); 'select' forces plain vim.ui.select.
                    -- The project picker (keys.select) always uses vim.ui.select.

  workspace = 'herd.nvim',  -- float mode only: herdr workspace label that hosts spawned agents
                            -- (kept off your project tabs). Native mode uses nvim's own workspace.

  -- Keymaps. Set any to `false` to disable it.
  keys = {
    toggle    = '<leader>\\', -- (normal)   toggle this cwd's agent float; count = slot
    send      = '<leader>\\', -- (visual)   send selection to the active agent
    hide      = '<leader>\\', -- (terminal) hide the float from inside
    select    = '<leader>s',  -- (normal)   grouped picker: switch agent or spawn tool
    dashboard = '<leader>S',  -- (normal)   dashboard: global picker (native) / herd workspace (float)
    newline   = '<S-CR>',     -- (terminal) send a CLI newline (kitty Shift-Enter) to the agent
  },

  -- Float window. Defaults to a fullscreen invisible-border float.
  -- Set `winhighlight` to your terminal highlight groups for a transparent overlay
  -- (e.g. Snacks: 'Normal:SnacksTerminalNormal,...').
  win = {
    width       = 1,      -- fraction of &columns (1 = fullscreen)
    height      = 1,      -- fraction of &lines   (1 = fullscreen)
    border      = { '', '', '', '', ' ', ' ', ' ', '' },  -- invisible border (bottom row kept for footer)
    footer      = true,   -- show "Herd: <agent>" footer
    winblend    = 0,
    winhighlight = '',    -- set terminal-bg highlight groups here for a transparent overlay
    mouse       = true,   -- nvim owns the mouse in the float (agent gets scroll/click;
                          -- Shift+drag to select). false = hand the mouse to the terminal
                          -- so a plain drag selects natively (agent loses its mouse in the float).
  },

})
```

## 🚀 Usage

| Key | Mode | Action |
| --- | --- | --- |
| `<leader>\` | normal | Toggle this cwd's agent float. `<count><key>` targets slot N; an **empty slot spawns the inferred tool's next clone** (inferred from current target, first project agent, or sole configured tool — else opens the picker). |
| `<leader>\` | visual | Send the selection to the active agent (no Enter — the float opens so you can review and submit). |
| `<leader>\` | terminal | Hide the float from inside the agent. |
| `<leader>s` | normal | Grouped picker (**current project only**): switch to a running agent or spawn a configured tool. Rows show `name  [status]`. |
| `<leader>S` | normal | Dashboard. Float mode focuses the dedicated herd.nvim workspace; native mode opens the global cross-project agent picker. |
| `<S-CR>` | terminal | Send a newline (kitty `Esc[13;2u`) to the agent — for multi-line prompts without submitting. |

Also available as `:Herd [toggle|select|send|dashboard]`, `:Herd spawn <tool>`, and the
Lua API `require('herd').{toggle,select,send,dashboard,spawn}()`.

## 🧠 How it works

`herd` shells out to the `herdr` CLI. nvim is the host; herdr is a backend daemon:

| What | herdr command |
| --- | --- |
| discover agents | `herdr agent list` (nameless *detected* agents are skipped — herd targets by name) |
| spawn | `herdr tab create --workspace <ws> --label <label>` → `herdr agent start <name> --tab <tab> --no-focus -- <argv>` → close the tab's spare pane so the agent fills it |
| placement | float: dedicated `herd.nvim` workspace, found-or-created via `herdr workspace list/create`; native: nvim's own workspace (`$HERDR_WORKSPACE_ID`), tab labelled `<project>:<agent>` |
| show | float: nvim float running `herdr agent attach <pane-id>`; native: `herdr agent focus <pane-id>` |
| send selection | `herdr agent send <pane-id> <text>` |
| dashboard | float: focus the dedicated workspace (`herdr workspace focus <ws>`); native: global picker → `herdr agent focus <pane>` |

In **float mode**, spawned agents are placed in a dedicated herdr workspace (default label `herd.nvim`) that lives off your project workspaces/tabs — so they never tile next to nvim when nvim runs inside a herdr session. Each agent gets its own tab there, labelled with its project, so the herdr sidebar reads `<workspace> · <project>` (herdr only renders the `· <project>` suffix with 2+ tabs). In **native mode**, agents land as sibling tabs in nvim's *own* workspace instead, labelled `<project>:<agent>` — see "Native mode" below. In both modes the tab's spare pane is closed so the agent fills the tab, and when an agent exits herd **reaps its dead tab on the next spawn** (native mode reaps only tabs carrying this project's `<project>:` label prefix).

herd targets agents by their **pane id**, not by name: a bare tool name like `claude` is ambiguous to herdr when it also detects same-tool processes in other panes, so `attach`/`send` use the unique pane id.

Discovery is by agent **name**, which herdr preserves through its native agent
detection — so the tool you spawn is the tool `herd` finds again. Names are
server-global-unique, which is exactly why same-tool clones get numbered.

The float can be styled as a fullscreen-transparent overlay by setting
`win.winhighlight` to map float highlight groups to your terminal background groups
(e.g. `'Normal:MyTermBg,FloatBorder:MyTermBg'`). This mirrors the look of
sidekick.nvim when `winblend` is non-zero or terminal colors are remapped.

## 🧭 Native mode

`mode = 'native'` swaps the display backend: instead of showing an agent in
an nvim floating terminal, herd.nvim spawns it as a **sibling herdr tab in
nvim's own workspace** and drives focus through the herdr CLI. There is no
nvim window (float or tab) for the agent at all — scrolling, clicking, and
drag-select are native Ghostty-over-herdr behavior, with none of the
`win.mouse` trade-off float mode has.

**Requires nvim to run inside a herdr pane** (native mode reads
`$HERDR_TAB_ID`/`$HERDR_WORKSPACE_ID` from the environment herdr sets on any
pane it spawns). Without it, `setup()` warns and falls back to float mode for
the session.

`win.*` and `keys.hide`/`keys.newline` only apply to `mode = 'float'` —
native mode has no herd-owned nvim terminal buffer for them to affect.

Going *to* an agent is an nvim action (`<leader>\`/`<leader>s`, same keys as
float mode); coming *back* is not — nvim isn't focused/receiving input while
herdr shows another tab, so the return trip is ordinary herdr tab/pane
navigation instead:

- `last_pane` (tmux-style last-pane toggle) if your herdr config binds it —
  jumps back to whichever pane you were on before.
- `previous_tab`/`next_tab` as a fallback, cycling tabs within the workspace.
- `next_agent`/`previous_agent` to jump directly to a specific agent via
  herdr's own agents sidebar, independent of the round trip.

Bind these in `~/.config/herdr/config.toml`'s `[keys]` section — they're
herdr-native navigation, not something herd.nvim can configure.

### Round trip: `herd-return`

The bindings above are generic herdr navigation — they don't know *which*
editor spawned the focused agent. `bin/herd-return.lua` does. Bind it in
`~/.config/herdr/config.toml` and one key jumps from any herd agent tab
back to its origin editor tab, no matter how you reached the agent
(sidebar, `next_agent`, tab cycling, workspace hops):

```toml
[[keys.command]]
key = 'prefix+\'   # mirrors <leader>\: leader-doubled goes TO the agent,
type = "shell"     # prefix+\ comes back (unbound in herdr by default)
command = "nvim -l /path/to/herd.nvim/bin/herd-return.lua"
```

Resolution is stateless, from live herdr state: the focused agent tab's
label (`dotfiles:claude_2` → the sibling tab labelled `dotfiles`), falling
back to matching the agent's spawn cwd against your editor panes. When
nothing matches (not a herd tab, editor gone) it shows a herdr notification
and does nothing — herdr has no CLI to re-dispatch the key's default action.

### Dashboard: global agent picker

In native mode `:Herd dashboard` (or `keys.dashboard`) opens a picker over
**every running agent across all projects** — rows read
`dotfiles:claude_2  [working]  · dotfiles-config` — and selecting one
focuses its tab, flipping workspace when the agent lives elsewhere.
(Float mode keeps the old behavior: focus the dedicated herd workspace.)
When [snacks.nvim](https://github.com/folke/snacks.nvim) is installed, the
dashboard renders through `Snacks.picker` (full-size, with a preview pane
showing each agent's metadata and live output); without it — or with
`picker = 'select'` — it falls back to `vim.ui.select`. The project picker
(`keys.select`) always uses the compact `vim.ui.select`, which fits its
short switch/spawn list.

## ❓ FAQ

**Is this the same as sidekick.nvim?**
Same host model — nvim hosts the agents as floating terminals — but different backend:
herd uses **herdr** (not tmux/zellij), so you also get herdr's status hooks and the
grouped agent dashboard. If you already run herdr as your daemon, use herd. If you
prefer tmux/zellij as the backend, use sidekick.

**Do agents survive closing the float or quitting nvim?**
Yes. herdr owns the process; closing the float (or `:q`) only detaches the nvim
terminal. Run `<leader>s` (picker) or `:Herd select` to reattach from the same
project. For agents in other projects, use the dashboard (`<leader>S` /
`:Herd dashboard`) — float mode focuses the herd.nvim workspace in herdr;
native mode opens the global picker and jumps straight to the selection.

**Nothing happens / "no herdr server running".**
Launch `herdr` first (any terminal or as a headless daemon). Run `:checkhealth herd`.

**Can I run multiple agents in one project?**
Yes. Picker → spawn a tool again; it'll be named `claude_2`, etc. Use `2<leader>\`
to toggle directly to slot 2.

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent multiplexer this plugin drives.
- [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) — structure and UX
  inspiration.

## 📄 License

[MIT](./LICENSE)
