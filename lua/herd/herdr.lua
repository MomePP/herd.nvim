--- Thin client over the `herdr` CLI. Pure functions, no UI state.
--- All commands target herdr's default-session socket — the same server your
--- interactive `herdr` client is attached to.
local M = {}

--- Run a herdr CLI command. Returns stdout, or nil on failure.
---@param args string[]
---@param opts? { quiet?: boolean }
---@return string?
function M.run(args, opts)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    if not (opts or {}).quiet then
      vim.notify('herd: ' .. (res.stderr ~= '' and res.stderr or 'herdr command failed'), vim.log.levels.ERROR)
    end
    return nil
  end
  return res.stdout
end

--- Run a herdr command and return its decoded JSON `result`, or nil.
---@param args string[]
---@param opts? { quiet?: boolean }
---@return table?
function M.api(args, opts)
  local ok, decoded = pcall(vim.json.decode, M.run(args, opts) or '')
  return ok and decoded.result or nil
end

---@return boolean
function M.installed()
  return vim.fn.executable('herdr') == 1
end

--- `herdr status server` reports rc 0 in both states, so liveness is parsed.
---@return boolean
function M.server_running()
  local out = M.run({ 'status', 'server' }, { quiet = true })
  return out ~= nil and out:find('status: running', 1, true) ~= nil
end

---@class herd.Agent
---@field name string
---@field pane_id string
---@field status string
---@field cwd string

--- Live agents, optionally scoped to a spawn-cwd.
---@param cwd? string normalized cwd to filter by
---@return herd.Agent[]
function M.agents(cwd)
  local res = M.api({ 'agent', 'list' }, { quiet = true })
  local ret = {} ---@type herd.Agent[]
  for _, a in ipairs(res and res.agents or {}) do
    if not cwd or vim.fs.normalize(a.cwd or '') == cwd then
      ret[#ret + 1] = { name = a.name, pane_id = a.pane_id, status = a.agent_status, cwd = a.cwd }
    end
  end
  return ret
end

--- herdr agent names are server-global-unique, so a second `claude` needs a
--- distinct name. Picks `tool`, then `tool_2`, `tool_3`, ...
---@param tool string
---@return string
function M.next_name(tool)
  local taken = {}
  for _, a in ipairs(M.agents()) do
    taken[a.name] = true
  end
  if not taken[tool] then
    return tool
  end
  local i = 2
  while taken[tool .. '_' .. i] do
    i = i + 1
  end
  return tool .. '_' .. i
end

--- Spawn an agent in the herdr server.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@return herd.Agent?
function M.spawn(name, cwd, def)
  local args = { 'agent', 'start', name, '--cwd', cwd, '--no-focus' }
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  local res = M.api(args)
  return res and res.agent
end

---@param name string agent name or pane id
function M.focus(name)
  M.run({ 'agent', 'focus', name }, { quiet = true })
end

--- Zoom a pane fullscreen (no-op unless the tab has ≥2 panes).
---@param pane string
function M.zoom(pane)
  M.run({ 'pane', 'zoom', '--on', '--pane', pane }, { quiet = true })
end

---@param pane string
---@param text string
function M.send_text(pane, text)
  M.run({ 'pane', 'send-text', pane, text })
end

return M
