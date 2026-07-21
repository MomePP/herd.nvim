local Watch = require('herd.watch')

describe('herd.watch', function()
  local spawned, killed
  local agent = { name = 'claude', pane_id = 'w1:p2', tab_id = 'w1:t2', workspace_id = 'w1', cwd = '/p' }

  before_each(function()
    spawned, killed = {}, {}
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
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '', 1)
    vim.wait(10, function() return false end) -- drain scheduled callbacks
    assert.are.equal(1, #spawned) -- no janitor chain started
  end)

  -- Post-death, "was the user looking at the agent" is unknowable (herdr has
  -- already reaped the tab and moved focus), so the watcher never moves focus
  -- — the return trip belongs to bin/herd-run.sh, which checks pre-death.
  -- The janitor chain runs through the same async spawn seam (never a
  -- blocking :wait() on nvim's main loop): wait → tab get → maybe tab close.
  it('pane death reaps a lingering empty tab asynchronously, no focus moves', function()
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    assert.are.same({ 'herdr', 'tab', 'get', 'w1:t2' }, spawned[2].argv)
    spawned[2].on_done('{"result":{"tab":{"focused":true,"pane_count":0}}}', '', 0)
    vim.wait(100, function() return #spawned >= 3 end)
    assert.are.same({ 'herdr', 'tab', 'close', 'w1:t2' }, spawned[3].argv)
  end)

  it('pane death leaves a tab with surviving panes alone (splits survive)', function()
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    spawned[2].on_done('{"result":{"tab":{"focused":true,"pane_count":1}}}', '', 0)
    vim.wait(20, function() return #spawned >= 3 end)
    assert.are.equal(2, #spawned) -- no tab close
  end)

  it('pane death with the tab already gone does nothing further', function()
    Watch.start(agent)
    spawned[1].on_done('{"error":{"code":"pane_not_found"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    spawned[2].on_done('{"error":{"code":"tab_not_found"}}', '', 1) -- herdr reaped it
    vim.wait(20, function() return #spawned >= 3 end)
    assert.are.equal(2, #spawned)
  end)

  it('a spurious sentinel match (rc 0) re-arms — the pane is alive', function()
    Watch.start(agent)
    spawned[1].on_done('{"result":{"matched":true}}', '', 0)
    vim.wait(100, function() return #spawned == 2 end)
    assert.are.equal(2, #spawned) -- re-armed on the same pane, no janitor chain
    assert.are.equal('w1:p2', spawned[2].argv[4])
    assert.are.equal('wait', spawned[2].argv[2])
  end)

  it('re-arms the wait on timeout, stops on any other outcome', function()
    Watch.start(agent)
    spawned[1].on_done('', 'timed out waiting for output', 1)
    vim.wait(100, function() return #spawned == 2 end)
    assert.are.equal(2, #spawned) -- re-armed on the same pane
    assert.are.equal('w1:p2', spawned[2].argv[4])
    spawned[2].on_done('', 'connect: no such file or directory', 1) -- server gone
    vim.wait(10, function() return false end)
    assert.are.equal(2, #spawned) -- no re-arm, no crash
  end)
end)
