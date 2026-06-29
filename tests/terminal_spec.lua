local Terminal = require('herd.terminal')

describe('herd.terminal', function()
  local spawned
  before_each(function()
    Terminal.reg = {}
    spawned = {}
    -- fake the PTY spawn so headless tests don't need a real herdr server
    Terminal.spawn_term = function(cmd, _on_exit)
      spawned[#spawned + 1] = cmd
      return 4242 -- fake job id
    end
  end)

  it('open creates one buffer + visible float and runs attach for the name', function()
    Terminal.open('claude')
    local e = Terminal.reg['claude']
    assert.is_truthy(e)
    assert.is_true(vim.api.nvim_buf_is_valid(e.buf))
    assert.is_true(vim.api.nvim_win_is_valid(e.win))
    assert.is_true(Terminal.is_open('claude'))
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, spawned[1])
  end)

  it('open attaches by opts.pane (unambiguous) when given, not the name', function()
    Terminal.open('claude', { pane = 'wC:pD' })
    assert.is_truthy(Terminal.reg['claude']) -- still keyed by name
    assert.are.same({ 'herdr', 'agent', 'attach', 'wC:pD' }, spawned[1])
  end)

  it('hide closes the window but keeps the buffer (agent survives)', function()
    Terminal.open('claude')
    local buf = Terminal.reg['claude'].buf
    Terminal.hide('claude')
    assert.is_false(Terminal.is_open('claude'))
    assert.is_true(vim.api.nvim_buf_is_valid(buf)) -- buffer (job) retained
  end)

  it('re-open after hide reuses the buffer and does NOT re-attach', function()
    Terminal.open('claude')
    local buf = Terminal.reg['claude'].buf
    Terminal.hide('claude')
    Terminal.open('claude')
    assert.are.equal(buf, Terminal.reg['claude'].buf)
    assert.are.equal(1, #spawned) -- still only the first attach
  end)

  it('toggle flips visibility', function()
    Terminal.toggle('claude') -- opens
    assert.is_true(Terminal.is_open('claude'))
    Terminal.toggle('claude') -- hides
    assert.is_false(Terminal.is_open('claude'))
  end)

  it('open applies configured winhighlight to the float', function()
    require('herd.config').setup({ win = { winhighlight = 'Normal:Foo' } })
    Terminal.open('claude')
    assert.are.equal('Normal:Foo', vim.wo[Terminal.reg['claude'].win].winhighlight)
    require('herd.config').options = nil
  end)
end)
