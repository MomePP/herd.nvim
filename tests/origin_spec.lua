local Origin = require('herd.origin')

--- Live-shaped fixtures (herdr 0.7.1 `tab list`/`pane list`/`agent list`).
--- Workspace w6 holds two projects sharing it — "dotfiles" (~/.config) and
--- "local" (~/.local) — each with an editor tab and a native agent tab.
--- w9 has an identically-labelled "dotfiles" tab to prove workspace scoping.
local function fixtures()
  local tabs = {
    { tab_id = 'w6:t1', label = 'dotfiles', workspace_id = 'w6' },
    { tab_id = 'w6:t2', label = 'local', workspace_id = 'w6' },
    { tab_id = 'w6:tD', label = 'dotfiles:claude_2', workspace_id = 'w6' },
    { tab_id = 'w6:tE', label = 'local:claude', workspace_id = 'w6' },
    { tab_id = 'w9:t1', label = 'dotfiles', workspace_id = 'w9' },
  }
  local panes = {
    { pane_id = 'w6:p1', tab_id = 'w6:t1', workspace_id = 'w6', cwd = '/Users/u/.config', focused = false },
    { pane_id = 'w6:p2', tab_id = 'w6:t2', workspace_id = 'w6', cwd = '/Users/u/.local', focused = false },
    { pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6', cwd = '/Users/u/.config', focused = true },
    { pane_id = 'w6:pB', tab_id = 'w6:tE', workspace_id = 'w6', cwd = '/Users/u/.local', focused = false },
    { pane_id = 'w9:p1', tab_id = 'w9:t1', workspace_id = 'w9', cwd = '/Users/u/proj', focused = false },
  }
  local agents = {
    { name = 'claude_2', pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6', cwd = '/Users/u/.config' },
    { name = 'claude', pane_id = 'w6:pB', tab_id = 'w6:tE', workspace_id = 'w6', cwd = '/Users/u/.local' },
  }
  return tabs, panes, agents
end

describe('herd.origin', function()
  describe('label_prefix', function()
    it('splits at the last colon', function()
      assert.are.equal('dotfiles', Origin.label_prefix('dotfiles:claude_2'))
      assert.are.equal('a:b', Origin.label_prefix('a:b:claude'))
    end)

    it('is nil without a colon, with an empty prefix, or for a nil label', function()
      assert.is_nil(Origin.label_prefix('dotfiles'))
      assert.is_nil(Origin.label_prefix(':claude'))
      assert.is_nil(Origin.label_prefix(nil))
    end)
  end)

  describe('resolve', function()
    it('follows the label link to the origin editor tab in the same workspace', function()
      local tabs, panes, agents = fixtures()
      -- focused pane w6:pA sits in "dotfiles:claude_2" → tab labelled
      -- "dotfiles" in w6 (w9's identically-labelled tab is out of scope)
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)

    it('splits editor labels containing colons at the last colon', function()
      local tabs = {
        { tab_id = 'w1:t1', label = 'a:b', workspace_id = 'w1' },
        { tab_id = 'w1:t2', label = 'a:b:claude', workspace_id = 'w1' },
      }
      local panes = {
        { pane_id = 'w1:p1', tab_id = 'w1:t1', workspace_id = 'w1', cwd = '/x', focused = false },
        { pane_id = 'w1:p2', tab_id = 'w1:t2', workspace_id = 'w1', cwd = '/x', focused = true },
      }
      assert.are.equal('w1:t1', (Origin.resolve(tabs, panes, {})))
    end)

    it('falls back to the agent spawn cwd when the label link is broken', function()
      local tabs, panes, agents = fixtures()
      tabs[3].label = 'renamed' -- user renamed the agent tab: no colon, no link
      -- focused agent w6:pA spawn cwd /Users/u/.config → editor pane w6:p1 → tab w6:t1
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)

    it('cwd fallback never lands on another agent pane', function()
      local tabs, panes, agents = fixtures()
      tabs[3].label = 'renamed'
      panes[1].cwd = '/elsewhere' -- the real editor no longer matches...
      agents[2].cwd = '/Users/u/.config' -- ...and the OTHER agent shares the cwd
      panes[4].cwd = '/Users/u/.config'
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('no origin editor here', reason)
    end)

    it('is nil with a reason when the focused pane is not an agent', function()
      local tabs, panes, agents = fixtures()
      panes[3].focused = false
      panes[1].focused = true -- nvim's own editor pane focused
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('not an agent pane', reason)
    end)

    it('is nil with a reason when nothing is focused', function()
      local tabs, panes, agents = fixtures()
      panes[3].focused = false
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('no focused pane', reason)
    end)

    it('first match wins on duplicate editor labels in one workspace', function()
      local tabs, panes, agents = fixtures()
      tabs[#tabs + 1] = { tab_id = 'w6:t7', label = 'dotfiles', workspace_id = 'w6' }
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)
  end)

  describe('editor_pane', function()
    it('returns a pane in the resolved origin tab', function()
      local _, panes = fixtures()
      assert.are.equal('w6:p1', Origin.editor_pane(panes, 'w6:t1'))
    end)

    it('is nil when the tab has no pane', function()
      local _, panes = fixtures()
      assert.is_nil(Origin.editor_pane(panes, 'w6:tX'))
    end)
  end)

  describe('has_nvim', function()
    it('is true when nvim is a foreground process (by name or argv0)', function()
      assert.is_true(Origin.has_nvim({ foreground_processes = { { name = 'zsh' }, { name = 'nvim' } } }))
      assert.is_true(Origin.has_nvim({ foreground_processes = { { name = 'nvim', argv0 = 'nvim' } } }))
    end)

    it('is false for a plain shell or missing info', function()
      assert.is_false(Origin.has_nvim({ foreground_processes = { { name = 'zsh' } } }))
      assert.is_false(Origin.has_nvim(nil))
    end)
  end)
end)
