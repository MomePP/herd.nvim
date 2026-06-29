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

- 🚀 **Spawn + fullscreen** — `<leader><Tab>` (normal) picks/spawns a tool and zooms it.
- ✂️ **Send selection** — `<leader><Tab>` in visual mode pushes the selection to the agent.
- 🧭 **Navigation stays in your multiplexer** — jump nvim↔agent with your terminal's
  pane focus (e.g. herdr `Ctrl-a h`/`l`); opt into an in-editor `toggle` key if you want.
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

  -- Keymaps. Set any to `false` to disable it.
  keys = {
    toggle = false,           -- (normal) jump to this cwd's agent / spawn — off by default
    send   = '<leader><Tab>', -- visual: send selection to the active agent
    select = '<leader><Tab>', -- normal: pick an agent to switch to, or a tool to spawn
  },

  -- Zoom the agent pane fullscreen on toggle/spawn.
  zoom = true,
})
```

## 🚀 Usage

| Key | Mode | Action |
| --- | --- | --- |
| `<leader><Tab>` | normal | Picker: switch to a running agent, or spawn a configured tool (zoomed). |
| `<leader><Tab>` | visual | Send the selection to the active agent (no Enter — review, then submit). |
| `<leader><Tab>`¹ | normal | *(opt-in `toggle`)* jump straight to this cwd's agent / spawn if none. |

¹ `toggle` is disabled by default — navigation is left to your multiplexer (see below).
Set `keys.toggle` to a key to enable the in-editor jump.

Also available as `:Herd [toggle|select|send]` and the Lua API
`require('herd').{toggle,select,send,spawn}()`.

### Navigation ⟲ (important)

herd is a **spawner**, not a navigator — once the agent pane is focused, Neovim no
longer receives keystrokes (so `<leader>` can't reach it), and moving between nvim and
the agent is best handled by your multiplexer anyway. That's why `toggle` is **off by
default**.

herd spawns the agent as a **split in nvim's tab** (nvim-left / agent-right), so use
herdr's **directional pane focus** — it's tab-scoped, so it always lands on the right
pane regardless of which workspace you're in (unlike `last_pane`, which is global):

```
nvim  ──<leader><Tab>──▶  agent   (spawn/pick → lands you in the agent, zoomed)
nvim  ◀──prefix+h──       agent   (focus pane left  = nvim)
nvim  ──prefix+l──▶       agent   (focus pane right = agent)
```

> Avoid herdr's `last_pane` / `cycle_pane_*` for this — they're global / cycle-based,
> so after switching workspaces they won't reliably return to *this* project's agent.

#### Pairing herdr config

The directional keys above are herdr defaults; `prefix` is whatever you set (herdr's
default is `ctrl+b`). A minimal pairing in `~/.config/herdr/config.toml`:

```toml
[keys]
prefix           = "ctrl+a"   # optional — e.g. match tmux muscle memory
focus_pane_left  = "prefix+h" # → nvim
focus_pane_right = "prefix+l" # → agent
focus_pane_down  = "prefix+j"
focus_pane_up    = "prefix+k"
```

Prefer an in-editor jump instead? Re-enable `toggle` in setup
(`keys = { toggle = '<leader>;' }`) and pair it with a herdr `last_pane` binding for
the way back — just note the cwd/workspace caveat above.

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

**Why doesn't herd map a "go to agent" key by default?**
Because `<leader>` only exists inside nvim — once the agent pane has focus, the
keyboard goes to the agent's TUI and only your multiplexer's prefix is intercepted.
So the round trip can't be symmetric from nvim alone; navigation belongs to herdr
(`prefix+h`/`l`). See [Navigation](#navigation--important). You can still opt into an
in-editor `toggle` key.

**Nothing happens / "no herdr server running".**
Launch `herdr` first and run nvim inside one of its panes. Run `:checkhealth herd`.

**Can I run multiple agents in one project?**
Yes. `<leader><Tab>` → pick a tool to spawn again; it'll be named `claude_2`, etc.

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent multiplexer this plugin drives.
- [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) — structure and UX
  inspiration.

## 📄 License

[MIT](./LICENSE)
