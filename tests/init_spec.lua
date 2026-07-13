local Herd = require('herd')

describe('herd init', function()
  it('setup registers the :Herd command and is idempotent', function()
    Herd.setup({ tools = { claude = { cmd = { 'claude' } } } })
    assert.is_true(vim.fn.exists(':Herd') >= 1)
    Herd.setup({}) -- second call must not error
  end)

  it('send is a no-op (no error) when there is no visual selection', function()
    -- not in visual mode + empty register region → returns without notifying error
    assert.has_no.errors(function()
      Herd.send()
    end)
  end)

  it('format_context wraps a multi-line selection with path:range and a fence', function()
    local out = Herd.format_context({ path = 'src/a.lua', ft = 'lua', sline = 10, eline = 12, text = 'x = 1' })
    assert.are.equal('src/a.lua:10-12:\n```lua\nx = 1\n```', out)
  end)

  it('format_context uses a single line number when the selection is one line', function()
    local out = Herd.format_context({ path = 'src/a.lua', ft = 'lua', sline = 5, eline = 5, text = 'y = 2' })
    assert.are.equal('src/a.lua:5:\n```lua\ny = 2\n```', out)
  end)

  it('format_context omits the fence language when filetype is empty', function()
    local out = Herd.format_context({ path = 'notes', ft = '', sline = 1, eline = 1, text = 'hi' })
    assert.are.equal('notes:1:\n```\nhi\n```', out)
  end)

  it('send wraps the selection through format_context when send.context is on', function()
    Herd.setup({}) -- send.context defaults on
    local Herdr = require('herd.herdr')
    local Target = require('herd.target')
    local Terminal = require('herd.terminal')
    local saved = {
      sel = Herd.selection, fmt = Herd.format_context,
      server = Herdr.server_running, agents = Herdr.agents, send = Herdr.agent_send,
      current = Target.current, open = Terminal.open, notify = vim.notify,
    }
    Herd.selection = function() return { text = 'RAW', sline = 3, eline = 4 } end
    Herd.format_context = function(ctx) return 'WRAPPED(' .. ctx.text .. ')' end
    Herdr.server_running = function() return true end
    Herdr.agents = function() return {} end
    Target.current = function() return { name = 'claude', pane_id = 'p1', cwd = vim.fn.getcwd() } end
    local sent
    Herdr.agent_send = function(pane, text) sent = { pane = pane, text = text } end
    Terminal.open = function() end
    vim.notify = function() end

    Herd.send()

    Herd.selection, Herd.format_context = saved.sel, saved.fmt
    Herdr.server_running, Herdr.agents, Herdr.agent_send = saved.server, saved.agents, saved.send
    Target.current, Terminal.open, vim.notify = saved.current, saved.open, saved.notify

    assert.are.equal('p1', sent.pane)
    assert.are.equal('WRAPPED(RAW)', sent.text)
  end)

  it('send passes the raw selection when send.context is false', function()
    Herd.setup({ send = { context = false } })
    local Herdr = require('herd.herdr')
    local Target = require('herd.target')
    local Terminal = require('herd.terminal')
    local saved = {
      sel = Herd.selection,
      server = Herdr.server_running, agents = Herdr.agents, send = Herdr.agent_send,
      current = Target.current, open = Terminal.open, notify = vim.notify,
    }
    Herd.selection = function() return { text = 'RAW', sline = 3, eline = 4 } end
    Herdr.server_running = function() return true end
    Herdr.agents = function() return {} end
    Target.current = function() return { name = 'claude', pane_id = 'p1', cwd = vim.fn.getcwd() } end
    local sent
    Herdr.agent_send = function(pane, text) sent = { pane = pane, text = text } end
    Terminal.open = function() end
    vim.notify = function() end

    Herd.send()

    Herd.selection = saved.sel
    Herdr.server_running, Herdr.agents, Herdr.agent_send = saved.server, saved.agents, saved.send
    Target.current, Terminal.open, vim.notify = saved.current, saved.open, saved.notify

    assert.are.equal('RAW', sent.text)
  end)

  it('send does not crash and sends raw when disabled with `send = false`', function()
    Herd.setup({ send = false }) -- non-table disable idiom, mirroring keys.x = false
    local Herdr = require('herd.herdr')
    local Target = require('herd.target')
    local Terminal = require('herd.terminal')
    local saved = {
      sel = Herd.selection,
      server = Herdr.server_running, agents = Herdr.agents, send = Herdr.agent_send,
      current = Target.current, open = Terminal.open, notify = vim.notify,
    }
    Herd.selection = function() return { text = 'RAW', sline = 3, eline = 4 } end
    Herdr.server_running = function() return true end
    Herdr.agents = function() return {} end
    Target.current = function() return { name = 'claude', pane_id = 'p1', cwd = vim.fn.getcwd() } end
    local sent
    Herdr.agent_send = function(pane, text) sent = { pane = pane, text = text } end
    Terminal.open = function() end
    vim.notify = function() end

    -- pcall + restore BEFORE asserting so a failure can't leak the stubs into
    -- later tests (a failed assertion aborts the `it` block mid-way).
    local ok, err = pcall(Herd.send)

    Herd.selection = saved.sel
    Herdr.server_running, Herdr.agents, Herdr.agent_send = saved.server, saved.agents, saved.send
    Target.current, Terminal.open, vim.notify = saved.current, saved.open, saved.notify

    assert.is_true(ok, 'send crashed: ' .. tostring(err))
    assert.are.equal('RAW', sent.text)
  end)

  it('spawn errors cleanly on an unknown tool', function()
    Herd.setup({ tools = {} })
    local notified
    local saved = vim.notify
    vim.notify = function(msg, lvl) notified = { msg = msg, lvl = lvl } end
    -- stub server check so we reach the unknown-tool branch
    require('herd.herdr').server_running = function() return true end
    Herd.spawn('nope')
    vim.notify = saved
    assert.is_truthy(notified and notified.msg:find('unknown tool', 1, true))
  end)

  it('setup falls back to float when native mode is requested without HERDR_TAB_ID', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = nil
    local notified
    local saved_notify = vim.notify
    vim.notify = function(msg, lvl) notified = { msg = msg, lvl = lvl } end

    Herd.setup({ mode = 'native' })

    vim.notify = saved_notify
    vim.env.HERDR_TAB_ID = saved_env
    assert.is_truthy(notified)
    assert.is_truthy(notified.msg:find('native mode requires nvim', 1, true))
    assert.are.equal(vim.log.levels.WARN, notified.lvl)
    assert.are.equal('float', require('herd.config').get().mode)
  end)

  it('setup keeps native mode when HERDR_TAB_ID is present', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    local notified = false
    local saved_notify = vim.notify
    vim.notify = function() notified = true end

    Herd.setup({ mode = 'native' })

    vim.notify = saved_notify
    vim.env.HERDR_TAB_ID = saved_env
    assert.is_false(notified)
    assert.are.equal('native', require('herd.config').get().mode)
  end)

  it('spawn uses spawn_native and focuses the tab in native mode', function()
    local saved_tab_env, saved_ws_env = vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID = 'w6:t1', 'w6'
    Herd.setup({ mode = 'native', tools = { claude = { cmd = { 'claude' } } } })

    local Herdr = require('herd.herdr')
    local saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label =
      Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.agent_focus, Herdr.tab_label
    Herdr.server_running = function() return true end
    Herdr.next_name = function(tool) return tool end
    Herdr.tab_label = function(id) return id == 'w6:t1' and 'dotfiles' or nil end
    local spawn_project
    Herdr.spawn_native = function(name, _cwd, _def, project)
      spawn_project = project
      return { name = name, tab_id = 'w6:t9', pane_id = 'w6:pQ' }
    end
    local pruned
    Herdr.prune_workspace = function(ws, keep, prefix) pruned = { ws, keep, prefix } end
    local focused
    Herdr.agent_focus = function(id) focused = id end
    local saved_notify = vim.notify
    vim.notify = function() end

    Herd.spawn('claude')
    vim.wait(200, function() return focused ~= nil end, 5) -- show() defers via vim.schedule

    vim.notify = saved_notify
    Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.agent_focus, Herdr.tab_label =
      saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label
    vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID = saved_tab_env, saved_ws_env

    -- agent tab named after nvim's own tab label; reaper scoped to "<project>:"
    assert.are.equal('dotfiles', spawn_project)
    assert.are.same({ 'w6', 'w6:t9', 'dotfiles:' }, pruned)
    assert.are.equal('w6:pQ', focused)
  end)

  it('toggle focuses the agent tab via herdr in native mode (no float)', function()
    local saved_tab_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    Herd.setup({ mode = 'native' })

    local Herdr = require('herd.herdr')
    local Terminal = require('herd.terminal')
    local saved_server, saved_agents, saved_focus = Herdr.server_running, Herdr.agents, Herdr.agent_focus
    local saved_toggle = Terminal.toggle
    Herdr.server_running = function() return true end
    Herdr.agents = function()
      return { { name = 'claude', pane_id = 'w6:pQ', tab_id = 'w6:t9', status = 'idle', cwd = vim.fn.getcwd() } }
    end
    local focused
    Herdr.agent_focus = function(id) focused = id end
    local toggled = false
    Terminal.toggle = function() toggled = true end

    Herd.toggle()

    Herdr.server_running, Herdr.agents, Herdr.agent_focus = saved_server, saved_agents, saved_focus
    Terminal.toggle = saved_toggle
    vim.env.HERDR_TAB_ID = saved_tab_env

    assert.are.equal('w6:pQ', focused)
    assert.is_false(toggled)
  end)

  it('dashboard opens the global agent picker in native mode', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    Herd.setup({ mode = 'native' })

    local Herdr = require('herd.herdr')
    local Picker = require('herd.picker')
    local saved_server, saved_ensure = Herdr.server_running, Herdr.ensure_workspace
    local saved_global = Picker.open_global
    Herdr.server_running = function() return true end
    local ensured = false
    Herdr.ensure_workspace = function() ensured = true end
    local opened = false
    Picker.open_global = function() opened = true end

    Herd.dashboard()

    Herdr.server_running, Herdr.ensure_workspace = saved_server, saved_ensure
    Picker.open_global = saved_global
    vim.env.HERDR_TAB_ID = saved_env

    assert.is_true(opened)
    assert.is_false(ensured) -- the dedicated-workspace path is float-only
  end)

  it('dashboard still focuses the dedicated workspace in float mode', function()
    Herd.setup({ mode = 'float' })

    local Herdr = require('herd.herdr')
    local Picker = require('herd.picker')
    local saved_server, saved_ensure, saved_focus_ws =
      Herdr.server_running, Herdr.ensure_workspace, Herdr.focus_workspace
    local saved_global = Picker.open_global
    Herdr.server_running = function() return true end
    Herdr.ensure_workspace = function() return 'wH' end
    local focused
    Herdr.focus_workspace = function(id) focused = id end
    local opened = false
    Picker.open_global = function() opened = true end

    Herd.dashboard()

    Herdr.server_running, Herdr.ensure_workspace, Herdr.focus_workspace =
      saved_server, saved_ensure, saved_focus_ws
    Picker.open_global = saved_global

    assert.are.equal('wH', focused)
    assert.is_false(opened)
  end)

  it('native mode skips the float-only TermOpen and mouse-passthrough autocmds', function()
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_term')
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_mouse')
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'

    Herd.setup({ mode = 'native', keys = { hide = '<leader>s', newline = '<S-CR>' }, win = { mouse = false } })

    vim.env.HERDR_TAB_ID = saved_env
    assert.has_error(function()
      vim.api.nvim_get_autocmds({ group = 'herd_term' })
    end)
    assert.has_error(function()
      vim.api.nvim_get_autocmds({ group = 'herd_mouse' })
    end)
  end)

  it('float mode still registers the TermOpen and mouse-passthrough autocmds', function()
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_term')
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_mouse')

    Herd.setup({ mode = 'float', keys = { hide = '<leader>s', newline = '<S-CR>' }, win = { mouse = false } })

    assert.is_true(#vim.api.nvim_get_autocmds({ group = 'herd_term' }) > 0)
    assert.is_true(#vim.api.nvim_get_autocmds({ group = 'herd_mouse' }) > 0)
  end)
end)
