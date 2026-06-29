--- nvim-host float manager. One floating :terminal per agent, attached to the
--- herdr-owned PTY via `herdr agent attach`. Hiding keeps the buffer (and its
--- terminal job) alive so the agent survives and re-show is instant.
local Config = require('herd.config')
local Herdr = require('herd.herdr')

local M = {}

--- name -> { buf, win? }
---@type table<string, { buf: integer, win?: integer }>
M.reg = {}

--- Seam: open a terminal running `cmd` in the current buffer. Returns the job
--- id. Tests replace this so headless runs need no real herdr server.
---@param cmd string[]
---@param on_exit fun(job: integer, code: integer, event: string)
---@return integer
function M.spawn_term(cmd, on_exit)
  return vim.fn.termopen(cmd, { on_exit = on_exit })
end

--- Build the floating window over `buf`, sized per config.win.
---@param buf integer
---@param footer_text string
---@return integer win
local function open_float(buf, footer_text)
  local w = Config.get().win
  local width = math.max(1, math.floor(vim.o.columns * w.width))
  local height = math.max(1, math.floor(vim.o.lines * w.height))
  local cfg = {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = w.border,
  }
  if w.footer then
    cfg.footer = { { ' ' .. footer_text .. ' ', 'FloatFooter' } }
    cfg.footer_pos = 'left'
  end
  local win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].winblend = w.winblend
  if w.winhighlight and w.winhighlight ~= '' then
    vim.wo[win].winhighlight = w.winhighlight
  end
  return win
end

--- Show the agent's float, reusing its buffer/job if it already exists.
---@param name string
---@param opts? { cwd?: string }
function M.open(name, opts)
  opts = opts or {}
  local footer = 'Herd: ' .. name .. (opts.cwd and ('  ' .. vim.fn.fnamemodify(opts.cwd, ':~')) or '')
  local e = M.reg[name]
  if e and vim.api.nvim_buf_is_valid(e.buf) then
    if e.win and vim.api.nvim_win_is_valid(e.win) then
      vim.api.nvim_set_current_win(e.win)
    else
      e.win = open_float(e.buf, footer)
    end
    vim.cmd('startinsert')
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  M.reg[name] = { buf = buf }
  local win = open_float(buf, footer)
  M.reg[name].win = win
  -- termopen acts on the current buffer (the float's buffer).
  M.spawn_term(Herdr.attach_argv(name), function()
    local cur = M.reg[name]
    if cur and cur.win and vim.api.nvim_win_is_valid(cur.win) then
      pcall(vim.api.nvim_win_close, cur.win, true)
    end
    M.reg[name] = nil
  end)
  vim.cmd('startinsert')
end

--- Hide the float, keeping the buffer (and terminal job) alive.
---@param name string
function M.hide(name)
  local e = M.reg[name]
  if e and e.win and vim.api.nvim_win_is_valid(e.win) then
    vim.api.nvim_win_hide(e.win)
    e.win = nil
  end
end

---@param name string
---@return boolean
function M.is_open(name)
  local e = M.reg[name]
  return e ~= nil and e.win ~= nil and vim.api.nvim_win_is_valid(e.win)
end

---@param name string
---@param opts? { cwd?: string }
function M.toggle(name, opts)
  if M.is_open(name) then
    M.hide(name)
  else
    M.open(name, opts)
  end
end

return M
