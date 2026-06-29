local Picker = require('herd.picker')

describe('herd.picker', function()
  it('groups agents by cwd then name, then lists spawn entries', function()
    local agents = {
      { name = 'claude_2', cwd = '/p/b', status = 'working', pane_id = 'x' },
      { name = 'claude', cwd = '/p/a', status = 'idle', pane_id = 'y' },
    }
    local tools = { opencode = {}, claude = {} }
    local items = Picker.items(agents, tools)

    -- agents first, sorted by cwd ('/p/a' < '/p/b')
    assert.are.equal('claude', items[1].agent.name)
    assert.are.equal('claude_2', items[2].agent.name)
    -- labels carry name + status
    assert.is_truthy(items[1].label:find('claude', 1, true))
    assert.is_truthy(items[1].label:find('idle', 1, true))
    -- spawn entries come after, sorted, marked '+'
    assert.are.equal('claude', items[3].tool)
    assert.is_truthy(items[3].label:find('+ claude', 1, true))
    assert.are.equal('opencode', items[4].tool)
  end)

  it('empty agents → only spawn entries', function()
    local items = Picker.items({}, { claude = {} })
    assert.are.equal(1, #items)
    assert.are.equal('claude', items[1].tool)
  end)
end)
