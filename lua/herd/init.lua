--- herd.nvim — drive herdr coding agents from Neovim, when herdr is the host.
---
--- nvim runs in one herdr pane; CLI agents (claude/opencode/...) run in sibling
--- panes. Spawn a tool and zoom it fullscreen, toggle to a live agent, and send the
--- visual selection — mirroring the sidekick.nvim UX without nvim hosting the agents.
local Config = require('herd.config')
local Herdr = require('herd.herdr')

local M = {}

--- The agent the next action targets. Validated against the live list on every use.
---@type herd.Agent?
M.target = nil

--- Resolve which live agent the next action should hit, scoped to the current cwd:
---   1. the cached target, if still running AND in this cwd;
---   2. else any running agent in this cwd;
---   3. else nil → caller spawns a fresh agent for this project.
--- Never returns an agent from another cwd, so opening nvim in a new project
--- spawns its own agent instead of toggling into another project's pane.
---@return herd.Agent?
local function live_target()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local scoped = Herdr.agents(cwd)
  if #scoped == 0 then
    return nil
  end
  if M.target then
    for _, a in ipairs(scoped) do
      if a.pane_id == M.target.pane_id then
        return a
      end
    end
  end
  return scoped[1]
end

--- Bring an agent pane to the foreground, fullscreen (per config.zoom).
---@param t herd.Agent
local function show(t)
  Herdr.focus(t.name)
  if Config.get().zoom then
    Herdr.zoom(t.pane_id)
  end
end

---@return boolean
local function ensure_server()
  if Herdr.server_running() then
    return true
  end
  vim.notify('herd: no herdr server running — launch `herdr` first', vim.log.levels.WARN)
  return false
end

--- Spawn a configured tool as a new agent and show it.
---@param tool string
function M.spawn(tool)
  if not ensure_server() then
    return
  end
  local def = Config.get().tools[tool]
  if not def then
    return vim.notify('herd: unknown tool ' .. tostring(tool), vim.log.levels.ERROR)
  end
  local agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def)
  if not agent then
    return -- error already surfaced
  end
  M.target = { name = agent.name, pane_id = agent.pane_id, cwd = agent.cwd }
  show(M.target)
  vim.notify('herd: spawned ' .. agent.name)
end

--- Go to a running agent fullscreen. If the one you last used stopped, this lands on
--- another running agent; if nothing is running, open the picker to spawn one.
function M.toggle()
  if not ensure_server() then
    return
  end
  local t = live_target()
  if t then
    M.target = t
    show(t)
  else
    M.select()
  end
end

--- Picker over running agents (switch + fullscreen) and configured tools (spawn).
function M.select()
  if not ensure_server() then
    return
  end
  local items = {}
  for _, a in ipairs(Herdr.agents()) do
    items[#items + 1] = { agent = a, label = ('%s  [%s]'):format(a.name, a.status or '?') }
  end
  local names = vim.tbl_keys(Config.get().tools)
  table.sort(names)
  for _, n in ipairs(names) do
    items[#items + 1] = { tool = n, label = '+ ' .. n }
  end
  if #items == 0 then
    return vim.notify('herd: no tools configured', vim.log.levels.WARN)
  end
  vim.ui.select(items, {
    prompt = 'herd:',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if not i then
      return
    end
    if i.agent then
      M.target = i.agent
      show(i.agent)
    else
      M.spawn(i.tool)
    end
  end)
end

--- The current visual selection as one string (modern getregion API, nvim ≥ 0.10).
---@return string
local function selection()
  local mode = vim.fn.mode()
  if not mode:match('^[vV\22]$') then
    mode = vim.fn.visualmode()
  end
  return table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode }), '\n')
end

--- Send the visual selection to the active agent (no Enter — review then submit).
function M.send()
  local text = selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  if text == '' then
    return
  end
  if not ensure_server() then
    return
  end
  local t = live_target()
  if not t then
    return vim.notify('herd: no agents running', vim.log.levels.WARN)
  end
  M.target = t
  Herdr.send_text(t.pane_id, text) -- multi-line passed as one argv
  show(t) -- focus (and zoom) the agent so you land in the CLI to review/submit
  vim.notify('herd → ' .. t.name)
end

---@param opts? herd.Config
function M.setup(opts)
  local cfg = Config.setup(opts)
  local map = vim.keymap.set
  -- Any key can be set to false (or nil) to skip its mapping.
  if cfg.keys.toggle then
    map('n', cfg.keys.toggle, M.toggle, { desc = 'herd: toggle agent (fullscreen)' })
  end
  if cfg.keys.send then
    map('x', cfg.keys.send, M.send, { desc = 'herd: send selection' })
  end
  if cfg.keys.select then
    map('n', cfg.keys.select, M.select, { desc = 'herd: select / spawn agent' })
  end

  vim.api.nvim_create_user_command('Herd', function(a)
    local sub = a.args ~= '' and a.args or 'toggle'
    local fn = ({ toggle = M.toggle, select = M.select, send = M.send })[sub]
    if fn then
      fn()
    else
      vim.notify('herd: unknown subcommand ' .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'toggle', 'select', 'send' }
    end,
    desc = 'herd',
  })
end

return M
