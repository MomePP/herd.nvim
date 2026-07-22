local Target = require('herd.target')

local function A(name, cwd, status)
  return { name = name, cwd = cwd, status = status or 'idle', pane_id = name }
end

describe('herd.target', function()
  local agents = {
    A('claude_2', '/p/a'),
    A('claude', '/p/a'),
    A('opencode', '/p/b'),
  }
  local cwd = vim.fs.normalize('/p/a')

  it('scoped filters by cwd and sorts by name', function()
    local s = Target.scoped(agents, cwd)
    assert.are.equal(2, #s)
    assert.are.equal('claude', s[1].name)
    assert.are.equal('claude_2', s[2].name)
  end)

  it('current prefers the cached target when still scoped', function()
    assert.are.equal('claude_2', Target.current(agents, cwd, 'claude_2').name)
  end)

  it('current falls back to first scoped when cache is gone/foreign', function()
    assert.are.equal('claude', Target.current(agents, cwd, 'opencode').name)
    assert.are.equal('claude', Target.current(agents, cwd, nil).name)
  end)

  it('current is nil when nothing runs in this cwd', function()
    assert.is_nil(Target.current(agents, vim.fs.normalize('/p/zzz'), nil))
  end)

  it('by_slot indexes the scoped, sorted list', function()
    assert.are.equal('claude', Target.by_slot(agents, cwd, 1).name)
    assert.are.equal('claude_2', Target.by_slot(agents, cwd, 2).name)
    assert.is_nil(Target.by_slot(agents, cwd, 3))
  end)
end)

