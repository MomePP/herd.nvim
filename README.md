# 🐑 herd.nvim

> Drive [herdr](https://herdr.dev) coding agents from Neovim — **nvim is the host, herdr is the backend daemon**.

`herd.nvim` is a Neovim plugin that makes nvim the top-level UI for your
[herdr](https://herdr.dev) coding agents. herdr runs as a background daemon
that **owns each agent's PTY** — so herdr's status hooks and grouped agent
dashboard keep working — while agents are shown inside **nvim floating
terminals** via `herdr agent attach`. All navigation uses standard nvim
keybinds; there is no multiplexer round-trip.

> Inspired by [`folke/sidekick.nvim`](https://github.com/folke/sidekick.nvim). Where
> sidekick makes nvim the host with tmux/zellij as the backend, herd uses the same
> nvim-as-host model with **herdr** as the backend — gaining herdr's status hooks
> and grouped agent dashboard.

## ✨ Features

- 🚀 **Spawn + fullscreen float** — picker spawns a tool and shows it in a 90 % nvim float.
- 🔄 **Toggle** — `<leader><Tab>` (normal) opens/closes this cwd's agent; `count` targets a numbered slot.
- ✂️ **Send selection** — visual `<leader><Tab>` pushes the selection to the active agent (no Enter — review, then submit).
- 🗂 **Grouped picker** — `<leader>;` lists all running agents (across all projects) and configured tools.
- 📊 **Dashboard escape-hatch** — `<leader>\` pops herdr's full TUI in a float for anything beyond a single agent.
- 💾 **Persistence** — agents survive closing the float and `:q`; herdr owns the process and rediscovers them via `herdr agent list`.
- 🩺 **`:checkhealth herd`** — verifies herdr, the server, and your tools.
- 🪶 **Tiny** — seven small Lua files, one external dependency (the `herdr` binary).

## 📋 Requirements

- Neovim **≥ 0.10** (uses `vim.fn.getregion()`)
- [herdr](https://herdr.dev/docs/install/) **≥ 0.7** on `$PATH`
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

  workspace = 'herd',  -- herdr workspace label that hosts spawned agents (kept off your project tabs)

  -- Keymaps. Set any to `false` to disable it.
  keys = {
    toggle    = '<leader><Tab>',  -- (normal)   toggle this cwd's agent float; count = slot
    send      = '<leader><Tab>',  -- (visual)   send selection to the active agent
    hide      = '<leader><Tab>',  -- (terminal) hide the float from inside
    select    = '<leader>;',      -- (normal)   grouped picker: switch agent or spawn tool
    dashboard = '<leader>\\',     -- (normal)   herdr full TUI in a float
  },

  -- Float window dimensions and style.
  win = {
    width    = 0.9,       -- fraction of &columns
    height   = 0.9,       -- fraction of &lines
    border   = 'rounded',
    footer   = true,      -- show "Herd: <agent>" footer
    winblend = 0,
  },
})
```

## 🚀 Usage

| Key | Mode | Action |
| --- | --- | --- |
| `<leader><Tab>` | normal | Toggle this cwd's agent float (count = slot). Falls back to picker if no agent runs here. |
| `<leader><Tab>` | visual | Send the selection to the active agent (no Enter — review, then submit). |
| `<leader><Tab>` | terminal | Hide the float from inside the agent. |
| `<leader>;` | normal | Grouped picker: switch to any running agent, or spawn a configured tool. |
| `<leader>\` | normal | Open herdr's full TUI dashboard in a float. |

Also available as `:Herd [toggle|select|send|dashboard]`, `:Herd spawn <tool>`, and the
Lua API `require('herd').{toggle,select,send,dashboard,spawn}()`.

## 🧠 How it works

`herd` shells out to the `herdr` CLI. nvim is the host; herdr is a backend daemon:

| What | herdr command |
| --- | --- |
| discover agents | `herdr agent list` |
| spawn | `herdr agent start <name> --cwd <p> --workspace <ws> --no-focus -- <argv>` |
| placement | dedicated `herd` workspace, found-or-created via `herdr workspace list` / `herdr workspace create --no-focus --label herd` |
| show in nvim | nvim float running `herdr agent attach <name>` |
| send selection | `herdr agent send <name> <text>` |
| dashboard | focus the dedicated `herd` workspace (`herdr workspace focus <ws>`) |

Spawned agents are placed in a dedicated herdr workspace (default label `herd`) that lives off your project workspaces/tabs — so they never tile next to nvim when nvim runs inside a herdr session. The workspace is found-or-created automatically on each spawn; herdr auto-closes emptied tabs and the workspace is reused across spawns. The label is configurable via the `workspace` option.

Discovery is by agent **name**, which herdr preserves through its native agent
detection — so the tool you spawn is the tool `herd` finds again. Names are
server-global-unique, which is exactly why same-tool clones get numbered.

## ❓ FAQ

**Is this the same as sidekick.nvim?**
Same host model — nvim hosts the agents as floating terminals — but different backend:
herd uses **herdr** (not tmux/zellij), so you also get herdr's status hooks and the
grouped agent dashboard. If you already run herdr as your daemon, use herd. If you
prefer tmux/zellij as the backend, use sidekick.

**Do agents survive closing the float or quitting nvim?**
Yes. herdr owns the process; closing the float (or `:q`) only detaches the nvim
terminal. Run `<leader>;` (picker) or `:Herd select` to reattach — the picker lists
all live agents regardless of cwd. The dashboard (`<leader>\`) shows the full herdr
agent view.

**Nothing happens / "no herdr server running".**
Launch `herdr` first (any terminal or as a headless daemon). Run `:checkhealth herd`.

**Can I run multiple agents in one project?**
Yes. Picker → spawn a tool again; it'll be named `claude_2`, etc. Use `2<leader><Tab>`
to toggle directly to slot 2.

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent multiplexer this plugin drives.
- [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) — structure and UX
  inspiration.

## 📄 License

[MIT](./LICENSE)
