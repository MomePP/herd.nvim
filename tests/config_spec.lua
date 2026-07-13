local Config = require('herd.config')

describe('herd.config', function()
  before_each(function()
    Config.options = nil
  end)

  it('defaults: empty tools, leader-doubled agent key + s/S pickers, fullscreen win, no zoom', function()
    local c = Config.setup({})
    assert.are.same({}, c.tools)
    assert.are.equal('float', c.mode)
    assert.are.equal('<leader>\\', c.keys.toggle)
    assert.are.equal('<leader>\\', c.keys.send)
    assert.are.equal('<leader>\\', c.keys.hide)
    assert.are.equal('<leader>s', c.keys.select)
    assert.are.equal('<leader>S', c.keys.dashboard)
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
    assert.are.equal('<leader>\\', c.keys.toggle) -- untouched default
  end)

  it('a partial win.border override replaces the default list (no index-merge)', function()
    local c = Config.setup({ win = { border = { '│' } } })
    assert.are.same({ '│' }, c.win.border) -- not spliced into the 8-element default
    assert.are.equal(1, c.win.width) -- sibling win defaults still apply
  end)

  it('mode can be overridden to native', function()
    local c = Config.setup({ mode = 'native' })
    assert.are.equal('native', c.mode)
  end)

  it('picker defaults to auto and can be forced to select', function()
    assert.are.equal('auto', Config.setup({}).picker)
    Config.options = nil
    assert.are.equal('select', Config.setup({ picker = 'select' }).picker)
    Config.options = nil -- don't leak the forced picker into other spec files
  end)

  it('send.context defaults to true and can be disabled', function()
    assert.is_true(Config.setup({}).send.context)
    Config.options = nil
    assert.is_false(Config.setup({ send = { context = false } }).send.context)
    Config.options = nil
  end)

  it('reload defaults to true and can be disabled', function()
    assert.is_true(Config.setup({}).reload)
    Config.options = nil
    assert.is_false(Config.setup({ reload = false }).reload)
    Config.options = nil
  end)

end)
