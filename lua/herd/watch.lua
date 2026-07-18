--- Native-mode auto-return. While the user is over in an agent's herdr tab,
--- watch that pane and jump the herdr client back to nvim's own tab the moment
--- the agent process exits. Only one watcher runs at a time (the agent last
--- focused through herd) — `herdr wait output` blocks on the server socket, so
--- watching costs no polling. Float mode needs none of this: the attach job's
--- on_exit already closes the float.
local Herdr = require('herd.herdr')

local M = {}

-- Text that never appears in a pane: the wait only ever ends by pane death
-- (pane_not_found), its timeout (re-armed below), or being killed.
local SENTINEL = 'herd.nvim::never::0x7f2c'
local TIMEOUT_MS = 600000

--- gen invalidates in-flight callbacks: stop/start bump it, and a callback
--- from a superseded watcher sees a stale gen and does nothing.
M.state = { gen = 0 }

--- Seam: run `argv` async, calling `on_done(stdout, stderr)` on exit. Returns
--- a killable handle. Tests replace this so no real herdr server is needed.
---@param argv string[]
---@param on_done fun(stdout: string, stderr: string)
---@return { kill: fun(self, sig: integer) }
function M.spawn(argv, on_done)
  return vim.system(argv, { text = true }, function(res)
    on_done(res.stdout or '', res.stderr or '')
  end)
end

--- The agent's pane died: return the herdr client to nvim's tab if the user
--- was looking at the agent, and reap the tab when the agent was its only
--- pane (splits survive).
---@param a herd.Agent
local function on_pane_dead(a)
  if not vim.env.HERDR_TAB_ID then
    return
  end
  local res = Herdr.api({ 'tab', 'get', a.tab_id }, { quiet = true })
  local tab = res and res.tab
  if tab then
    if tab.focused then
      Herdr.run({ 'tab', 'focus', vim.env.HERDR_TAB_ID }, { quiet = true })
    end
    if tab.pane_count == 0 then
      Herdr.run({ 'tab', 'close', a.tab_id }, { quiet = true })
    end
    return
  end
  -- herdr (0.7.4) removes a tab whose only pane died before this query can
  -- see it, so "was the user looking at the agent" can't be read off the tab.
  -- Infer it instead: the focused workspace is still the agent's, and the
  -- editor tab isn't focused (a return would have disarmed us via FocusGained).
  local list = Herdr.api({ 'workspace', 'list' }, { quiet = true })
  local focused_ws
  for _, w in ipairs(list and list.workspaces or {}) do
    if w.focused then
      focused_ws = w.workspace_id
    end
  end
  if focused_ws ~= a.workspace_id then
    return
  end
  local own = Herdr.api({ 'tab', 'get', vim.env.HERDR_TAB_ID }, { quiet = true })
  if own and own.tab and own.tab.focused then
    return
  end
  Herdr.run({ 'tab', 'focus', vim.env.HERDR_TAB_ID }, { quiet = true })
end

--- Watch `a`'s pane, replacing any previous watcher.
---@param a herd.Agent
function M.start(a)
  M.stop()
  local gen = M.state.gen
  local function watch()
    M.state.handle = M.spawn(
      { 'herdr', 'wait', 'output', a.pane_id, '--match', SENTINEL, '--timeout', tostring(TIMEOUT_MS) },
      function(stdout, stderr)
        vim.schedule(function()
          if gen ~= M.state.gen then
            return -- superseded or stopped; a newer watcher owns the state
          end
          local out = stdout .. stderr
          if out:find('pane_not_found', 1, true) then
            M.state.handle = nil
            on_pane_dead(a)
          elseif out:find('timed out', 1, true) then
            watch() -- defensive re-arm; the wait itself is the cheap steady state
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
