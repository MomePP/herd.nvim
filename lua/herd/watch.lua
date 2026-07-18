--- Native-mode exit janitor. While the user is over in an agent's herdr tab,
--- watch that pane and reap the agent's tab if it lingers agentless after the
--- process exits. The return trip is NOT decided here: only bin/herd-run.sh
--- can check focus before the pane dies — post-death, "was the user looking
--- at the agent" is unknowable (herdr has already reaped the tab and moved
--- focus), and guessing steals focus from sibling tabs. Only one watcher runs
--- at a time; `herdr wait output` blocks on the server socket, so watching
--- costs no polling.
local Herdr = require('herd.herdr')

local M = {}

-- Text that should not appear in a pane: the wait ends by pane death
-- (pane_not_found), timeout (re-armed), a spurious match (re-armed — the
-- pane is alive, e.g. an agent printed this file), or being killed.
local SENTINEL = 'herd.nvim::never::0x7f2c'
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

--- The agent's pane died: reap its tab when the agent was its only pane and
--- herdr left the tab behind (0.7.4 usually removes it first; older versions
--- and race windows do not). Never moves focus — see the module comment.
---@param a herd.Agent
local function on_pane_dead(a)
  local res = Herdr.api({ 'tab', 'get', a.tab_id }, { quiet = true })
  local tab = res and res.tab
  if tab and tab.pane_count == 0 then
    Herdr.run({ 'tab', 'close', a.tab_id }, { quiet = true })
  end
end

--- Watch `a`'s pane, replacing any previous watcher.
---@param a herd.Agent
function M.start(a)
  M.stop()
  local gen = M.state.gen
  local function watch()
    M.state.handle = M.spawn(
      { 'herdr', 'wait', 'output', a.pane_id, '--match', SENTINEL, '--timeout', tostring(TIMEOUT_MS) },
      function(stdout, stderr, code)
        vim.schedule(function()
          if gen ~= M.state.gen then
            return -- superseded or stopped; a newer watcher owns the state
          end
          local out = stdout .. stderr
          if out:find('pane_not_found', 1, true) then
            M.state.handle = nil
            on_pane_dead(a)
          elseif code == 0 or out:find('timed out', 1, true) then
            -- rc 0: the sentinel appeared in the pane (an agent printed this
            -- file) — the pane is alive, keep watching. Timeout: defensive
            -- re-arm; the blocking wait is the cheap steady state.
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
