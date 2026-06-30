local Config = require('herd.config')

describe('herd.config', function()
  before_each(function()
    Config.options = nil
  end)

  it('defaults: empty tools, sidekick-style keys, fullscreen win, no zoom', function()
    local c = Config.setup({})
    assert.are.same({}, c.tools)
    assert.are.equal('<leader>s', c.keys.toggle)
    assert.are.equal('<leader>s', c.keys.send)
    assert.are.equal('<leader>s', c.keys.hide)
    assert.are.equal('<leader>S', c.keys.select)
    assert.is_false(c.keys.dashboard)
    assert.are.equal('<S-CR>', c.keys.newline)
    assert.are.equal(1, c.win.width)
    assert.are.equal(1, c.win.height)
    assert.is_true(c.win.footer)
    assert.are.equal('', c.win.winhighlight)
    assert.is_true(c.win.mouse)
    assert.are.same({ '', '', '', '', ' ', ' ', ' ', '' }, c.win.border)
    assert.is_nil(c.zoom)
    assert.are.equal('herd.nvim', c.workspace)
  end)

  it('merges user tools and overrides keys', function()
    local c = Config.setup({
      tools = { claude = { cmd = { 'claude' } } },
      keys = { select = false },
    })
    assert.are.same({ 'claude' }, c.tools.claude.cmd)
    assert.is_false(c.keys.select)
    assert.are.equal('<leader>s', c.keys.toggle) -- untouched default
  end)
end)
