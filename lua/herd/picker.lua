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
      label = ('%s  %s  [%s]'):format(a.name, vim.fn.fnamemodify(a.cwd or '', ':~'), a.status or '?'),
    }
  end

  local names = vim.tbl_keys(tools)
  table.sort(names)
  for _, n in ipairs(names) do
    items[#items + 1] = { tool = n, label = '+ ' .. n }
  end
  return items
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
  vim.ui.select(items, {
    prompt = 'herd:',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      on_choice(i)
    end
  end)
end

return M
