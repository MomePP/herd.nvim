local Spicker = require('herd.snackspicker')

describe('herd.snackspicker', function()
  after_each(function()
    package.loaded['snacks.picker'] = nil
  end)

  it('available is false without snacks and true with it', function()
    assert.is_false(Spicker.available())
    package.loaded['snacks.picker'] = { pick = function() end }
    assert.is_true(Spicker.available())
  end)

  it('open maps herd items to snacks items and confirm schedules on_choice', function()
    local captured
    package.loaded['snacks.picker'] = { pick = function(opts) captured = opts end }
    local herd_item = { agent = { name = 'a', pane_id = 'p' }, label = 'a  [idle]' }
    local chosen
    Spicker.open({ herd_item }, 'herd:', function(it) chosen = it end)

    assert.are.equal('herd:', captured.title)
    assert.are.equal('a  [idle]', captured.items[1].text)

    local closed = false
    captured.confirm({ close = function() closed = true end }, captured.items[1])
    vim.wait(100, function() return chosen ~= nil end, 5)
    assert.is_true(closed)
    assert.are.equal(herd_item, chosen)
  end)

  it('confirm with no item (cancel) closes without calling on_choice', function()
    local captured
    package.loaded['snacks.picker'] = { pick = function(opts) captured = opts end }
    local called = false
    Spicker.open({ { label = 'x', agent = {} } }, 'herd:', function() called = true end)
    captured.confirm({ close = function() end }, nil)
    vim.wait(50)
    assert.is_false(called)
  end)

  it('preview sets metadata header plus live agent output', function()
    local captured
    package.loaded['snacks.picker'] = { pick = function(opts) captured = opts end }
    local Herdr = require('herd.herdr')
    local saved_read = Herdr.agent_read
    Herdr.agent_read = function(pane) return pane == 'w6:pQ' and 'out line 1\nout line 2' or nil end

    Spicker.open({
      { agent = { name = 'claude', status = 'idle', cwd = '/p', pane_id = 'w6:pQ' }, label = 'claude  [idle]' },
    }, 'herd:', function() end)

    local set_lines, set_title
    local ctx = {
      item = captured.items[1],
      preview = {
        reset = function() end,
        set_lines = function(_, lines) set_lines = lines end,
        set_title = function(_, t) set_title = t end,
      },
    }
    captured.preview(ctx)
    Herdr.agent_read = saved_read

    assert.are.equal('claude  [idle]', set_lines[1])
    assert.are.equal('cwd: /p', set_lines[2])
    assert.is_truthy(vim.tbl_contains(set_lines, 'out line 1'))
    assert.is_truthy(vim.tbl_contains(set_lines, 'out line 2'))
    assert.are.equal('claude', set_title)
  end)

  it('picker.open_global routes through snacks when available', function()
    local captured
    package.loaded['snacks.picker'] = { pick = function(opts) captured = opts end }
    local Herdr = require('herd.herdr')
    local saved_agents, saved_ws, saved_tabs = Herdr.agents, Herdr.workspace_labels, Herdr.tab_labels
    Herdr.agents = function()
      return { { name = 'a', pane_id = 'p', tab_id = 't', workspace_id = 'w', status = 'idle', cwd = '/p' } }
    end
    Herdr.workspace_labels = function() return { w = 'ws' } end
    Herdr.tab_labels = function() return { t = 'a-tab' } end
    local selected = false
    local saved_select = vim.ui.select
    vim.ui.select = function() selected = true end

    require('herd.picker').open_global(function() end)

    vim.ui.select = saved_select
    Herdr.agents, Herdr.workspace_labels, Herdr.tab_labels = saved_agents, saved_ws, saved_tabs

    assert.is_truthy(captured)
    assert.is_false(selected)
  end)

  it('picker = "select" forces the vim.ui.select fallback even with snacks present', function()
    package.loaded['snacks.picker'] = { pick = function() error('snacks must not be used') end }
    local Config = require('herd.config')
    Config.options = nil
    Config.setup({ picker = 'select' })
    local Herdr = require('herd.herdr')
    local saved_agents, saved_ws, saved_tabs = Herdr.agents, Herdr.workspace_labels, Herdr.tab_labels
    Herdr.agents = function()
      return { { name = 'a', pane_id = 'p', tab_id = 't', workspace_id = 'w', status = 'idle', cwd = '/p' } }
    end
    Herdr.workspace_labels = function() return { w = 'ws' } end
    Herdr.tab_labels = function() return { t = 'a-tab' } end
    local selected = false
    local saved_select = vim.ui.select
    vim.ui.select = function() selected = true end

    require('herd.picker').open_global(function() end)

    vim.ui.select = saved_select
    Herdr.agents, Herdr.workspace_labels, Herdr.tab_labels = saved_agents, saved_ws, saved_tabs
    Config.options = nil

    assert.is_true(selected)
  end)
end)
