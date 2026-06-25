local M = {}

local Herdr = require('herd.herdr')
local Config = require('herd.config')

function M.check()
  local h = vim.health
  h.start('herd.nvim')

  if not Herdr.installed() then
    h.error('herdr not found on $PATH', {
      'Install herdr: https://herdr.dev/docs/install/  (or `brew install herdr`)',
    })
    return
  end
  local ver = (Herdr.run({ '--version' }, { quiet = true }) or 'unknown'):gsub('%s+$', '')
  h.ok('herdr found: ' .. ver)

  if Herdr.server_running() then
    h.ok('herdr server is running')
  else
    h.warn('no herdr server running', {
      'Launch `herdr` — herd targets the default-session socket your client uses',
    })
  end

  if vim.env.HERDR_PANE_ID then
    h.ok('nvim is inside a herdr pane (' .. vim.env.HERDR_PANE_ID .. ')')
  else
    h.warn('nvim is not inside a herdr pane', {
      'herd is designed for nvim hosted in a herdr pane (herdr is the multiplexer)',
    })
  end

  local tools = Config.get().tools
  local names = vim.tbl_keys(tools)
  if #names > 0 then
    table.sort(names)
    h.ok(('%d tool(s) configured: %s'):format(#names, table.concat(names, ', ')))
  else
    h.warn('no tools configured', { 'Add tools in require("herd").setup({ tools = { ... } })' })
  end
end

return M
