local Herdr = require('herd.herdr')

describe('herd.herdr', function()
  it('attach_argv', function()
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, Herdr.attach_argv('claude'))
  end)

  it('focus_workspace runs the workspace focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.focus_workspace('wH')
    assert.are.same({ 'workspace', 'focus', 'wH' }, got)
    Herdr.run = saved
  end)

  it('slot_name: 1 is the base, n>1 is suffixed', function()
    assert.are.equal('claude', Herdr.slot_name('claude', 1))
    assert.are.equal('claude_2', Herdr.slot_name('claude', 2))
  end)

  it('next_name picks the first free clone slot', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = { { name = 'claude' }, { name = 'claude_2' } } }
    end
    assert.are.equal('opencode', Herdr.next_name('opencode'))
    assert.are.equal('claude_3', Herdr.next_name('claude'))
    Herdr.api = saved
  end)

  it('agents parses, filters by normalized cwd, and drops nameless agents', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = {
        { name = 'a', pane_id = 'p1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', agent_status = 'working', cwd = '/tmp/y' },
        -- detected agent with no assigned name → must be skipped
        { pane_id = 'p3', agent_status = 'working', cwd = '/tmp/x' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    local scoped = Herdr.agents(vim.fs.normalize('/tmp/x'))
    assert.are.equal(1, #scoped) -- only the named 'a', not the nameless p3
    assert.are.equal('a', scoped[1].name)
    Herdr.api = saved
  end)

  it('agent_send shells the literal-text send command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args; return '' end
    Herdr.agent_send('claude', 'hello world')
    assert.are.same({ 'agent', 'send', 'claude', 'hello world' }, got)
    Herdr.run = saved
  end)

  it('ensure_workspace returns an existing workspace by label (no create)', function()
    local created = false
    local saved = Herdr.api
    Herdr.api = function(args)
      if args[1] == 'workspace' and args[2] == 'list' then
        return { workspaces = { { workspace_id = 'wA', label = 'tlic' }, { workspace_id = 'wH', label = 'herd' } } }
      end
      if args[1] == 'workspace' and args[2] == 'create' then
        created = true
        return { workspace = { workspace_id = 'wNEW' } }
      end
      return {}
    end
    assert.are.equal('wH', Herdr.ensure_workspace('herd'))
    assert.is_false(created)
    Herdr.api = saved
  end)

  it('ensure_workspace creates the workspace when absent', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      if args[1] == 'workspace' and args[2] == 'list' then
        return { workspaces = {} }
      end
      if args[1] == 'workspace' and args[2] == 'create' then
        return { workspace = { workspace_id = 'wNEW' } }
      end
      return {}
    end
    assert.are.equal('wNEW', Herdr.ensure_workspace('herd'))
    Herdr.api = saved
  end)

  it('spawn places the agent in the given workspace (no --split)', function()
    local got
    local saved = Herdr.api
    Herdr.api = function(args) got = args; return { agent = { name = 'claude' } } end
    Herdr.spawn('claude', '/tmp/proj', { cmd = { 'claude', '--foo' }, env = { A = '1' } }, 'wH')
    local joined = table.concat(got, ' ')
    assert.is_nil(joined:find('--split'))
    assert.is_truthy(joined:find('agent start claude', 1, true))
    assert.is_truthy(joined:find('--cwd /tmp/proj', 1, true))
    assert.is_truthy(joined:find('--no-focus', 1, true))
    assert.is_truthy(joined:find('--workspace wH', 1, true))
    assert.is_truthy(joined:find('--env A=1', 1, true))
    assert.is_truthy(joined:find('-- claude --foo', 1, true))
    Herdr.api = saved
  end)

  it('spawn omits --workspace and still spawns when no workspace is given', function()
    local got
    local saved = Herdr.api
    Herdr.api = function(args) got = args; return { agent = { name = 'claude' } } end
    local agent = Herdr.spawn('claude', '/tmp/proj', { cmd = { 'claude' } })
    local joined = table.concat(got, ' ')
    assert.is_nil(joined:find('--workspace'))
    assert.is_nil(joined:find('--split'))
    assert.is_truthy(joined:find('agent start claude', 1, true))
    assert.is_truthy(joined:find('-- claude', 1, true))
    assert.are.equal('claude', agent.name)
    Herdr.api = saved
  end)

  it('spawn creates a labelled tab and starts the agent in it (not --workspace)', function()
    local calls = {}
    local saved = Herdr.api
    Herdr.api = function(args)
      calls[#calls + 1] = args
      if args[1] == 'tab' and args[2] == 'create' then
        return { tab = { tab_id = 'wH:t5' } }
      end
      if args[1] == 'agent' and args[2] == 'start' then
        return { agent = { name = 'claude', pane_id = 'wH:p9' } }
      end
      return {}
    end
    Herdr.spawn('claude', '/tmp/proj', { cmd = { 'claude' } }, 'wH', 'dotfiles-config')
    local tabcmd = table.concat(calls[1], ' ')
    assert.are.equal('tab', calls[1][1])
    assert.are.equal('create', calls[1][2])
    assert.is_truthy(tabcmd:find('--workspace wH', 1, true))
    assert.is_truthy(tabcmd:find('--label dotfiles-config', 1, true))
    local startcmd = table.concat(calls[2], ' ')
    assert.is_truthy(startcmd:find('--tab wH:t5', 1, true))
    assert.is_nil(startcmd:find('--workspace')) -- placed via --tab, not --workspace
    assert.is_nil(startcmd:find('--split'))
    -- agent's pane is zoomed so it fills the tab (the tab also holds an empty pane)
    assert.are.same({ 'pane', 'zoom', 'wH:p9', '--on' }, calls[3])
    Herdr.api = saved
  end)

  it('focused_workspace_label returns the focused workspace, excluding the herd label', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      if args[1] == 'workspace' and args[2] == 'list' then
        return { workspaces = {
          { workspace_id = 'w6', label = 'dotfiles-config', focused = true },
          { workspace_id = 'wH', label = 'herd', focused = false },
        } }
      end
      return {}
    end
    assert.are.equal('dotfiles-config', Herdr.focused_workspace_label('herd'))
    Herdr.api = saved
  end)

  it('focused_workspace_label is nil when only the herd workspace is focused', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { workspaces = { { workspace_id = 'wH', label = 'herd', focused = true } } }
    end
    assert.is_nil(Herdr.focused_workspace_label('herd'))
    Herdr.api = saved
  end)

  it('prune_workspace closes agentless tabs, keeping live agents and keep_tab', function()
    local closed = {}
    local saved_api, saved_run = Herdr.api, Herdr.run
    Herdr.api = function(args)
      if args[1] == 'agent' and args[2] == 'list' then
        return { agents = { { name = 'claude', tab_id = 'wH:t1' } } } -- t1 has a live agent
      end
      if args[1] == 'tab' and args[2] == 'list' then
        return { tabs = { { tab_id = 'wH:t1' }, { tab_id = 'wH:t2' }, { tab_id = 'wH:t3' } } }
      end
      return {}
    end
    Herdr.run = function(args)
      if args[1] == 'tab' and args[2] == 'close' then
        closed[#closed + 1] = args[3]
      end
    end
    Herdr.prune_workspace('wH', 'wH:t3') -- keep t3 (just-spawned, maybe not in list yet)
    assert.are.same({ 'wH:t2' }, closed) -- t1 live, t3 kept, only dead t2 closed
    Herdr.api, Herdr.run = saved_api, saved_run
  end)
end)
