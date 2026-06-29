--- Pure cwd-scoped target resolution. No UI, no herdr calls — operates on a
--- plain agent list so it is unit-testable.
local M = {}

---@param agents herd.Agent[]
---@param cwd string normalized cwd
---@return herd.Agent[]
function M.scoped(agents, cwd)
  local out = {}
  for _, a in ipairs(agents) do
    if vim.fs.normalize(a.cwd or '') == cwd then
      out[#out + 1] = a
    end
  end
  table.sort(out, function(x, y)
    return x.name < y.name
  end)
  return out
end

--- Cached target if still running in this cwd, else the first scoped agent.
---@param agents herd.Agent[]
---@param cwd string
---@param target_name? string
---@return herd.Agent?
function M.current(agents, cwd, target_name)
  local s = M.scoped(agents, cwd)
  if #s == 0 then
    return nil
  end
  if target_name then
    for _, a in ipairs(s) do
      if a.name == target_name then
        return a
      end
    end
  end
  return s[1]
end

--- The n-th scoped agent (1-based), or nil.
---@param agents herd.Agent[]
---@param cwd string
---@param n integer
---@return herd.Agent?
function M.by_slot(agents, cwd, n)
  return M.scoped(agents, cwd)[n]
end

return M
