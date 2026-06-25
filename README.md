# 🐑 herd.nvim

> Drive [herdr](https://herdr.dev) coding agents from Neovim — when **herdr is the host**.

`herd.nvim` is a tiny companion for [herdr](https://herdr.dev), the terminal-native
**agent multiplexer**. It assumes the idiomatic herdr layout — herdr is your
multiplexer, **nvim lives in one pane**, and your CLI agents (`claude`, `opencode`, …)
live in sibling panes — and gives you back the ergonomics you'd miss from an
in-editor agent plugin:

- **Spawn** a CLI agent and **zoom it fullscreen** with one key.
- **Toggle** to a running agent; when the one you used stops, fall back to another
  that's still running.
- **Send the visual selection** straight to the active agent.

It talks to the `herdr` CLI only — there is **no embedded terminal**, no second
multiplexer, nothing to keep in sync. herdr stays the host; nvim just points at it.

> Inspired by [`folke/sidekick.nvim`](https://github.com/folke/sidekick.nvim). Where
> sidekick makes **nvim the host** (agents summoned as floats), herd takes the
> opposite, herdr-native stance: **herdr is the host**, nvim is a pane.

## ✨ Features

- 🚀 **Spawn + fullscreen** — `<leader><Tab>` / `:Herd` starts a tool and zooms it.
- ♻️ **Smart toggle** — reuses your last agent; if it died, lands on another live one;
  if none are running, opens the spawn picker.
- ✂️ **Send selection** — `<leader>s` in visual mode pushes the selection to the agent.
- 🔢 **Multiple agents per project** — herdr agent names are globally unique, so a
  second `claude` becomes `claude_2`, `claude_3`, … automatically.
- 🩺 **`:checkhealth herd`** — verifies herdr, the server, the pane, and your tools.
- 🪶 **Tiny** — three small Lua files, one external dependency (the `herdr` binary).

## 📋 Requirements

- Neovim **≥ 0.10** (uses `vim.fn.getregion()`)
- [herdr](https://herdr.dev/docs/install/) **≥ 0.7** on `$PATH`
- A running herdr server you're attached to — i.e. launch `herdr` and run nvim
  inside one of its panes.

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

  -- Keymaps (set any to false-y by overriding; or remap to taste).
  keys = {
    toggle = '<leader><Tab>', -- normal: toggle agent fullscreen / spawn
    send   = '<leader>s',     -- visual: send selection to the active agent
    select = '<leader>S',     -- normal: pick an agent to switch to, or a tool to spawn
  },

  -- Zoom the agent pane fullscreen on toggle/spawn.
  zoom = true,
})
```

## 🚀 Usage

| Key | Mode | Action |
| --- | --- | --- |
| `<leader><Tab>` | normal | Toggle to a running agent, fullscreen. None running → spawn picker. |
| `<leader>s` | visual | Send the selection to the active agent (no Enter — review, then submit). |
| `<leader>S` | normal | Picker: switch to a running agent, or spawn a configured tool. |

Also available as `:Herd [toggle|select|send]` and the Lua API
`require('herd').{toggle,select,send,spawn}()`.

### The return trip ⟲ (important)

`herd` can take you **to** an agent, but it **cannot bring you back** — once the agent
pane is focused, Neovim no longer receives keystrokes, so `<leader>` can't reach it.
That half belongs to herdr. Bind it in `~/.config/herdr/config.toml`:

```toml
[keys]
last_pane = "prefix+tab"   # Ctrl-b Tab from the agent → back to nvim
```

So the full loop is symmetric:

```
nvim  ──<leader><Tab>──▶  agent (fullscreen)
nvim  ◀──Ctrl-b Tab────   agent
```

Same `Tab` gesture both ways — two different owners, because herdr is the host.

## 🧠 How it works

`herd` shells out to the `herdr` CLI:

| What | herdr command |
| --- | --- |
| discover agents | `herdr agent list` (name, pane id, status, cwd) |
| spawn | `herdr agent start <name> --cwd <p> -- <argv>` |
| focus + fullscreen | `herdr agent focus <name>` + `herdr pane zoom --on` |
| send selection | `herdr pane send-text <pane> <text>` |

Discovery is by agent **name**, which herdr preserves through its native agent
detection — so the tool you spawn is the tool `herd` finds again. Names are
server-global-unique, which is exactly why same-tool clones get numbered.

## ❓ FAQ

**Is this the same as sidekick.nvim?**
No — it's the inverse. sidekick makes nvim the host and runs agents as floating
terminals (using tmux/zellij underneath). herd assumes **herdr** is the host and
nvim is a pane. If you want nvim-as-host, use sidekick. If you've adopted herdr as
your multiplexer, use herd.

**Why can't one key toggle both directions?**
Because `<leader>` only exists inside nvim. When the agent pane has focus, the
keyboard goes to the agent's TUI; only herdr's global prefix is intercepted. See
[The return trip](#the-return-trip-).

**Nothing happens / "no herdr server running".**
Launch `herdr` first and run nvim inside one of its panes. Run `:checkhealth herd`.

**Can I run multiple agents in one project?**
Yes. `<leader>S` → pick a tool to spawn again; it'll be named `claude_2`, etc.

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent multiplexer this plugin drives.
- [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) — structure and UX
  inspiration.

## 📄 License

[MIT](./LICENSE)
