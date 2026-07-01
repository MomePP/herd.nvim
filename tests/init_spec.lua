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
end)
