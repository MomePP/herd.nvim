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
    -- herdr also lists DETECTED agents with no assigned name (a coding-agent
    -- process it spotted in some pane). herd targets by name, so skip the
    -- nameless ones — they break next_name / picker labels and aren't reachable.
    if a.name and (not cwd or vim.fs.normalize(a.cwd or '') == cwd) then
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

--- Clone slot name: slot 1 is the base, slot n>1 is `base_n`.
---@param base string
---@param n integer
---@return string
function M.slot_name(base, n)
  return n <= 1 and base or (base .. '_' .. n)
end

--- Find-or-create the dedicated workspace that hosts herd agents (kept off the
--- user's project workspaces/tabs). Matched by label. Returns its id, or nil.
---@param label string
---@return string?
function M.ensure_workspace(label)
  local list = M.api({ 'workspace', 'list' }, { quiet = true })
  for _, w in ipairs(list and list.workspaces or {}) do
    if w.label == label then
      return w.workspace_id
    end
  end
  local created = M.api({ 'workspace', 'create', '--no-focus', '--label', label })
  return created and created.workspace and created.workspace.workspace_id
end

--- Spawn an agent in the herdr server, placed in `workspace` (off nvim's view)
--- when given. nvim hosts; the agent is only ever seen through the float that
--- attaches to it.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param workspace? string workspace id to place the agent in
---@return herd.Agent?
function M.spawn(name, cwd, def, workspace)
  local args = { 'agent', 'start', name, '--cwd', cwd, '--no-focus' }
  if workspace then
    vim.list_extend(args, { '--workspace', workspace })
  end
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  local res = M.api(args)
  return res and res.agent
end

--- argv to attach an nvim :terminal to a running agent's PTY (clean stream).
---@param name string
---@return string[]
function M.attach_argv(name)
  return { 'herdr', 'agent', 'attach', name }
end

--- Focus a workspace in the herdr client (used to surface the agent pool).
---@param id string workspace id
function M.focus_workspace(id)
  M.run({ 'workspace', 'focus', id }, { quiet = true })
end

--- Send literal text to an agent (no Enter — review then submit).
---@param name string
---@param text string
function M.agent_send(name, text)
  M.run({ 'agent', 'send', name, text })
end

return M
