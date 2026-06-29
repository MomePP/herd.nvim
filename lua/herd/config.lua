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

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field keys herd.Keys
---@field win herd.Win
---@field workspace string  herdr workspace label that hosts spawned agents

---@type herd.Config
local defaults = {
  tools = {},
  workspace = 'herd',
  keys = {
    toggle = '<leader><Tab>',    -- (normal) toggle this cwd's agent; count = slot
    send = '<leader><Tab>',      -- (visual) send selection to the active agent
    hide = '<leader><Tab>',      -- (terminal) hide the float from inside
    select = '<leader>;',        -- (normal) grouped picker
    dashboard = '<leader>\\',    -- (normal) focus the dedicated herd workspace
    newline = '<S-CR>',          -- (terminal) send a CLI newline (kitty Shift-Enter) to the agent
  },
  win = {
    width = 0.9,
    height = 0.9,
    border = 'rounded',
    footer = true,
    winblend = 0,
    winhighlight = '',
  },
}

---@type herd.Config?
M.options = nil

---@param opts? herd.Config
---@return herd.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', defaults, opts or {})
  return M.options
end

---@return herd.Config
function M.get()
  return M.options or M.setup({})
end

return M
