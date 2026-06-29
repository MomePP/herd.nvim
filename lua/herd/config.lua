local M = {}

---@class herd.Tool
---@field cmd string[]                  argv to launch the CLI agent
---@field env? table<string, string>    extra environment for the agent process

---@class herd.Keys
---@field toggle string|false  normal: go to a live agent / spawn (false = disabled)
---@field send string|false    visual: send the selection to the active agent
---@field select string|false  normal: switch to an agent, or spawn a tool

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field keys herd.Keys
---@field zoom boolean    zoom the agent pane fullscreen on toggle/spawn

---@type herd.Config
local defaults = {
  tools = {},
  keys = {
    -- herd is a spawner; navigation (nvim <-> agent) is left to your multiplexer
    -- (e.g. herdr directional pane focus). Set `toggle` to a key to opt back in.
    toggle = false, -- (normal) jump to this cwd's agent / spawn — off by default
    send = '<leader><Tab>', -- (visual) send selection to the active agent
    select = '<leader><Tab>', -- (normal) pick a running agent or spawn a tool
  },
  zoom = true,
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
