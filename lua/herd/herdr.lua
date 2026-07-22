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

--- Decode a herdr JSON envelope into its `result` table, or nil.
--- Type guard: a bare JSON `null` decodes to vim.NIL (userdata), not a table,
--- so `decoded.result` would throw outside the pcall. A `{"result": null}`
--- envelope decodes to a table whose `.result` is vim.NIL — truthy in Lua, so
--- returning it would make callers' `res and res.foo` index a userdata and
--- throw. Normalize both to nil; every caller already treats nil as absent.
---@param stdout string?
---@return table?
local function decode_result(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout or '')
  if not (ok and type(decoded) == 'table') or decoded.result == vim.NIL then
    return nil
  end
  return decoded.result
end

--- Run a herdr command and return its decoded JSON `result`, or nil.
---@param args string[]
---@param opts? { quiet?: boolean }
---@return table?
function M.api(args, opts)
  return decode_result(M.run(args, opts))
end

--- Async `api` for the slow calls: `agent start` blocks on the server-side
--- readiness handshake (seconds for slow CLIs), and a :wait() there freezes
--- nvim's UI for the duration. Runs off the main loop; `cb` gets the decoded
--- `result` (or nil, after the same error notification `run` gives) back on
--- the main loop.
---@param args string[]
---@param cb fun(res: table?)
function M.api_async(args, cb)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify('herd: ' .. (res.stderr ~= '' and res.stderr or 'herdr command failed'), vim.log.levels.ERROR)
        return cb(nil)
      end
      cb(decode_result(res.stdout))
    end)
  end)
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

--- The herdr agent kind for `def`: explicit `def.kind`, else the basename of
--- the executable (a plain `claude` or `/usr/local/bin/opencode` both resolve;
--- a wrapper binary whose name isn't a supported kind needs `def.kind`).
---@param def herd.Tool
---@return string
local function tool_kind(def)
  return def.kind or vim.fs.basename(def.cmd[1])
end

--- Build `agent start` argv (herdr ≥ 0.7.5): the agent is started by kind in
--- an existing pane; anything after `--` is passed to the CLI natively. cwd
--- and env are the pane's (set at `tab create`), not flags here.
---@param name string unique agent name
---@param def herd.Tool
---@param pane string pane id at a shell prompt (the tab's root pane)
---@return string[]
local function start_args(name, def, pane)
  local args = { 'agent', 'start', name, '--kind', tool_kind(def), '--pane', pane }
  if #def.cmd > 1 then
    args[#args + 1] = '--'
    for i = 2, #def.cmd do
      args[#args + 1] = def.cmd[i]
    end
  end
  return args
end

--- Spawn an agent in the herdr server, placed in `workspace` (off nvim's view)
--- when given, labelled `tab_label` when given. The tab carries the cwd and
--- `def.env` (its shell inherits them, and so does the agent), and its root
--- pane is where the agent starts — the agent fills the tab, nothing spare to
--- close. nvim hosts; the agent is only ever seen through the float that
--- attaches to it.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param workspace? string workspace id to place the agent in (default: focused)
---@param tab_label? string label for the agent's own tab (e.g. the project)
---@param focus? boolean focus the tab as soon as it exists (native mode)
---@param on_done fun(agent: herd.Agent?) called on the main loop once the
--- readiness handshake completes (nil on failure — error already notified)
function M.spawn(name, cwd, def, workspace, tab_label, focus, on_done)
  local args = { 'tab', 'create', '--cwd', cwd, '--no-focus' }
  if workspace then
    vim.list_extend(args, { '--workspace', workspace })
  end
  if tab_label then
    vim.list_extend(args, { '--label', tab_label })
  end
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  local created = M.api(args)
  local tab = created and created.tab and created.tab.tab_id
  local pane = created and created.root_pane and created.root_pane.pane_id
  if not (tab and pane) then
    return on_done(nil) -- error already surfaced by Herdr.run
  end
  if focus then
    -- Surface the tab BEFORE the readiness handshake below: `agent start`
    -- blocks until the CLI is detected interactive-ready (seconds for slow
    -- tools), and watching it boot in its own tab is the feedback that the
    -- spawn is happening — the pre-0.7.5 timing, when `agent start` returned
    -- immediately. On a failed start the user is left on the shell tab with
    -- the error notification, which is also the honest view.
    M.run({ 'tab', 'focus', tab }, { quiet = true })
  end
  M.api_async(start_args(name, def, pane), function(started)
    local agent = started and started.agent
    if agent then
      agent.tab_id = agent.tab_id or tab
    end
    on_done(agent)
  end)
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
--- mode) instead of a dedicated hidden workspace: the caller's
--- `$HERDR_WORKSPACE_ID`, so the tab lands in the real project workspace
--- nvim's own pane already lives in.
---
--- The tab is labelled `<project>:<name>` (e.g. `dotfiles:claude_2`) so the
--- herdr sidebar shows which project's agent it is when several projects share
--- a workspace, and so `prune_workspace` can reap only *this* project's dead
--- agent tabs via the `<project>:` label prefix (nvim's own tab is labelled
--- just `<project>`, no trailing colon, so it is never reaped).
---
--- The return trip on agent exit belongs to herd.watch (the agent's pane
--- outlives the agent on herdr ≥ 0.7.5, so it is decidable post-exit).
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@param project string label of nvim's own tab (or cwd basename); tab prefix
---@param on_done fun(agent: herd.Agent?) see `spawn`
function M.spawn_native(name, cwd, def, project, on_done)
  return M.spawn(name, cwd, def, vim.env.HERDR_WORKSPACE_ID, project .. ':' .. name, true, on_done)
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

--- Send literal text to an agent's pane (no Enter — review then submit).
--- `pane send-text` since 0.7.5; the old `agent send` is gone, and its
--- replacement `agent send-keys` takes key names, not literal text.
---@param target string pane id
---@param text string
function M.agent_send(target, text)
  M.run({ 'pane', 'send-text', target, text })
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
