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
- 🔄 **Toggle** — `<leader>s` (normal) opens/closes this cwd's agent; `count` targets a numbered slot.
- ✂️ **Send selection** — visual `<leader>s` pushes the selection to the active agent (no Enter — review, then submit).
- 🗂 **Grouped picker** — `<leader>S` lists running agents **for the current project** and configured tools. Use the dashboard for a cross-project view.
- 📊 **Dashboard** — unmapped by default; use `:Herd dashboard` or set `keys.dashboard` to a key to focus the dedicated herd.nvim workspace in herdr.
- 💾 **Persistence** — agents survive closing the float and `:q`; herdr owns the process and rediscovers them via `herdr agent list`.
- 🩺 **`:checkhealth herd`** — verifies herdr, the server, and your tools.
- 🪶 **Tiny** — seven small Lua files, one external dependency (the `herdr` binary).

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

## ⚙️ Configuration

Defaults:

```lua
require('herd').setup({
  -- Spawnable agents. Key = tool name, `cmd` = argv, `env` = extra environment.
  tools = {},

  mode = 'float',  -- 'native' shows agents as herdr tabs instead of nvim floats
                    -- (requires nvim to run inside a herdr pane). See "Native mode" below.

  workspace = 'herd.nvim',  -- herdr workspace label that hosts spawned agents (kept off your project tabs)

  -- Keymaps. Set any to `false` to disable it.
  keys = {
    toggle    = '<leader>s',  -- (normal)   toggle this cwd's agent float; count = slot
    send      = '<leader>s',  -- (visual)   send selection to the active agent
    hide      = '<leader>s',  -- (terminal) hide the float from inside
    select    = '<leader>S',  -- (normal)   grouped picker: switch agent or spawn tool
    dashboard = false,        -- (normal)   unmapped by default; use :Herd dashboard
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
| `<leader>s` | normal | Toggle this cwd's agent float. `<count><key>` targets slot N; an **empty slot spawns the inferred tool's next clone** (inferred from current target, first project agent, or sole configured tool — else opens the picker). |
| `<leader>s` | visual | Send the selection to the active agent (no Enter — the float opens so you can review and submit). |
| `<leader>s` | terminal | Hide the float from inside the agent. |
| `<leader>S` | normal | Grouped picker (**current project only**): switch to a running agent or spawn a configured tool. Rows show `name  [status]`. |
| (unmapped) | normal | Focus the dedicated herd.nvim workspace in herdr. Use `:Herd dashboard` or set `keys.dashboard` to a key. |
| `<S-CR>` | terminal | Send a newline (kitty `Esc[13;2u`) to the agent — for multi-line prompts without submitting. |

Also available as `:Herd [toggle|select|send|dashboard]`, `:Herd spawn <tool>`, and the
Lua API `require('herd').{toggle,select,send,dashboard,spawn}()`.

## 🧠 How it works

`herd` shells out to the `herdr` CLI. nvim is the host; herdr is a backend daemon:

| What | herdr command |
| --- | --- |
| discover agents | `herdr agent list` (nameless *detected* agents are skipped — herd targets by name) |
| spawn | `herdr tab create --workspace <ws> --label <project>` → `herdr agent start <name> --tab <tab> --no-focus -- <argv>` → close the tab's spare pane so the agent fills it |
| placement | dedicated `herd.nvim` workspace, found-or-created via `herdr workspace list` / `herdr workspace create --no-focus --label herd.nvim` |
| show in nvim | nvim float running `herdr agent attach <pane-id>` |
| send selection | `herdr agent send <pane-id> <text>` |
| dashboard | focus the dedicated `herd.nvim` workspace (`herdr workspace focus <ws>`) |

Spawned agents are placed in a dedicated herdr workspace (default label `herd.nvim`) that lives off your project workspaces/tabs — so they never tile next to nvim when nvim runs inside a herdr session. The workspace is found-or-created automatically on each spawn and reused across spawns. When an agent exits herdr leaves its (now agentless) tab behind, so herd **reaps dead tabs on the next spawn**. The label is configurable via the `workspace` option.

Each agent gets its **own tab inside that workspace, labelled with its project** (the focused workspace's label, falling back to the cwd folder), so the herdr sidebar reads `<workspace> · <project>` (e.g. `herd.nvim · dotfiles-config`). The spare pane the tab is created with is closed so the agent fills the tab (fullscreen when viewed in herdr, without zooming — which would steal focus). Note herdr only renders the `· <project>` suffix when the workspace holds **2+ tabs** (2+ agents); with a single agent it shows just the workspace name.

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

Going *to* an agent is an nvim action (`<leader>s`/`<leader>S`, same keys as
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

## ❓ FAQ

**Is this the same as sidekick.nvim?**
Same host model — nvim hosts the agents as floating terminals — but different backend:
herd uses **herdr** (not tmux/zellij), so you also get herdr's status hooks and the
grouped agent dashboard. If you already run herdr as your daemon, use herd. If you
prefer tmux/zellij as the backend, use sidekick.

**Do agents survive closing the float or quitting nvim?**
Yes. herdr owns the process; closing the float (or `:q`) only detaches the nvim
terminal. Run `<leader>S` (picker) or `:Herd select` to reattach from the same
project. For agents in other projects, use `:Herd dashboard` (or set `keys.dashboard`)
to focus the herd.nvim workspace in herdr and see all agents there, then re-toggle
from nvim once you change directory.

**Nothing happens / "no herdr server running".**
Launch `herdr` first (any terminal or as a headless daemon). Run `:checkhealth herd`.

**Can I run multiple agents in one project?**
Yes. Picker → spawn a tool again; it'll be named `claude_2`, etc. Use `2<leader>s`
to toggle directly to slot 2.

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent multiplexer this plugin drives.
- [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) — structure and UX
  inspiration.

## 📄 License

[MIT](./LICENSE)
