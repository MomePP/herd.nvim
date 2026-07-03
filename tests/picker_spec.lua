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

  it('items_global renders "<tab-label>  [status]  · <workspace>" rows sorted by workspace label', function()
    local agents = {
      { name = 'claude', cwd = '/p/a', status = 'idle', pane_id = 'wA:pN', tab_id = 'wA:t8', workspace_id = 'wA' },
      { name = 'claude_2', cwd = '/p/b', status = 'working', pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6' },
    }
    local ws_labels = { w6 = 'dotfiles-config', wA = 'tlic-dev' }
    local tab_labels = { ['w6:tD'] = 'dotfiles:claude_2', ['wA:t8'] = 'ado-badge:claude' }
    local items = Picker.items_global(agents, ws_labels, tab_labels)

    assert.are.equal(2, #items)
    -- sorted by workspace label: dotfiles-config before tlic-dev
    assert.are.equal('claude_2', items[1].agent.name)
    assert.are.equal('dotfiles:claude_2  [working]  · dotfiles-config', items[1].label)
    assert.are.equal('ado-badge:claude  [idle]  · tlic-dev', items[2].label)
  end)

  it('items_global falls back to the agent name and "?" when labels are unknown', function()
    local items = Picker.items_global(
      { { name = 'claude', status = 'idle', pane_id = 'p', tab_id = 'tX', workspace_id = 'wX' } },
      {},
      {}
    )
    assert.are.equal(1, #items)
    assert.are.equal('claude  [idle]  · ?', items[1].label)
  end)

  it('items attaches the tool def to spawn entries', function()
    local items = Picker.items({}, { claude = { cmd = { 'claude', '--x' } } })
    assert.are.same({ 'claude', '--x' }, items[1].def.cmd)
  end)

  it('items_global attaches ws and tab_label for the preview header', function()
    local items = Picker.items_global(
      { { name = 'claude', status = 'idle', pane_id = 'p', tab_id = 'w6:tD', workspace_id = 'w6' } },
      { w6 = 'dotfiles-config' },
      { ['w6:tD'] = 'dotfiles:claude' }
    )
    assert.are.equal('dotfiles-config', items[1].ws)
    assert.are.equal('dotfiles:claude', items[1].tab_label)
  end)

  it('preview_meta renders an agent header and a tool header', function()
    local agent_lines = Picker.preview_meta({
      agent = { name = 'claude_4', status = 'idle', cwd = '/p/x', workspace_id = 'w9' },
      ws = 'gogo-dev',
      tab_label = 'gogo-code:claude_4',
      label = 'x',
    })
    assert.are.same({
      'claude_4  [idle]',
      'cwd: /p/x',
      'workspace: gogo-dev',
      'tab: gogo-code:claude_4',
    }, agent_lines)

    local tool_lines = Picker.preview_meta({
      tool = 'claude',
      def = { cmd = { 'claude', '--x' }, env = { A = '1' } },
      label = '+ claude',
    })
    assert.are.same({ '+ claude', 'cmd: claude --x', 'env: A=1' }, tool_lines)
  end)
end)
