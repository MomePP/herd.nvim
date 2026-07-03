--- Snacks.picker rendering for herd's pickers: full default layout with a
--- preview pane (agent metadata header + live pane output). Loaded lazily
--- from picker.lua's chooser; falls back to vim.ui.select when snacks.nvim
--- is not installed (see Picker.choose).
local M = {}

---@return boolean
function M.available()
  return (pcall(require, 'snacks.picker'))
end

--- Preview pane content: metadata header, then live output for agent rows.
---@param it herd.PickItem
---@return string[] lines, string title
local function preview_content(it)
  local lines = require('herd.picker').preview_meta(it)
  if it.agent and it.agent.pane_id then
    lines[#lines + 1] = string.rep('─', 40)
    local out = require('herd.herdr').agent_read(it.agent.pane_id)
    vim.list_extend(lines, vim.split(out or '(no output)', '\n'))
  end
  return lines, it.agent and it.agent.name or it.tool or ''
end

--- Open a Snacks picker over herd PickItems.
---@param items herd.PickItem[]
---@param title string
---@param on_choice fun(item: herd.PickItem)
function M.open(items, title, on_choice)
  local sitems = {}
  for idx, it in ipairs(items) do
    sitems[#sitems + 1] = { text = it.label, herd = it, idx = idx }
  end
  require('snacks.picker').pick({
    source = 'herd',
    title = title,
    items = sitems,
    format = function(item)
      return { { item.text } }
    end,
    preview = function(ctx)
      ctx.preview:reset()
      local lines, ptitle = preview_content(ctx.item.herd)
      ctx.preview:set_lines(lines)
      ctx.preview:set_title(ptitle)
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        -- mirror snacks' own ui_select provider: schedule past picker teardown
        vim.schedule(function()
          on_choice(item.herd)
        end)
      end
    end,
  })
end

return M
