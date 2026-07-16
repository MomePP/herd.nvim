--- Origin-editor resolution for the herd-return gesture (native mode).
--- Pure functions over already-decoded herdr `tab list` / `pane list` /
--- `agent list` tables — no CLI calls, no vim UI — so the logic is unit-
--- testable and shared by `bin/herd-return.lua`.
---
--- Native agent tabs are labelled `<origin-tab-label>:<agent>` at spawn
--- (see herdr.spawn_native); nvim's own tab is the bare `<origin-tab-label>`.
--- Resolution dereferences that link, falling back to the agent's spawn cwd.
local M = {}

--- Everything before the LAST colon of a native agent tab label, or nil.
--- Agent names (`next_name` output) never contain colons; editor tab labels
--- may — `a:b:claude` splits to `a:b`, not `a`.
---@param label string?
---@return string?
function M.label_prefix(label)
  if not label then
    return nil
  end
  local prefix = label:match('^(.*):[^:]*$')
  if prefix == nil or prefix == '' then
    return nil
  end
  return prefix
end

--- Resolve the origin editor tab for the globally focused pane.
--- Order: label link (sibling tab in the same workspace whose label equals
--- the focused tab's `<project>` prefix) → cwd fallback (a non-agent pane
--- in the same workspace whose spawn cwd equals the focused agent's).
---@param tabs table[] raw entries from `herdr tab list` (tab_id, label, workspace_id)
---@param panes table[] raw entries from `herdr pane list` (pane_id, tab_id, workspace_id, cwd, focused)
---@param agents table[] raw entries from `herdr agent list` (pane_id, cwd)
---@return string? tab_id origin tab to focus, or nil
---@return string? reason set when tab_id is nil
function M.resolve(tabs, panes, agents)
  local focused
  for _, p in ipairs(panes) do
    if p.focused then
      focused = p
      break
    end
  end
  if not focused then
    return nil, 'no focused pane'
  end

  local focused_agent, agent_panes = nil, {}
  for _, a in ipairs(agents) do
    agent_panes[a.pane_id] = true
    if a.pane_id == focused.pane_id then
      focused_agent = a
    end
  end

  -- 1) label link: focused tab "<project>:<agent>" → sibling tab "<project>"
  local focused_label
  for _, t in ipairs(tabs) do
    if t.tab_id == focused.tab_id then
      focused_label = t.label
      break
    end
  end
  local prefix = M.label_prefix(focused_label)
  if prefix then
    for _, t in ipairs(tabs) do
      if t.workspace_id == focused.workspace_id and t.tab_id ~= focused.tab_id and t.label == prefix then
        return t.tab_id
      end
    end
  end

  -- 2) cwd fallback: only meaningful when the focused pane hosts an agent
  if not focused_agent then
    return nil, 'not an agent pane'
  end
  for _, p in ipairs(panes) do
    if
      p.workspace_id == focused.workspace_id
      and p.tab_id ~= focused.tab_id
      and p.cwd == focused_agent.cwd
      and not agent_panes[p.pane_id]
    then
      return p.tab_id
    end
  end
  return nil, 'no origin editor here'
end

--- Pane id to target in the resolved origin tab (where the editor lives, or the
--- idle shell it left behind after nvim quit). First pane in the tab.
---@param panes table[] raw entries from `herdr pane list`
---@param tab_id string origin tab id (from resolve)
---@return string? pane_id
function M.editor_pane(panes, tab_id)
  for _, p in ipairs(panes) do
    if p.tab_id == tab_id then
      return p.pane_id
    end
  end
  return nil
end

--- Is nvim a foreground process in a pane's `pane process-info` result? Used to
--- tell a live editor from the idle shell it was quit to.
---@param process_info table? the `result.process_info` from `pane process-info`
---@return boolean
function M.has_nvim(process_info)
  for _, p in ipairs(process_info and process_info.foreground_processes or {}) do
    if p.name == 'nvim' or p.argv0 == 'nvim' then
      return true
    end
  end
  return false
end

return M
