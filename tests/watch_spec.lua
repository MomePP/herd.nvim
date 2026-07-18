local Watch = require('herd.watch')
local Herdr = require('herd.herdr')

describe('herd.watch', function()
  local spawned, killed, api_results, run_calls
  local agent = { name = 'claude', pane_id = 'w1:p2', tab_id = 'w1:t2', workspace_id = 'w1', cwd = '/p' }

  before_each(function()
    spawned, killed, run_calls = {}, {}, {}
    api_results = {}
    Watch.state = { gen = 0 }
    -- fake the async process spawn: record argv, hand back a killable handle,
    -- and expose the completion callback so tests can fire it
    Watch.spawn = function(argv, on_done)
      local entry = { argv = argv, on_done = on_done }
      spawned[#spawned + 1] = entry
      return {
        kill = function()
          killed[#killed + 1] = entry
        end,
      }
    end
    Herdr.api = function(args)
      return api_results[table.concat(args, ' ')]
    end
    Herdr.run = function(args)
      run_calls[#run_calls + 1] = table.concat(args, ' ')
      return ''
    end
    vim.env.HERDR_TAB_ID = 'w1:t1'
  end)

  it('start spawns a blocking herdr wait on the agent pane', function()
    Watch.start(agent)
    assert.are.equal(1, #spawned)
    local argv = spawned[1].argv
    assert.are.equal('herdr', argv[1])
    assert.are.equal('wait', argv[2])
    assert.are.equal('output', argv[3])
    assert.are.equal('w1:p2', argv[4])
  end)

  it('start for another agent kills the previous watcher', function()
    Watch.start(agent)
    Watch.start({ name = 'codex', pane_id = 'w1:p9', tab_id = 'w1:t9' })
    assert.are.equal(1, #killed)
    assert.are.equal(spawned[1], killed[1])
    assert.are.equal('w1:p9', spawned[2].argv[4])
  end)

  it('stop kills the watcher and a late callback does nothing', function()
    Watch.start(agent)
    Watch.stop()
    assert.are.equal(1, #killed)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(10, function() return false end) -- drain scheduled callbacks
    assert.are.same({}, run_calls)
  end)

  it('pane death while the agent tab is focused returns to the editor tab and reaps it', function()
    api_results['tab get w1:t2'] = { tab = { focused = true, pane_count = 0 } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(100, function() return #run_calls >= 2 end)
    assert.are.same({ 'tab focus w1:t1', 'tab close w1:t2' }, run_calls)
  end)

  it('pane death while elsewhere reaps the empty tab but does not steal focus', function()
    api_results['tab get w1:t2'] = { tab = { focused = false, pane_count = 0 } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(100, function() return #run_calls >= 1 end)
    assert.are.same({ 'tab close w1:t2' }, run_calls)
  end)

  it('does not reap a tab that still has panes (splits survive)', function()
    api_results['tab get w1:t2'] = { tab = { focused = true, pane_count = 1 } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(100, function() return #run_calls >= 1 end)
    assert.are.same({ 'tab focus w1:t1' }, run_calls)
  end)

  -- herdr 0.7.4 removes a tab whose only pane died before we can query it:
  -- `tab get` fails, so "was the user looking at the agent" is inferred from
  -- the focused workspace + the editor tab not being focused.
  it('tab already gone: jumps back when still in the agent workspace and not in the editor', function()
    api_results['tab get w1:t2'] = nil -- herdr auto-closed the empty tab
    api_results['workspace list'] = { workspaces = { { workspace_id = 'w1', focused = true } } }
    api_results['tab get w1:t1'] = { tab = { focused = false } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(100, function() return #run_calls >= 1 end)
    assert.are.same({ 'tab focus w1:t1' }, run_calls)
  end)

  it('tab already gone: stays put when the user moved to another workspace', function()
    api_results['tab get w1:t2'] = nil
    api_results['workspace list'] = { workspaces = { { workspace_id = 'w9', focused = true } } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(50, function() return #run_calls >= 1 end)
    assert.are.same({}, run_calls)
  end)

  it('tab already gone: stays put when the editor tab is already focused', function()
    api_results['tab get w1:t2'] = nil
    api_results['workspace list'] = { workspaces = { { workspace_id = 'w1', focused = true } } }
    api_results['tab get w1:t1'] = { tab = { focused = true } }
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '')
    vim.wait(50, function() return #run_calls >= 1 end)
    assert.are.same({}, run_calls)
  end)

  it('re-arms the wait on timeout, stops on any other outcome', function()
    Watch.start(agent)
    spawned[1].on_done('', 'timed out waiting for output')
    vim.wait(100, function() return #spawned == 2 end)
    assert.are.equal(2, #spawned) -- re-armed on the same pane
    assert.are.equal('w1:p2', spawned[2].argv[4])
    spawned[2].on_done('', 'connect: no such file or directory') -- server gone
    vim.wait(10, function() return false end)
    assert.are.equal(2, #spawned) -- no re-arm, no crash
    assert.are.same({}, run_calls)
  end)
end)
