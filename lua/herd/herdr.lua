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
  -- type guard: a bare JSON `null` decodes to vim.NIL (userdata), not a table,
  -- so `decoded.result` would throw outside the pcall. A `{"result": null}`
  -- envelope decodes to a table whose `.result` is vim.NIL — truthy in Lua, so
  -- returning it would make callers' `res and res.foo` index a userdata and
  -- throw. Normalize both to nil; every caller already treats nil as absent.
  if not (ok and type(decoded) == 'table') or decoded.result == vim.NIL then
    return nil
  end
  return decoded.result
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
---@field tab_id string
---@field workspace_id string
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
      ret[#ret + 1] = {
        name = a.name,
        pane_id = a.pane_id,
        tab_id = a.tab_id,
        workspace_id = a.workspace_id,
        status = a.agent_status,
        cwd = a.cwd,
      }
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
---
--- `label_prefix` guards native mode, where `ws_id` is nvim's *own* project
--- workspace (shared with nvim's host tab and sibling projects' tabs, none of
--- which host an agent): when set (the `<project>:` prefix, see `spawn_native`),
--- only agentless tabs whose label starts with it — this project's own dead
--- agent tabs — are reaped. nvim's own tab is labelled just `<project>` (no
--- trailing colon), so it is never matched. When nil (float mode's dedicated
--- workspace holds only herd agent tabs) every agentless tab is reaped, unchanged.
---@param ws_id string
---@param keep_tab? string tab id to always keep
---@param label_prefix? string only reap agentless tabs whose label starts here
function M.prune_workspace(ws_id, keep_tab, label_prefix)
  local agents = M.api({ 'agent', 'list' }, { quiet = true })
  local live = {}
  for _, a in ipairs(agents and agents.agents or {}) do
    if a.tab_id then
      live[a.tab_id] = true
    end
  end
  local tabs = M.api({ 'tab', 'list', '--workspace', ws_id }, { quiet = true })
  for _, t in ipairs(tabs and tabs.tabs or {}) do
    local owned = not label_prefix or (t.label ~= nil and vim.startswith(t.label, label_prefix))
    if t.tab_id and t.tab_id ~= keep_tab and not live[t.tab_id] and owned then
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

--- Build `agent start` argv: base flags + `placement` (the flags that position
--- the agent — `{'--tab', id}`, `{'--workspace', id}`, or `{}` for the default
--- workspace) + one `--env` per `def.env` entry + `-- <cmd>`.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param placement string[]
---@return string[]
local function start_args(name, cwd, def, placement)
  local args = { 'agent', 'start', name, '--cwd', cwd, '--no-focus' }
  vim.list_extend(args, placement)
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  return args
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
  local placement = tab and { '--tab', tab } or workspace and { '--workspace', workspace } or {}
  local started = M.api(start_args(name, cwd, def, placement))
  local agent = started and started.agent
  -- `tab create` leaves an empty initial pane, so `agent start --tab` lands the
  -- agent as a *second* pane (a split). Close that spare pane so the agent is the
  -- sole pane — it then fills the tab (fullscreen in herdr) and the tab label
  -- shows in the sidebar, without zooming (which steals focus out of nvim).
  if agent and tab and workspace and agent.pane_id then
    local panes = M.api({ 'pane', 'list', '--workspace', workspace })
    for _, p in ipairs(panes and panes.panes or {}) do
      if p.tab_id == tab and p.pane_id ~= agent.pane_id then
        M.api({ 'pane', 'close', p.pane_id })
      end
    end
  end
  return agent
end

--- Label of a tab (e.g. nvim's own tab, via `$HERDR_TAB_ID`), or nil. Used to
--- name native agent tabs after the project nvim sits in (`<label>:<agent>`).
---@param tab_id string
---@return string?
function M.tab_label(tab_id)
  local res = M.api({ 'tab', 'get', tab_id }, { quiet = true })
  return res and res.tab and res.tab.label
end

--- Map of workspace_id → label, from one `workspace list` call. Used by the
--- global picker to render cross-workspace agent rows.
---@return table<string, string>
function M.workspace_labels()
  local list = M.api({ 'workspace', 'list' }, { quiet = true })
  local ret = {}
  for _, w in ipairs(list and list.workspaces or {}) do
    ret[w.workspace_id] = w.label
  end
  return ret
end

--- Map of tab_id → label, from one `tab list` call (all workspaces). Used by
--- the global picker: a native agent tab's label (`<project>:<agent>`) already
--- names both the project and the agent.
---@return table<string, string>
function M.tab_labels()
  local list = M.api({ 'tab', 'list' }, { quiet = true })
  local ret = {}
  for _, t in ipairs(list and list.tabs or {}) do
    ret[t.tab_id] = t.label
  end
  return ret
end

--- Spawn an agent as a sibling herdr tab in nvim's own workspace (native
--- mode) instead of a dedicated hidden workspace: `tab create` (no explicit
--- `--workspace`; caller's `$HERDR_WORKSPACE_ID`, so the tab lands in the
--- real project workspace nvim's own pane already lives in) → `agent start
--- --tab` → close the spare pane the tab was created with, using the pane id
--- `tab create` already returned (no `pane list` round trip needed).
---
--- The tab is labelled `<project>:<name>` (e.g. `dotfiles:claude_2`) so the
--- herdr sidebar shows which project's agent it is when several projects share
--- a workspace, and so `prune_workspace` can reap only *this* project's dead
--- agent tabs via the `<project>:` label prefix (nvim's own tab is labelled
--- just `<project>`, no trailing colon, so it is never reaped).
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param project string label of nvim's own tab (or cwd basename); tab prefix
---@return herd.Agent?
function M.spawn_native(name, cwd, def, project)
  local ws = vim.env.HERDR_WORKSPACE_ID
  local label = project .. ':' .. name
  local created = M.api({ 'tab', 'create', '--workspace', ws, '--cwd', cwd, '--label', label, '--no-focus' })
  local tab = created and created.tab and created.tab.tab_id
  if not tab then
    return nil -- error already surfaced by Herdr.run; no safe fallback placement
  end
  local spare_pane = created.root_pane and created.root_pane.pane_id
  local started = M.api(start_args(name, cwd, def, { '--tab', tab }))
  local agent = started and started.agent
  if agent then
    agent.tab_id = tab
    if spare_pane then
      M.api({ 'pane', 'close', spare_pane })
    end
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

--- Focus an agent by its unambiguous pane id — herdr switches the visible tab
--- (and workspace, when the agent lives elsewhere) to the agent's pane. Used
--- by native mode; the agent-first equivalent of `tab focus`, verified
--- behaviorally identical against a live server.
---@param target string pane id (preferred) or unique agent name
function M.agent_focus(target)
  M.run({ 'agent', 'focus', target }, { quiet = true })
end

--- Send literal text to an agent (no Enter — review then submit).
---@param target string pane id (preferred) or unique agent name
---@param text string
function M.agent_send(target, text)
  M.run({ 'agent', 'send', target, text })
end

--- Recent visible output of an agent's pane, as plain text — used by the
--- snacks picker's preview pane to show what an agent is doing.
---@param pane_id string
---@return string?
---@param pane_id string
---@param opts? { source?: 'visible'|'recent'|'recent-unwrapped', lines?: integer }
---@return string?
function M.agent_read(pane_id, opts)
  opts = opts or {}
  local args = { 'agent', 'read', pane_id, '--source', opts.source or 'visible', '--format', 'text' }
  if opts.lines then
    vim.list_extend(args, { '--lines', tostring(opts.lines) })
  end
  local res = M.api(args, { quiet = true })
  return res and res.read and res.read.text
end

return M
