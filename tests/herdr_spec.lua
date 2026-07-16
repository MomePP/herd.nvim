local Herdr = require('herd.herdr')

describe('herd.herdr', function()
  it('attach_argv', function()
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, Herdr.attach_argv('claude'))
  end)

  it('api returns nil for JSON-null stdout (bare null and {"result": null})', function()
    local saved = Herdr.run
    -- bare `null` decodes to vim.NIL (userdata) — indexing `.result` must not throw
    Herdr.run = function() return 'null' end
    assert.is_nil(Herdr.api({ 'tab', 'get', 'stale' }))
    -- `{"result": null}` decodes to a table whose `.result` is vim.NIL (truthy);
    -- callers that do `res and res.foo` would index a userdata and throw
    Herdr.run = function() return '{"result": null}' end
    assert.is_nil(Herdr.api({ 'tab', 'get', 'stale' }))
    -- and a normal envelope still returns its result
    Herdr.run = function() return '{"result": {"tab": {"label": "x"}}}' end
    assert.are.same({ tab = { label = 'x' } }, Herdr.api({ 'tab', 'get', 'ok' }))
    Herdr.run = saved
  end)

  it('focus_workspace runs the workspace focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.focus_workspace('wH')
    assert.are.same({ 'workspace', 'focus', 'wH' }, got)
    Herdr.run = saved
  end)

  it('agent_focus runs the agent focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.agent_focus('w6:pQ')
    assert.are.same({ 'agent', 'focus', 'w6:pQ' }, got)
    Herdr.run = saved
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
        { name = 'a', pane_id = 'p1', tab_id = 't1', workspace_id = 'w1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', tab_id = 't2', workspace_id = 'w2', agent_status = 'working', cwd = '/tmp/y' },
        -- detected agent with no assigned name → must be skipped
        { pane_id = 'p3', tab_id = 't3', workspace_id = 'w1', agent_status = 'working', cwd = '/tmp/x' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    assert.are.equal('t1', all[1].tab_id)
    assert.are.equal('w1', all[1].workspace_id)
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
      if args[1] == 'pane' and args[2] == 'list' then
        return { panes = {
          { pane_id = 'wH:p9', tab_id = 'wH:t5' }, -- the agent
          { pane_id = 'wH:p8', tab_id = 'wH:t5' }, -- the spare initial pane
        } }
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
    -- the spare pane in the tab (≠ the agent's) is closed; the agent's is kept
    assert.are.same({ 'pane', 'list', '--workspace', 'wH' }, calls[3])
    assert.are.same({ 'pane', 'close', 'wH:p8' }, calls[4])
    Herdr.api = saved
  end)

  it('spawn_native creates a tab in the env workspace, starts the agent, and closes the spare pane via the tab-create response (no pane list)', function()
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = 'w6'
    local calls = {}
    local saved_api = Herdr.api
    Herdr.api = function(args)
      calls[#calls + 1] = args
      if args[1] == 'tab' and args[2] == 'create' then
        return { tab = { tab_id = 'w6:t9' }, root_pane = { pane_id = 'w6:pS' } }
      end
      if args[1] == 'agent' and args[2] == 'start' then
        return { agent = { name = 'claude', pane_id = 'w6:pQ' } }
      end
      return {}
    end

    local agent = Herdr.spawn_native('claude', '/tmp/proj', { cmd = { 'claude' } }, 'dotfiles')

    local tabcmd = table.concat(calls[1], ' ')
    assert.are.equal('tab', calls[1][1])
    assert.are.equal('create', calls[1][2])
    assert.is_truthy(tabcmd:find('--workspace w6', 1, true))
    assert.is_truthy(tabcmd:find('--label dotfiles:claude', 1, true))
    assert.is_truthy(tabcmd:find('--cwd /tmp/proj', 1, true))
    assert.is_truthy(tabcmd:find('--no-focus', 1, true))

    local startcmd = table.concat(calls[2], ' ')
    assert.is_truthy(startcmd:find('agent start claude', 1, true))
    assert.is_truthy(startcmd:find('--tab w6:t9', 1, true))
    assert.is_nil(startcmd:find('--workspace'))
    assert.is_nil(startcmd:find('--split'))

    -- the spare pane id came straight from the tab-create response — no
    -- follow-up `pane list` round trip, unlike float mode's M.spawn.
    assert.are.same({ 'pane', 'close', 'w6:pS' }, calls[3])
    assert.are.equal(3, #calls)

    assert.are.equal('claude', agent.name)
    assert.are.equal('w6:t9', agent.tab_id)

    Herdr.api = saved_api
    vim.env.HERDR_WORKSPACE_ID = saved_ws
  end)

  it('spawn_native returns nil and never starts the agent when tab creation fails', function()
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = 'w6'
    local calls = {}
    local saved_api = Herdr.api
    Herdr.api = function(args)
      calls[#calls + 1] = args
      return {} -- 'tab create' fails: no `.tab` in the response
    end

    local agent = Herdr.spawn_native('claude', '/tmp/proj', { cmd = { 'claude' } }, 'dotfiles')

    assert.is_nil(agent)
    assert.are.equal(1, #calls) -- only the failed tab-create call, no agent start

    Herdr.api = saved_api
    vim.env.HERDR_WORKSPACE_ID = saved_ws
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

  it('prune_workspace with a "<project>:" label_prefix reaps only this project\'s dead agent tabs', function()
    local closed = {}
    local saved_api, saved_run = Herdr.api, Herdr.run
    Herdr.api = function(args)
      if args[1] == 'agent' and args[2] == 'list' then
        -- t9 hosts a live dotfiles agent; nothing else does
        return { agents = { { name = 'claude', tab_id = 'w6:t9' } } }
      end
      if args[1] == 'tab' and args[2] == 'list' then
        return { tabs = {
          { tab_id = 'w6:t1', label = 'dotfiles' },          -- nvim's own tab: no colon, agentless
          { tab_id = 'w6:t2', label = 'server' },            -- user's shell tab: agentless
          { tab_id = 'w6:t5', label = 'herd.nvim:claude' },  -- a SIBLING project's dead agent: agentless
          { tab_id = 'w6:t8', label = 'dotfiles:claude_2' }, -- this project's dead agent: agentless
          { tab_id = 'w6:t9', label = 'dotfiles:claude' },   -- this project's live agent: has agent
        } }
      end
      return {}
    end
    Herdr.run = function(args)
      if args[1] == 'tab' and args[2] == 'close' then
        closed[#closed + 1] = args[3]
      end
    end
    Herdr.prune_workspace('w6', nil, 'dotfiles:')
    -- ONLY this project's dead agent tab is closed; nvim's own tab, the user's
    -- shell tab, the sibling project's dead agent, and the live agent all survive.
    assert.are.same({ 'w6:t8' }, closed)
    Herdr.api, Herdr.run = saved_api, saved_run
  end)

  it('tab_label returns a tab\'s label, or nil when absent', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      if args[1] == 'tab' and args[2] == 'get' and args[3] == 'w6:t1' then
        return { tab = { tab_id = 'w6:t1', label = 'dotfiles' } }
      end
      return {} -- unknown tab: no `.tab`
    end
    assert.are.equal('dotfiles', Herdr.tab_label('w6:t1'))
    assert.is_nil(Herdr.tab_label('w6:tX'))
    Herdr.api = saved
  end)

  it('workspace_labels maps workspace ids to labels in one call', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same({ 'workspace', 'list' }, args)
      return { workspaces = {
        { workspace_id = 'w6', label = 'dotfiles-config' },
        { workspace_id = 'wA', label = 'tlic-dev' },
      } }
    end
    assert.are.same({ w6 = 'dotfiles-config', wA = 'tlic-dev' }, Herdr.workspace_labels())
    Herdr.api = saved
  end)

  it('tab_labels maps tab ids to labels across all workspaces in one call', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same({ 'tab', 'list' }, args)
      return { tabs = {
        { tab_id = 'w6:tD', label = 'dotfiles:claude_2' },
        { tab_id = 'wA:t8', label = 'ado-badge:claude' },
      } }
    end
    assert.are.same(
      { ['w6:tD'] = 'dotfiles:claude_2', ['wA:t8'] = 'ado-badge:claude' },
      Herdr.tab_labels()
    )
    Herdr.api = saved
  end)

  it('agent_read returns the visible pane text', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same({ 'agent', 'read', 'w6:pQ', '--source', 'visible', '--format', 'text' }, args)
      return { read = { text = 'hello\nworld' } }
    end
    assert.are.equal('hello\nworld', Herdr.agent_read('w6:pQ'))
    Herdr.api = saved
  end)

  it('agent_read is nil when the read fails', function()
    local saved = Herdr.api
    Herdr.api = function() return nil end
    assert.is_nil(Herdr.agent_read('w6:pQ'))
    Herdr.api = saved
  end)

  it('agent_read passes source and lines when given opts', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same(
        { 'agent', 'read', 'w6:pQ', '--source', 'recent', '--format', 'text', '--lines', '200' },
        args
      )
      return { read = { text = 'x' } }
    end
    assert.are.equal('x', Herdr.agent_read('w6:pQ', { source = 'recent', lines = 200 }))
    Herdr.api = saved
  end)
end)
