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

describe('herd.target base/infer', function()
  it('base_of strips only a trailing _<digits>', function()
    assert.are.equal('claude', Target.base_of('claude'))
    assert.are.equal('claude', Target.base_of('claude_2'))
    assert.are.equal('claude', Target.base_of('claude_22'))
    assert.are.equal('open_code', Target.base_of('open_code'))   -- no trailing digits
    assert.are.equal('open_code', Target.base_of('open_code_3'))
  end)

  it('infer_base: prefers the current target base when it is a configured tool', function()
    local tools = { claude = {}, opencode = {} }
    local agents = { A('opencode', '/p/a') }
    local cwd = vim.fs.normalize('/p/a')
    assert.are.equal('claude', Target.infer_base(agents, cwd, 'claude_2', tools))
  end)

  it('infer_base: falls back to first scoped agent base', function()
    local tools = { claude = {}, opencode = {} }
    local agents = { A('claude_2', '/p/a') }
    local cwd = vim.fs.normalize('/p/a')
    assert.are.equal('claude', Target.infer_base(agents, cwd, nil, tools))
  end)

  it('infer_base: uses the sole configured tool when nothing else applies', function()
    assert.are.equal('claude', Target.infer_base({}, vim.fs.normalize('/p/a'), nil, { claude = {} }))
  end)

  it('infer_base: nil when ambiguous (no target, no agents, multiple tools)', function()
    local tools = { claude = {}, opencode = {} }
    assert.is_nil(Target.infer_base({}, vim.fs.normalize('/p/a'), nil, tools))
  end)

  it('infer_base: skips a target/agent base that is not a configured tool', function()
    local tools = { claude = {} }
    -- target base 'ghost' not configured, no scoped agents, sole tool 'claude' wins
    assert.are.equal('claude', Target.infer_base({}, vim.fs.normalize('/p/a'), 'ghost_2', tools))
  end)
end)
