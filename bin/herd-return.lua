--- herd-return — jump from the focused herdr agent tab back to the editor
--- tab that spawned it. Run headlessly via `nvim -l`, bound herdr-side in
--- ~/.config/herdr/config.toml:
---
---   [[keys.command]]
---   key = "prefix+s"
---   type = "shell"
---   command = "nvim -l /path/to/herd.nvim/bin/herd-return.lua"
---
--- Stateless: reads live herdr state, resolves via lua/herd/origin.lua, and
--- either focuses the origin tab or shows a herdr notification. Exits 0
--- silently when the server is unreachable (a notification is impossible
--- then, and a keypress must never surface a stack trace).

-- Resolve the plugin root from this script's own path so `require` finds
-- lua/herd/origin.lua no matter where the herdr command runs from.
local self_path = vim.fn.fnamemodify(arg[0] or debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fs.dirname(vim.fs.dirname(self_path))
package.path = ('%s/lua/?.lua;%s'):format(root, package.path)
local Origin = require('herd.origin')

--- `herdr <args>` → decoded JSON `result`, or nil (server down / bad output).
---@param args string[]
---@return table?
local function api(args)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout or '')
  return ok and decoded.result or nil
end

local tabs = api({ 'tab', 'list' })
local panes = api({ 'pane', 'list' })
local agents = api({ 'agent', 'list' })
if not (tabs and panes and agents) then
  return -- herdr unreachable: exit silently
end

local tab_id, reason = Origin.resolve(tabs.tabs or {}, panes.panes or {}, agents.agents or {})
if tab_id then
  api({ 'tab', 'focus', tab_id })
else
  api({ 'notification', 'show', 'herd: ' .. (reason or 'no origin editor here') })
end
