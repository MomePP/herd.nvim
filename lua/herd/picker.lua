--- Grouped agent picker built from `herdr agent list`: running agents (grouped
--- by project cwd) plus spawn entries for configured tools. The nvim-side
--- mirror of herdr's agent dashboard.
local Herdr = require('herd.herdr')
local Config = require('herd.config')
local M = {}

---@class herd.PickItem
---@field agent? herd.Agent
---@field tool? string
---@field label string
---@field def? herd.Tool
---@field ws? string
---@field tab_label? string

--- @param agents herd.Agent[]
--- @param tools table<string, herd.Tool>
--- @return herd.PickItem[]
function M.items(agents, tools)
  local running = vim.deepcopy(agents)
  table.sort(running, function(a, b)
    if (a.cwd or '') ~= (b.cwd or '') then
      return (a.cwd or '') < (b.cwd or '')
    end
    return a.name < b.name
  end)

  local items = {}
  for _, a in ipairs(running) do
    items[#items + 1] = {
      agent = a,
      label = ('%s  [%s]'):format(a.name, a.status or '?'),
    }
  end

  local names = vim.tbl_keys(tools)
  table.sort(names)
  for _, n in ipairs(names) do
    items[#items + 1] = { tool = n, def = tools[n], label = '+ ' .. n }
  end
  return items
end

--- Global rows: every running agent across all workspaces, labelled
--- `<tab-label>  [<status>]  · <workspace-label>` (a native agent's tab label
--- is `<project>:<agent>`, so the row already names both). Sorted by
--- workspace label, then agent name. No spawn rows — spawning stays
--- project-scoped in the `M.items` picker.
---@param agents herd.Agent[]
---@param ws_labels table<string, string> workspace_id → label
---@param tab_labels table<string, string> tab_id → label
---@return herd.PickItem[]
function M.items_global(agents, ws_labels, tab_labels)
  local running = vim.deepcopy(agents)
  table.sort(running, function(a, b)
    local wa = ws_labels[a.workspace_id] or ''
    local wb = ws_labels[b.workspace_id] or ''
    if wa ~= wb then
      return wa < wb
    end
    return a.name < b.name
  end)
  local items = {}
  for _, a in ipairs(running) do
    items[#items + 1] = {
      agent = a,
      ws = ws_labels[a.workspace_id],
      tab_label = tab_labels[a.tab_id],
      label = ('%s  [%s]  · %s'):format(
        tab_labels[a.tab_id] or a.name,
        a.status or '?',
        ws_labels[a.workspace_id] or '?'
      ),
    }
  end
  return items
end

--- Metadata header lines for a picker preview pane. Pure — no CLI calls;
--- the live-output tail is appended by the snacks glue, not here.
---@param it herd.PickItem
---@return string[]
function M.preview_meta(it)
  if it.tool then
    local lines = { '+ ' .. it.tool }
    local def = it.def or {}
    if def.cmd then
      lines[#lines + 1] = 'cmd: ' .. table.concat(def.cmd, ' ')
    end
    for k, v in pairs(def.env or {}) do
      lines[#lines + 1] = ('env: %s=%s'):format(k, tostring(v))
    end
    return lines
  end
  local a = it.agent
  local lines = { ('%s  [%s]'):format(a.name, a.status or '?'), 'cwd: ' .. (a.cwd or '?') }
  local ws = it.ws or a.workspace_id
  if ws then
    lines[#lines + 1] = 'workspace: ' .. ws
  end
  if it.tab_label then
    lines[#lines + 1] = 'tab: ' .. it.tab_label
  end
  return lines
end

--- Render a picker: Snacks.picker (full layout + preview pane) when
--- available and not opted out (`picker = 'select'`), else the plain
--- vim.ui.select fallback.
---@param items herd.PickItem[]
---@param title string
---@param on_choice fun(item: herd.PickItem)
local function choose(items, title, on_choice)
  local Spicker = require('herd.snackspicker') -- lazy: avoids a require cycle
  if Config.get().picker ~= 'select' and Spicker.available() then
    return Spicker.open(items, title, on_choice)
  end
  vim.ui.select(items, {
    prompt = title,
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      on_choice(i)
    end
  end)
end

--- Open the global picker over every running agent (cross-project). The
--- nvim-side dashboard for native mode. `on_choice` receives the chosen
--- `herd.PickItem` (not called on cancel).
---@param on_choice fun(item: herd.PickItem)
function M.open_global(on_choice)
  local items = M.items_global(Herdr.agents(), Herdr.workspace_labels(), Herdr.tab_labels())
  if #items == 0 then
    return vim.notify('herd: no agents running', vim.log.levels.WARN)
  end
  choose(items, 'herd (all projects):', on_choice)
end

--- Open the picker. `on_choice` receives the chosen `herd.PickItem` (or is not
--- called on cancel).
---@param on_choice fun(item: herd.PickItem)
function M.open(on_choice)
  -- scope the picker to agents in the current project (sidekick `filter.cwd`)
  local items = M.items(Herdr.agents(vim.fs.normalize(vim.fn.getcwd())), Config.get().tools)
  if #items == 0 then
    return vim.notify('herd: no agents running and no tools configured', vim.log.levels.WARN)
  end
  choose(items, 'herd:', on_choice)
end

return M
