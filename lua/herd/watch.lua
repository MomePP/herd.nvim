--- Native-mode exit watcher. While the user is over in an agent's herdr tab,
--- block on `agent wait` and act when the agent process ends. On herdr ≥
--- 0.7.5 the agent runs inside the tab's shell, so its pane OUTLIVES the
--- agent (it drops back to a shell prompt and herdr never reaps the tab):
--- "was the user looking at the agent" is decidable post-exit from the pane's
--- `focused` flag, and this watcher owns both the return trip to the origin
--- tab and reaping the now-idle tab. Only one watcher runs at a time; `agent
--- wait` blocks on the server socket, so watching costs no polling.
local M = {}

local TIMEOUT_MS = 600000

--- gen invalidates in-flight callbacks: stop/start bump it, and a callback
--- from a superseded watcher sees a stale gen and does nothing.
M.state = { gen = 0 }

--- Seam: run `argv` async, calling `on_done(stdout, stderr, code)` on exit.
--- Returns a killable handle. Tests replace this so no real herdr server is
--- needed.
---@param argv string[]
---@param on_done fun(stdout: string, stderr: string, code: integer)
---@return { kill: fun(self, sig: integer) }
function M.spawn(argv, on_done)
  return vim.system(argv, { text = true }, function(res)
    on_done(res.stdout or '', res.stderr or '', res.code)
  end)
end

--- Decoded JSON `result` table from a herdr CLI envelope, or nil.
--- Type-guards each hop: JSON null decodes to vim.NIL (userdata), which
--- would throw on field access (same envelope hazard Herdr.api handles).
---@param stdout string
---@return table?
local function result_of(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  local result = ok and type(decoded) == 'table' and decoded.result
  return type(result) == 'table' and result or nil
end

--- The agent exited; its pane lives on at a shell prompt. Return focus to
--- `origin` iff the agent's pane is still the focused one (the user was
--- looking at it) — focus moves BEFORE the reap, since closing the focused
--- tab would flash a neighbor. Then close the agent's tab unless the user
--- split it (other panes share the tab). Runs through the async spawn seam,
--- not Herdr.api/run — those block on :wait(), and this fires on nvim's main
--- loop right at hand-back time.
---@param a herd.Agent
---@param origin? string editor tab to return to
local function on_agent_gone(a, origin)
  local function reap()
    M.spawn({ 'herdr', 'tab', 'get', a.tab_id }, function(stdout, _, code)
      if code ~= 0 then
        return -- tab already gone (closed by hand) or server unreachable
      end
      local result = result_of(stdout)
      local tab = result and type(result.tab) == 'table' and result.tab
      if tab and (tab.pane_count or 0) <= 1 then
        M.spawn({ 'herdr', 'tab', 'close', a.tab_id }, function() end)
      end
    end)
  end
  if not origin then
    return reap()
  end
  M.spawn({ 'herdr', 'pane', 'get', a.pane_id }, function(stdout, _, code)
    local result = code == 0 and result_of(stdout) or nil
    local pane = result and type(result.pane) == 'table' and result.pane
    if pane and pane.focused == true then
      M.spawn({ 'herdr', 'tab', 'focus', origin }, function()
        reap()
      end)
    else
      reap()
    end
  end)
end

--- Watch `a`'s agent, replacing any previous watcher.
---@param a herd.Agent
---@param origin? string editor tab to return to on agent exit (auto_return)
function M.start(a, origin)
  M.stop()
  local gen = M.state.gen
  local function watch()
    M.state.handle = M.spawn(
      { 'herdr', 'agent', 'wait', a.pane_id, '--until', 'unknown', '--timeout', tostring(TIMEOUT_MS) },
      function(stdout, stderr, code)
        vim.schedule(function()
          if gen ~= M.state.gen then
            return -- superseded or stopped; a newer watcher owns the state
          end
          local out = stdout .. stderr
          if out:find('agent_not_running', 1, true) or out:find('agent_not_found', 1, true) then
            -- agent exited mid-wait, or was already gone when the wait armed
            M.state.handle = nil
            on_agent_gone(a, origin)
          elseif code == 0 or out:find('timeout', 1, true) then
            -- rc 0: the agent transiently reported the `unknown` state but is
            -- alive — keep watching. Timeout: defensive re-arm; the blocking
            -- wait is the cheap steady state.
            watch()
          else
            M.state.handle = nil -- server gone or unknown error: give up quietly
          end
        end)
      end
    )
  end
  watch()
end

--- Cancel the current watcher (user is back in the editor, or hopping again).
function M.stop()
  M.state.gen = M.state.gen + 1
  if M.state.handle then
    pcall(M.state.handle.kill, M.state.handle, 15)
    M.state.handle = nil
  end
end

return M
