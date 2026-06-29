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

--- Reap dead tabs in `ws_id`: when an agent's process exits, herdr removes the
--- pane but leaves the (now agentless) tab behind. Close every tab in the
--- workspace that no live agent occupies. `keep_tab` is never closed (the tab of
--- an agent just spawned, which may not be in `agent list` yet).
---@param ws_id string
---@param keep_tab? string tab id to always keep
function M.prune_workspace(ws_id, keep_tab)
  local agents = M.api({ 'agent', 'list' }, { quiet = true })
  local live = {}
  for _, a in ipairs(agents and agents.agents or {}) do
    if a.tab_id then
      live[a.tab_id] = true
    end
  end
  local tabs = M.api({ 'tab', 'list', '--workspace', ws_id }, { quiet = true })
  for _, t in ipairs(tabs and tabs.tabs or {}) do
    if t.tab_id and t.tab_id ~= keep_tab and not live[t.tab_id] then
      M.run({ 'tab', 'close', t.tab_id }, { quiet = true })
    end
  end
end

--- Label of the focused workspace (nvim's project at spawn time), excluding the
--- given label (the herd workspace itself). Lets spawned agents tag their tab
--- with the originating project. Returns nil if unresolved.
---@param exclude? string label to ignore
---@return string?
function M.focused_workspace_label(exclude)
  local list = M.api({ 'workspace', 'list' }, { quiet = true })
  for _, w in ipairs(list and list.workspaces or {}) do
    if w.focused and w.label ~= exclude then
      return w.label
    end
  end
  return nil
end

--- Spawn an agent in the herdr server, placed in `workspace` (off nvim's view)
--- when given. When `tab_label` is also given the agent gets its own labelled
--- tab in that workspace, so the herdr sidebar reads "<workspace> · <project>"
--- instead of just the bare workspace. nvim hosts; the agent is only ever seen
--- through the float that attaches to it.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param workspace? string workspace id to place the agent in
---@param tab_label? string label for the agent's own tab (e.g. the project)
---@return herd.Agent?
function M.spawn(name, cwd, def, workspace, tab_label)
  local tab
  if workspace and tab_label then
    local res = M.api({ 'tab', 'create', '--workspace', workspace, '--no-focus', '--cwd', cwd, '--label', tab_label })
    tab = res and res.tab and res.tab.tab_id
  end
  local args = { 'agent', 'start', name, '--cwd', cwd, '--no-focus' }
  if tab then
    vim.list_extend(args, { '--tab', tab })
  elseif workspace then
    vim.list_extend(args, { '--workspace', workspace })
  end
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  local started = M.api(args)
  local agent = started and started.agent
  -- The per-agent tab also holds the tab's initial empty pane, so the agent
  -- starts split. Zoom the agent's pane so it fills the tab when viewed in herdr.
  if agent and tab and agent.pane_id then
    M.api({ 'pane', 'zoom', agent.pane_id, '--on' })
  end
  return agent
end

--- argv to attach an nvim :terminal to a running agent's PTY (clean stream).
--- `target` should be the unambiguous pane id (a bare tool name like "claude"
--- can be ambiguous when herdr also detects same-tool processes).
---@param target string pane id (preferred) or unique agent name
---@return string[]
function M.attach_argv(target)
  return { 'herdr', 'agent', 'attach', target }
end

--- Focus a workspace in the herdr client (used to surface the agent pool).
---@param id string workspace id
function M.focus_workspace(id)
  M.run({ 'workspace', 'focus', id }, { quiet = true })
end

--- Send literal text to an agent (no Enter — review then submit).
---@param target string pane id (preferred) or unique agent name
---@param text string
function M.agent_send(target, text)
  M.run({ 'agent', 'send', target, text })
end

return M
