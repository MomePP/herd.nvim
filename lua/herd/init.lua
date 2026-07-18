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
local Watch = require('herd.watch')

local M = {}

--- Native mode hands focus to the agent's herdr tab; arm the exit watcher so
--- the client jumps back to nvim's tab if the agent process ends over there.
---@param a herd.Agent
local function focus_native(a)
  Herdr.agent_focus(a.pane_id)
  if Config.get().auto_return ~= false then
    Watch.start(a)
  end
end

--- Name of the agent the next action targets (validated against the live list).
---@type string?
M.target = nil

---@return string
local function cwd()
  return vim.fs.normalize(vim.fn.getcwd())
end

---@return boolean
local function ensure_server()
  if not Herdr.installed() then
    vim.notify('herd: `herdr` not found on $PATH — install it first', vim.log.levels.ERROR)
    return false
  end
  if not Herdr.server_running() then
    vim.notify('herd: no herdr server running — launch `herdr` first', vim.log.levels.WARN)
    return false
  end
  return true
end

--- Show an agent (float in 'float' mode, herdr agent focus in 'native' mode)
--- and remember it as the target.
---@param a herd.Agent
local function show(a)
  M.target = a.name
  -- Defer: when show() runs inside a vim.ui.select callback (the picker),
  -- acting synchronously races the picker teardown (float mode: the attach
  -- process gets killed, float blinks shut). A scheduled action runs after
  -- the callback returns and is reliable from every caller, in both modes.
  vim.schedule(function()
    if Config.get().mode == 'native' then
      focus_native(a)
    else
      Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id })
    end
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
  local agent, prune_ws, prune_prefix
  if Config.get().mode == 'native' then
    -- name the agent tab after the project nvim sits in (nvim's own tab label,
    -- e.g. "dotfiles"; falling back to the cwd folder) → "dotfiles:claude_2".
    local project = Herdr.tab_label(vim.env.HERDR_TAB_ID)
      or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
    agent = Herdr.spawn_native(Herdr.next_name(tool), vim.fn.getcwd(), def, project)
    prune_ws = vim.env.HERDR_WORKSPACE_ID
    -- reap only *this* project's dead agent tabs (the shared workspace also
    -- holds nvim's own tab and sibling projects' tabs); float's dedicated
    -- workspace reaps all agentless. nvim's own tab is "<project>" (no colon),
    -- so the "<project>:" prefix never matches it.
    prune_prefix = project .. ':'
  else
    local ws = Herdr.ensure_workspace(Config.get().workspace)
    -- Tag the agent's tab with the originating project so the herdr sidebar reads
    -- "<herd> · <project>" instead of a bare "herd". Prefer the focused workspace's
    -- label (nvim's project), falling back to the cwd folder name.
    local project = Herdr.focused_workspace_label(Config.get().workspace)
      or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
    agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def, ws, project)
    prune_ws = ws
  end
  if not agent then
    return -- error already surfaced by Herdr.run
  end
  if prune_ws then
    Herdr.prune_workspace(prune_ws, agent.tab_id, prune_prefix) -- reap tabs left by killed agents
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
  if Config.get().mode == 'native' then
    focus_native(a)
  else
    Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
  end
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

--- The current visual selection: its text plus 1-based line range (getregion,
--- nvim >= 0.10). Seam: tests replace this to drive M.send without a live
--- selection.
---@return { text: string, sline: integer, eline: integer }
function M.selection()
  local mode = vim.fn.mode()
  if not mode:match('^[vV\22]$') then
    mode = vim.fn.visualmode()
  end
  if mode == '' then
    return { text = '', sline = 0, eline = 0 }
  end
  local vpos, cpos = vim.fn.getpos('v'), vim.fn.getpos('.')
  local text = table.concat(vim.fn.getregion(vpos, cpos, { type = mode }), '\n')
  local sline, eline = vpos[2], cpos[2]
  if sline > eline then
    sline, eline = eline, sline
  end
  return { text = text, sline = sline, eline = eline }
end

--- Wrap a selection as a location-prefixed, filetype-fenced block —
--- `path:sline-eline:` then a ``` fence — so the agent knows where the code
--- lives. Public so a user `send.context` function can reuse it.
---@param ctx { path: string, ft: string, sline: integer, eline: integer, text: string }
---@return string
function M.format_context(ctx)
  local lines = ctx.sline == ctx.eline and tostring(ctx.sline) or ('%d-%d'):format(ctx.sline, ctx.eline)
  return ('%s:%s:\n```%s\n%s\n```'):format(ctx.path, lines, ctx.ft, ctx.text)
end

--- Deliver `text` to this project's active agent (no Enter) and land in it to
--- review/submit. Shared by send and diagnostics.
---@param text string
local function deliver(text)
  if not ensure_server() then
    return
  end
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  Herdr.agent_send(a.pane_id, text) -- target the unambiguous pane, not the name
  show(a) -- land in the agent to submit
  vim.notify('herd → ' .. a.name)
end

--- Send the visual selection to the active agent (no Enter — review then
--- submit). With `send.context` (default on) the selection is wrapped with its
--- file path and line range so the agent knows where the code lives.
function M.send()
  local sel = M.selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  if sel.text == '' then
    return
  end
  local payload = sel.text
  local sendcfg = Config.get().send
  -- `send` may be set to a non-table (e.g. `send = false`) to disable wrapping,
  -- mirroring the `keys.x = false` idiom — guard before indexing `.context`.
  local ctxopt = type(sendcfg) == 'table' and sendcfg.context
  if ctxopt then
    local ctx = {
      path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':.'),
      ft = vim.bo.filetype,
      sline = sel.sline,
      eline = sel.eline,
      text = sel.text,
    }
    payload = type(ctxopt) == 'function' and ctxopt(ctx) or M.format_context(ctx)
  end
  deliver(payload)
end

--- vim.diagnostic.severity is 1..4 (ERROR, WARN, INFO, HINT).
local DIAG_SEVERITY = { 'ERROR', 'WARN', 'INFO', 'HINT' }

--- Format a buffer's diagnostics as a text block for the agent: a file header
--- then `line:col [SEVERITY] message (source)` per entry. Public so a caller can
--- reuse the formatting.
---@param path string
---@param diags vim.Diagnostic[]
---@return string
function M.format_diagnostics(path, diags)
  local lines = { 'Diagnostics for ' .. path .. ':' }
  for _, d in ipairs(diags) do
    local sev = DIAG_SEVERITY[d.severity] or '?'
    local src = d.source and (' (' .. d.source .. ')') or ''
    -- collapse multi-line messages so each diagnostic stays on one line
    local msg = d.message:gsub('%s*\n%s*', ' ')
    lines[#lines + 1] = ('%d:%d [%s] %s%s'):format(d.lnum + 1, d.col + 1, sev, msg, src)
  end
  return table.concat(lines, '\n')
end

--- Send the current buffer's LSP diagnostics to the active agent (no Enter —
--- review then submit). No-op with a notice when the buffer is clean.
function M.diagnostics()
  local diags = vim.diagnostic.get(0)
  if #diags == 0 then
    return vim.notify('herd: no diagnostics in this buffer', vim.log.levels.INFO)
  end
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':.')
  deliver(M.format_diagnostics(path, diags))
end

local uv = vim.uv or vim.loop

--- Extract `path:line(:col)?` references from agent output, resolving each
--- relative to `base` and keeping only those that point at a real file (drops
--- prose like `10:30`, directories, and dead paths). Deduped. Public for reuse.
---@param text string
---@param base string directory to resolve relative paths against
---@return { filename: string, lnum: integer, col: integer }[]
function M.parse_refs(text, base)
  local seen, out = {}, {}
  for path, lnum, col in text:gmatch('([%w%._/%-]+):(%d+):?(%d*)') do
    local abs = vim.fs.normalize(path:match('^/') and path or (base .. '/' .. path))
    local key = abs .. ':' .. lnum .. ':' .. col
    local st = uv.fs_stat(abs)
    if not seen[key] and st and st.type == 'file' then
      seen[key] = true
      out[#out + 1] = { filename = abs, lnum = tonumber(lnum), col = col ~= '' and tonumber(col) or 1 }
    end
  end
  return out
end

--- Jump to files the active agent referenced: read its recent output, collect
--- the `path:line` references into the quickfix list, and jump to the first.
function M.jump()
  if not ensure_server() then
    return
  end
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  local text = Herdr.agent_read(a.pane_id, { source = 'recent', lines = 200 })
  local refs = text and M.parse_refs(text, a.cwd) or {}
  if #refs == 0 then
    return vim.notify('herd: no file references in the agent output', vim.log.levels.INFO)
  end
  vim.fn.setqflist({}, ' ', { title = 'herd: ' .. a.name, items = refs })
  vim.cmd('cfirst')
end

--- Surface the agent pool. Float mode: focus the dedicated herd workspace in
--- the herdr client. Native mode: agents live in real project workspaces (the
--- dedicated workspace is unused), so open a global picker over every running
--- agent instead — selecting one focuses it, flipping workspace when needed.
function M.dashboard()
  if not ensure_server() then
    return
  end
  if Config.get().mode == 'native' then
    return Picker.open_global(function(item)
      show(item.agent)
    end)
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
  if cfg.mode == 'native' and not vim.env.HERDR_TAB_ID then
    vim.notify(
      'herd: native mode requires nvim to run inside a herdr pane — falling back to float',
      vim.log.levels.WARN
    )
    cfg.mode = 'float'
  end
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
  -- terminal-mode hide/newline are registered per-float by an autocmd so they are
  -- buffer-local. Float-only: native mode has no herd-owned nvim terminal buffer.
  if cfg.mode == 'float' and (cfg.keys.hide or cfg.keys.newline) then
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

  -- win.mouse = false: hand the mouse to the terminal (Ghostty) while an agent
  -- float is focused, so a plain click-drag does native terminal selection instead
  -- of being forwarded to the agent. Restored on leaving the float. Float-only:
  -- native mode has no herd-owned nvim terminal buffer to hand the mouse away from.
  if cfg.mode == 'float' and cfg.win.mouse == false then
    local grp = vim.api.nvim_create_augroup('herd_mouse', { clear = true })
    local saved
    vim.api.nvim_create_autocmd('BufEnter', {
      group = grp,
      callback = function(ev)
        if Terminal.is_float_buf(ev.buf) then
          if saved == nil then
            saved = vim.o.mouse
          end
          vim.o.mouse = ''
        end
      end,
    })
    vim.api.nvim_create_autocmd('BufLeave', {
      group = grp,
      callback = function(ev)
        if Terminal.is_float_buf(ev.buf) and saved ~= nil then
          vim.o.mouse = saved
          saved = nil
        end
      end,
    })
  end

  -- Auto-reload: the agent (herdr owns its PTY) edits files outside nvim. Run
  -- `checktime` when nvim regains focus — and, in float mode, when leaving an
  -- agent float back to a normal buffer — so those buffers refresh instead of
  -- going stale (or prompting mid-edit). Respects 'autoread' like any checktime.
  if cfg.reload ~= false then
    local grp = vim.api.nvim_create_augroup('herd_reload', { clear = true })
    local function refresh()
      vim.cmd('checktime')
    end
    vim.api.nvim_create_autocmd('FocusGained', { group = grp, callback = refresh })
    if cfg.mode == 'float' then
      vim.api.nvim_create_autocmd('BufLeave', {
        group = grp,
        callback = function(ev)
          if Terminal.is_float_buf(ev.buf) then
            vim.schedule(refresh) -- after the buffer switch settles
          end
        end,
      })
    end
  end

  -- Auto-return watcher lifecycle: regaining focus means the user is back in
  -- the editor, so the armed exit watcher (if any) is no longer wanted.
  if cfg.mode == 'native' and cfg.auto_return ~= false then
    vim.api.nvim_create_autocmd('FocusGained', {
      group = vim.api.nvim_create_augroup('herd_watch', { clear = true }),
      callback = function()
        Watch.stop()
      end,
    })
  end

  vim.api.nvim_create_user_command('Herd', function(a)
    local sub = a.args ~= '' and a.args or 'toggle'
    local fn = ({ toggle = M.toggle, select = M.select, send = M.send, dashboard = M.dashboard, diagnostics = M.diagnostics, jump = M.jump })[sub]
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
    complete = function(arg_lead, cmd_line)
      -- after `spawn `, complete configured tool names; otherwise subcommands
      local cands = cmd_line:match('^%S+%s+spawn%s') and vim.tbl_keys(Config.get().tools)
        or { 'toggle', 'select', 'send', 'dashboard', 'diagnostics', 'jump', 'spawn' }
      return vim.tbl_filter(function(c)
        return vim.startswith(c, arg_lead)
      end, cands)
    end,
    desc = 'herd',
  })
end

return M
