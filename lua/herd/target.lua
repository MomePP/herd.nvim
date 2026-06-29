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

--- Strip a trailing clone suffix: 'claude_2' -> 'claude', 'claude' -> 'claude'.
--- Only a trailing _<digits> is removed (e.g. 'open_code' is unchanged).
---@param name string
---@return string
function M.base_of(name)
  return (name:gsub('_%d+$', ''))
end

--- Infer which configured tool to spawn when addressing an empty slot:
---   1. the current target's base (if it is a configured tool),
---   2. else the first scoped agent's base (if a configured tool),
---   3. else the sole configured tool, if exactly one is configured,
---   4. else nil (caller falls back to the picker).
---@param agents herd.Agent[]
---@param cwd string normalized cwd
---@param target_name? string
---@param tools table<string, any> configured tools (keyed by name)
---@return string?
function M.infer_base(agents, cwd, target_name, tools)
  local function configured(b)
    return (b and tools[b] ~= nil) and b or nil
  end
  if target_name then
    local b = configured(M.base_of(target_name))
    if b then
      return b
    end
  end
  local s = M.scoped(agents, cwd)
  if s[1] then
    local b = configured(M.base_of(s[1].name))
    if b then
      return b
    end
  end
  local names = vim.tbl_keys(tools)
  if #names == 1 then
    return names[1]
  end
  return nil
end

return M
