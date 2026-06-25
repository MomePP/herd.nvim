local M = {}

---@class herd.Tool
---@field cmd string[]                  argv to launch the CLI agent
---@field env? table<string, string>    extra environment for the agent process

---@class herd.Keys
---@field toggle string   normal: go to a live agent fullscreen / spawn
---@field send string     visual: send the selection to the active agent
---@field select string   normal: switch to an agent, or spawn a tool

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field keys herd.Keys
---@field zoom boolean    zoom the agent pane fullscreen on toggle/spawn

---@type herd.Config
local defaults = {
  tools = {},
  keys = {
    toggle = '<leader><Tab>',
    send = '<leader>s',
    select = '<leader>S',
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
