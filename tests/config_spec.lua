local Config = require('herd.config')

describe('herd.config', function()
  before_each(function()
    Config.options = nil
  end)

  it('defaults: empty tools, the five keys, a win table, no zoom', function()
    local c = Config.setup({})
    assert.are.same({}, c.tools)
    assert.are.equal('<leader><Tab>', c.keys.toggle)
    assert.are.equal('<leader><Tab>', c.keys.send)
    assert.are.equal('<leader><Tab>', c.keys.hide)
    assert.is_truthy(c.keys.select)
    assert.is_truthy(c.keys.dashboard)
    assert.are.equal(0.9, c.win.width)
    assert.are.equal(0.9, c.win.height)
    assert.is_true(c.win.footer)
    assert.are.equal('', c.win.winhighlight)
    assert.are.equal('<S-CR>', c.keys.newline)
    assert.is_nil(c.zoom)
    assert.are.equal('herd', c.workspace)
  end)

  it('merges user tools and overrides keys', function()
    local c = Config.setup({
      tools = { claude = { cmd = { 'claude' } } },
      keys = { select = false },
    })
    assert.are.same({ 'claude' }, c.tools.claude.cmd)
    assert.is_false(c.keys.select)
    assert.are.equal('<leader><Tab>', c.keys.toggle) -- untouched default
  end)
end)
