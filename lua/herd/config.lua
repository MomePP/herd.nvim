local M = {}

---@class herd.Tool
---@field cmd string[]                  argv to launch the CLI agent
---@field env? table<string, string>    extra environment for the agent process

---@class herd.Keys
---@field toggle string|false   normal: toggle this cwd's agent float (count = slot)
---@field send string|false     visual: send the selection to the active agent
---@field hide string|false     terminal: hide the float from inside
---@field select string|false   normal: grouped picker (switch / spawn)
---@field dashboard string|false normal: focus the dedicated herd workspace in herdr
---@field newline string|false  terminal: send a CLI newline (Shift-Enter) to the agent

---@class herd.Win
---@field width number    fraction of columns (0..1)
---@field height number   fraction of lines (0..1)
---@field border string   nvim_open_win border style
---@field footer boolean  show "Herd: <agent>" footer
---@field winblend number terminal-window blend
---@field winhighlight string  winhighlight applied to the float (e.g. terminal-bg groups)
---@field mouse boolean  true: nvim owns the mouse in the float (agent gets scroll/click,
---                      use Shift+drag to select). false: hand the mouse to the terminal
---                      while a float is focused so a plain drag selects natively (the
---                      agent loses its mouse inside the float).

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field mode 'float'|'native'  display backend: 'float' (default) hosts each
---                    agent in an nvim floating terminal; 'native' shows it as
---                    a sibling herdr tab in nvim's own workspace instead —
---                    requires nvim to run inside a herdr pane. `win.*` and
---                    `keys.hide`/`keys.newline` only apply to 'float'.
---@field picker 'auto'|'select'  renderer for the GLOBAL agent picker (the
---                    native-mode dashboard): 'auto' (default) uses
---                    Snacks.picker (full layout + live-output preview pane)
---                    when snacks.nvim is installed, plain vim.ui.select
---                    otherwise; 'select' forces vim.ui.select even with
---                    snacks installed. The project picker (`keys.select`)
---                    always uses vim.ui.select.
---@field keys herd.Keys
---@field win herd.Win
---@field workspace string  herdr workspace label that hosts spawned agents
---@field send { context: boolean|fun(ctx: table): string }  visual send: true
---                    (default) wraps the selection as `path:lines` + a
---                    filetype-fenced block so the agent knows where the code
---                    lives; false sends raw text; a function(ctx) formats it,
---                    where ctx = { path, ft, sline, eline, text }.
---@field auto_return boolean  true (default) arms an exit watcher when native
---                    mode focuses an agent: if the agent process ends while
---                    you are on its tab, herdr jumps back to nvim's tab and
---                    the empty tab is reaped. Disarmed when nvim regains
---                    focus. Native-only; float mode auto-closes on its own.
---@field reload boolean  true (default) runs `checktime` when nvim regains
---                    focus (and, in float mode, on leaving an agent float) so
---                    buffers the agent edited reload instead of going stale.

---@type herd.Config
local defaults = {
  tools = {},
  mode = 'float', -- 'native' requires nvim to run inside a herdr pane; see README
  picker = 'auto', -- global/dashboard picker only; 'select' forces plain vim.ui.select
  workspace = 'herd.nvim', -- dedicated workspace label; signals nvim-spawned agents
  send = {
    -- true wraps the visual selection with its `path:lines` header and a
    -- filetype fence; false sends raw text; a function(ctx) formats it.
    context = true,
  },
  reload = true, -- checktime on return so agent-edited buffers refresh
  auto_return = true, -- native mode: jump back to nvim when the focused agent exits
  keys = {
    -- leader-doubled scheme: <leader>\ (leader is '\' → a double-tap) drives the
    -- active agent across modes; s/S open the pickers. In native mode the herdr
    -- side mirrors it: prefix+\ (herd-return) jumps back to the editor.
    toggle = '<leader>\\', -- (normal) toggle this cwd's agent; count = slot
    send = '<leader>\\',   -- (visual) send selection to the active agent
    hide = '<leader>\\',   -- (terminal) hide the float from inside
    select = '<leader>s',  -- (normal) grouped picker (switch / spawn)
    dashboard = '<leader>S', -- (normal) global agent picker (native) / herd workspace (float)
    newline = '<S-CR>',    -- (terminal) send a CLI newline (kitty Shift-Enter) to the agent
  },
  win = {
    -- fullscreen float with an invisible border (only the bottom row is kept, for
    -- the footer). Set `winhighlight` to your terminal highlight groups for a
    -- transparent overlay (e.g. Snacks: Normal:SnacksTerminalNormal,...).
    width = 1,
    height = 1,
    border = { '', '', '', '', ' ', ' ', ' ', '' },
    footer = true,
    winblend = 0,
    winhighlight = '',
    mouse = true, -- false hands the mouse to the terminal in floats (plain-drag selection)
  },
}

---@type herd.Config?
M.options = nil

---@param opts? herd.Config
---@return herd.Config
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend('force', defaults, opts)
  -- `border` is a list; deep_extend merges lists by index, so a partial override
  -- (e.g. `border = { '│' }`) would splice into the 8-element default rather than
  -- replace it. Take a user-supplied border verbatim.
  if opts.win and opts.win.border ~= nil then
    M.options.win.border = opts.win.border
  end
  return M.options
end

---@return herd.Config
function M.get()
  return M.options or M.setup({})
end

return M
