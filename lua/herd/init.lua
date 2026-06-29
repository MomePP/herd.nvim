--- herd.nvim — drive herdr coding agents from Neovim, with nvim as the host.
---
--- nvim is the top-level UI; herdr runs as a backend daemon that owns each
--- agent's PTY. Agents are shown inside nvim floating terminals attached via
--- `herdr agent attach`, and driven entirely by nvim keybinds — mirroring the
--- sidekick.nvim UX with herdr (not tmux) as the backend.
local Config = require('herd.config')
local Herdr = require('herd.herdr')
local Target = require('herd.target')
local Terminal = require('herd.terminal')
local Picker = require('herd.picker')

local M = {}

--- Name of the agent the next action targets (validated against the live list).
---@type string?
M.target = nil

---@return string
local function cwd()
  return vim.fs.normalize(vim.fn.getcwd())
end

---@return boolean
local function ensure_server()
  if Herdr.installed() and Herdr.server_running() then
    return true
  end
  vim.notify('herd: no herdr server running — launch `herdr` first', vim.log.levels.WARN)
  return false
end

--- Show an agent float and remember it as the target.
---@param a herd.Agent
local function show(a)
  M.target = a.name
  -- Defer the float open: when show() runs inside a vim.ui.select callback (the
  -- picker), opening the float + attach synchronously races the picker teardown
  -- and the attach process gets killed (float blinks shut). A scheduled open runs
  -- after the callback returns and is reliable from every caller.
  vim.schedule(function()
    Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id })
  end)
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
  local ws = Herdr.ensure_workspace(Config.get().workspace)
  -- Tag the agent's tab with the originating project so the herdr sidebar reads
  -- "<herd> · <project>" instead of a bare "herd". Prefer the focused workspace's
  -- label (nvim's project), falling back to the cwd folder name.
  local project = Herdr.focused_workspace_label(Config.get().workspace)
    or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  local agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def, ws, project)
  if not agent then
    return -- error already surfaced by Herdr.run
  end
  if ws then
    Herdr.prune_workspace(ws, agent.tab_id) -- reap tabs left by killed agents
  end
  show(agent)
  vim.notify('herd: spawned ' .. agent.name)
end

--- Toggle this cwd's agent float. With a count, target that slot. If the float
--- is already open for the resolved target, hide it; if no agent runs here,
--- open the picker.
function M.toggle()
  if not ensure_server() then
    return
  end
  local count = vim.v.count
  local agents = Herdr.agents()
  local a
  if count > 0 then
    a = Target.by_slot(agents, cwd(), count)
    if not a then
      -- empty slot: spawn the next clone of the inferred tool, else fall to the picker
      local base = Target.infer_base(agents, cwd(), M.target, Config.get().tools)
      if base then
        return M.spawn(base)
      end
      return M.select()
    end
  else
    a = Target.current(agents, cwd(), M.target)
  end
  if not a then
    return M.select()
  end
  M.target = a.name
  Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
end

--- Grouped picker: switch to a running agent, or spawn a configured tool.
function M.select()
  if not ensure_server() then
    return
  end
  Picker.open(function(item)
    if item.agent then
      show(item.agent)
    else
      M.spawn(item.tool)
    end
  end)
end

--- The current visual selection as one string (getregion, nvim >= 0.10).
---@return string
local function selection()
  local mode = vim.fn.mode()
  if not mode:match('^[vV\22]$') then
    mode = vim.fn.visualmode()
  end
  if mode == '' then
    return ''
  end
  return table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode }), '\n')
end

--- Send the visual selection to the active agent (no Enter — review then submit).
function M.send()
  local text = selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  if text == '' then
    return
  end
  if not ensure_server() then
    return
  end
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  M.target = a.name
  Herdr.agent_send(a.pane_id, text) -- target the unambiguous pane, not the name
  vim.schedule(function()
    Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id }) -- land in the agent to submit
  end)
  vim.notify('herd → ' .. a.name)
end

--- Surface the agent pool: focus the dedicated herd workspace in the herdr client.
function M.dashboard()
  if not ensure_server() then
    return
  end
  local ws = Herdr.ensure_workspace(Config.get().workspace)
  if not ws then
    return vim.notify('herd: could not resolve the herd workspace', vim.log.levels.WARN)
  end
  Herdr.focus_workspace(ws)
end

---@param opts? herd.Config
function M.setup(opts)
  local cfg = Config.setup(opts)
  local map = vim.keymap.set
  if cfg.keys.toggle then
    map('n', cfg.keys.toggle, M.toggle, { desc = 'herd: toggle agent float (count = slot)' })
  end
  if cfg.keys.send then
    map('x', cfg.keys.send, M.send, { desc = 'herd: send selection' })
  end
  if cfg.keys.select then
    map('n', cfg.keys.select, M.select, { desc = 'herd: select / spawn agent' })
  end
  if cfg.keys.dashboard then
    map('n', cfg.keys.dashboard, M.dashboard, { desc = 'herd: herdr dashboard' })
  end
  -- terminal-mode hide/newline are registered per-float by an autocmd so they are buffer-local.
  if cfg.keys.hide or cfg.keys.newline then
    vim.api.nvim_create_autocmd('TermOpen', {
      group = vim.api.nvim_create_augroup('herd_term', { clear = true }),
      callback = function(ev)
        -- only herd floats (terminal buffers we created are 'nofile' scratch + termopen)
        for name, e in pairs(Terminal.reg) do
          if e.buf == ev.buf then
            if cfg.keys.hide then
              vim.keymap.set('t', cfg.keys.hide, function()
                Terminal.hide(name)
              end, { buffer = ev.buf, desc = 'herd: hide float' })
            end
            if cfg.keys.newline then
              vim.keymap.set('t', cfg.keys.newline, function()
                local job = vim.b[ev.buf].terminal_job_id
                if job then
                  vim.fn.chansend(job, '\27[13;2u')
                end
              end, { buffer = ev.buf, desc = 'herd: shift-enter newline to CLI' })
            end
          end
        end
      end,
    })
  end

  vim.api.nvim_create_user_command('Herd', function(a)
    local sub = a.args ~= '' and a.args or 'toggle'
    local fn = ({ toggle = M.toggle, select = M.select, send = M.send, dashboard = M.dashboard })[sub]
    if fn then
      fn()
    elseif sub:match('^spawn%s') then
      M.spawn(sub:gsub('^spawn%s+', ''))
    elseif sub == 'spawn' then
      vim.notify('herd: :Herd spawn <tool> — needs a tool name', vim.log.levels.WARN)
    else
      vim.notify('herd: unknown subcommand ' .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'toggle', 'select', 'send', 'dashboard', 'spawn' }
    end,
    desc = 'herd',
  })
end

return M
