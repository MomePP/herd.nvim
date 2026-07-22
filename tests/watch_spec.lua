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

  it('start arms a blocking agent wait on the agent pane', function()
    Watch.start(agent, 'w1:t1')
    assert.are.equal(1, #spawned)
    assert.are.same(
      { 'herdr', 'agent', 'wait', 'w1:p2', '--until', 'unknown', '--timeout', '600000' },
      spawned[1].argv
    )
  end)

  it('start for another agent kills the previous watcher', function()
    Watch.start(agent, 'w1:t1')
    Watch.start({ name = 'codex', pane_id = 'w1:p9', tab_id = 'w1:t9' }, 'w1:t1')
    assert.are.equal(1, #killed)
    assert.are.equal(spawned[1], killed[1])
    assert.are.equal('w1:p9', spawned[2].argv[4])
  end)

  it('stop kills the watcher and a late callback does nothing', function()
    Watch.start(agent, 'w1:t1')
    Watch.stop()
    assert.are.equal(1, #killed)
    spawned[1].on_done('{"error":{"code":"agent_not_running"}}', '', 1)
    vim.wait(10, function() return false end) -- drain scheduled callbacks
    assert.are.equal(1, #spawned) -- no return/reap chain started
  end)

  -- The agent exited but its pane lives on at a shell prompt (herdr ≥ 0.7.5
  -- never reaps it), so the return trip is decidable post-exit: the pane's
  -- `focused` still answers "was the user looking at the agent". Focus moves
  -- BEFORE the reap — closing the focused tab would flash a neighbor.
  it('agent exit with the pane still focused returns to the origin tab, then reaps', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"error":{"code":"agent_not_running"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    assert.are.same({ 'herdr', 'pane', 'get', 'w1:p2' }, spawned[2].argv)
    spawned[2].on_done('{"result":{"pane":{"pane_id":"w1:p2","focused":true}}}', '', 0)
    vim.wait(100, function() return #spawned >= 3 end)
    assert.are.same({ 'herdr', 'tab', 'focus', 'w1:t1' }, spawned[3].argv)
    spawned[3].on_done('{"result":{"type":"ok"}}', '', 0)
    vim.wait(100, function() return #spawned >= 4 end)
    assert.are.same({ 'herdr', 'tab', 'get', 'w1:t2' }, spawned[4].argv)
    spawned[4].on_done('{"result":{"tab":{"tab_id":"w1:t2","pane_count":1}}}', '', 0)
    vim.wait(100, function() return #spawned >= 5 end)
    assert.are.same({ 'herdr', 'tab', 'close', 'w1:t2' }, spawned[5].argv)
  end)

  it('agent exit with focus elsewhere reaps without moving focus', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"error":{"code":"agent_not_running"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    spawned[2].on_done('{"result":{"pane":{"pane_id":"w1:p2","focused":false}}}', '', 0)
    vim.wait(100, function() return #spawned >= 3 end)
    assert.are.same({ 'herdr', 'tab', 'get', 'w1:t2' }, spawned[3].argv)
    spawned[3].on_done('{"result":{"tab":{"tab_id":"w1:t2","pane_count":1}}}', '', 0)
    vim.wait(100, function() return #spawned >= 4 end)
    assert.are.same({ 'herdr', 'tab', 'close', 'w1:t2' }, spawned[4].argv)
  end)

  it('agent exit without an origin skips the focus check entirely', function()
    Watch.start(agent) -- auto_return effectively off: reap-only watcher
    spawned[1].on_done('{"error":{"code":"agent_not_running"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    assert.are.same({ 'herdr', 'tab', 'get', 'w1:t2' }, spawned[2].argv)
  end)

  it('agent exit with the pane already gone still reaps a lingering tab', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"error":{"code":"agent_not_found"}}', '', 1) -- pane/tab closed by hand
    vim.wait(100, function() return #spawned >= 2 end)
    spawned[2].on_done('{"error":{"code":"pane_not_found"}}', '', 1)
    vim.wait(100, function() return #spawned >= 3 end)
    assert.are.same({ 'herdr', 'tab', 'get', 'w1:t2' }, spawned[3].argv)
    spawned[3].on_done('{"error":{"code":"tab_not_found"}}', '', 1) -- already gone
    vim.wait(20, function() return #spawned >= 4 end)
    assert.are.equal(3, #spawned) -- nothing to close
  end)

  it('leaves a tab with user splits alone (pane_count > 1)', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"error":{"code":"agent_not_running"}}', '', 1)
    vim.wait(100, function() return #spawned >= 2 end)
    spawned[2].on_done('{"result":{"pane":{"focused":false}}}', '', 0)
    vim.wait(100, function() return #spawned >= 3 end)
    spawned[3].on_done('{"result":{"tab":{"tab_id":"w1:t2","pane_count":2}}}', '', 0)
    vim.wait(20, function() return #spawned >= 4 end)
    assert.are.equal(3, #spawned) -- no tab close
  end)

  it('a transient unknown-state match (rc 0) re-arms — the agent is alive', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"result":{"status":"unknown"}}', '', 0)
    vim.wait(100, function() return #spawned == 2 end)
    assert.are.equal(2, #spawned) -- re-armed on the same pane, no return/reap chain
    assert.are.equal('w1:p2', spawned[2].argv[4])
    assert.are.equal('wait', spawned[2].argv[3])
  end)

  it('re-arms the wait on timeout, stops on any other outcome', function()
    Watch.start(agent, 'w1:t1')
    spawned[1].on_done('{"error":{"code":"timeout"}}', '', 1)
    vim.wait(100, function() return #spawned == 2 end)
    assert.are.equal(2, #spawned) -- re-armed on the same pane
    assert.are.equal('w1:p2', spawned[2].argv[4])
    spawned[2].on_done('', 'connect: no such file or directory', 1) -- server gone
    vim.wait(10, function() return false end)
    assert.are.equal(2, #spawned) -- no re-arm, no crash
  end)
end)
