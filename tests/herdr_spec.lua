local Herdr = require('herd.herdr')

describe('herd.herdr', function()
  it('attach_argv / dashboard_argv', function()
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, Herdr.attach_argv('claude'))
    assert.are.same({ 'herdr' }, Herdr.dashboard_argv())
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

  it('agents parses + filters by normalized cwd', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = {
        { name = 'a', pane_id = 'p1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', agent_status = 'working', cwd = '/tmp/y' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    local scoped = Herdr.agents(vim.fs.normalize('/tmp/x'))
    assert.are.equal(1, #scoped)
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
end)
