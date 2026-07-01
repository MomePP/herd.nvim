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
    local saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus =
      Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab
    Herdr.server_running = function() return true end
    Herdr.next_name = function(tool) return tool end
    Herdr.spawn_native = function(name) return { name = name, tab_id = 'w6:t9' } end
    local pruned
    Herdr.prune_workspace = function(ws, keep) pruned = { ws, keep } end
    local focused
    Herdr.focus_tab = function(id) focused = id end
    local saved_notify = vim.notify
    vim.notify = function() end

    Herd.spawn('claude')
    vim.wait(200, function() return focused ~= nil end, 5) -- show() defers via vim.schedule

    vim.notify = saved_notify
    Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab =
      saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus
    vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID = saved_tab_env, saved_ws_env

    assert.are.same({ 'w6', 'w6:t9' }, pruned)
    assert.are.equal('w6:t9', focused)
  end)

  it('toggle focuses the agent tab via herdr in native mode (no float)', function()
    local saved_tab_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    Herd.setup({ mode = 'native' })

    local Herdr = require('herd.herdr')
    local Terminal = require('herd.terminal')
    local saved_server, saved_agents, saved_focus = Herdr.server_running, Herdr.agents, Herdr.focus_tab
    local saved_toggle = Terminal.toggle
    Herdr.server_running = function() return true end
    Herdr.agents = function()
      return { { name = 'claude', pane_id = 'w6:pQ', tab_id = 'w6:t9', status = 'idle', cwd = vim.fn.getcwd() } }
    end
    local focused
    Herdr.focus_tab = function(id) focused = id end
    local toggled = false
    Terminal.toggle = function() toggled = true end

    Herd.toggle()

    Herdr.server_running, Herdr.agents, Herdr.focus_tab = saved_server, saved_agents, saved_focus
    Terminal.toggle = saved_toggle
    vim.env.HERDR_TAB_ID = saved_tab_env

    assert.are.equal('w6:t9', focused)
    assert.is_false(toggled)
  end)
end)
