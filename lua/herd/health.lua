local Herdr = require('herd.herdr')
local Config = require('herd.config')

local M = {}

function M.check()
  vim.health.start('herd')

  if Herdr.installed() then
    vim.health.ok('`herdr` found on $PATH')
  else
    vim.health.error('`herdr` not found on $PATH', { 'Install herdr: https://herdr.dev/docs/install/' })
    return
  end

  if Herdr.server_running() then
    vim.health.ok('herdr server is running')
  else
    vim.health.warn('herdr server not running', { 'Launch `herdr` (it can run as a backend daemon).' })
  end

  local tools = Config.get().tools
  if vim.tbl_isempty(tools) then
    vim.health.warn('no tools configured', { 'Add tools = { claude = { cmd = { "claude" } } } to setup().' })
  else
    for name, def in pairs(tools) do
      local exe = def.cmd and def.cmd[1]
      if exe and vim.fn.executable(exe) == 1 then
        vim.health.ok(('tool %q → %s'):format(name, exe))
      else
        vim.health.warn(('tool %q: %q not executable'):format(name, tostring(exe)))
      end
    end
  end
end

return M
