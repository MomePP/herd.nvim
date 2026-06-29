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
end)
