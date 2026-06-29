# herd.nvim nvim-host / herdr-backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invert herd.nvim so nvim is the host UI and herdr is an invisible backend daemon — agents shown in nvim floating terminals via `herdr agent attach`, driven entirely by nvim keybinds.

**Architecture:** herd.nvim shells out to the running `herdr` server (over its socket) to spawn/list/send agents. Each agent is displayed inside an nvim floating `:terminal` running `herdr agent attach <name>`; hiding the float keeps the buffer/job alive (agent survives, instant re-show). Pure-logic modules (CLI argv building, clone/slot naming, cwd-scoped target resolution, picker formatting, terminal registry) are unit-tested with plenary-busted; live float/attach rendering is verified by a manual acceptance checklist.

**Tech Stack:** Lua, Neovim ≥ 0.10 API (`vim.system`, `vim.fn.getregion`, `nvim_open_win`, `vim.fn.termopen`), the `herdr` CLI (≥ 0.7), plenary.nvim (busted test harness, already installed at `~/.local/share/nvim/site/pack/core/opt/plenary.nvim`).

## Global Constraints

- Neovim **≥ 0.10** (uses `vim.fn.getregion()`); target nvim is 0.13-dev — fine.
- herdr **≥ 0.7** on `$PATH`, server running (verified against 0.7.1, protocol 14).
- herd.nvim talks to the `herdr` CLI **only** — no embedded second multiplexer, no direct socket protocol.
- The float must show a **clean single-agent PTY** via `herdr agent attach <name>` — never the full herdr session UI (that's the dashboard escape hatch only).
- **Hide ≠ kill:** hiding a float must keep the agent running in herdr.
- Agent **names are herdr-global-unique**; same-tool clones are numbered `claude`, `claude_2`, `claude_3`, …
- Commit identity for this repo is already `MomePP <13793017+MomePP@users.noreply.github.com>` — do not change it.
- Lua style: match the existing terse, comment-led style and `stylua.toml` in the repo (2-space indent, single quotes).
- Run all tests with:
  ```bash
  cd ~/Developer/nvim-plugins/herd.nvim && \
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
  ```

## File Structure

| File | Responsibility | Status |
| --- | --- | --- |
| `lua/herd/config.lua` | defaults: `tools`, `keys`, `win`; merge user opts. Drop `zoom`. | revise |
| `lua/herd/herdr.lua` | pure CLI client: `agents`, `next_name`, `slot_name`, `spawn`, `attach_argv`, `agent_send`, `dashboard_argv`, `server_running`, `installed`. Drop pane `focus`/`zoom`. | revise |
| `lua/herd/target.lua` | pure cwd-scoped target/slot resolution (`scoped`, `current`, `by_slot`). | create |
| `lua/herd/terminal.lua` | nvim float manager: registry `name → {buf,win}`; `open`/`hide`/`toggle`/`is_open`; `spawn_term` seam. | create |
| `lua/herd/picker.lua` | grouped agent picker from `herdr agent list` + spawn entries (`items`, `open`). | create |
| `lua/herd/init.lua` | `setup`, keymaps, `:Herd` cmd, target state, public API (`toggle`/`select`/`send`/`spawn`/`dashboard`). | rewrite |
| `lua/herd/health.lua` | `:checkhealth herd` — binary, server, tools. Drop pane checks. | revise |
| `tests/minimal_init.lua` | plenary harness (packadd plenary, rtp prepend cwd). | create |
| `tests/config_spec.lua` | config defaults + merge. | create |
| `tests/herdr_spec.lua` | argv builders, `next_name`, `slot_name`, `agents` parse, `spawn` argv (no `--split`). | create |
| `tests/target_spec.lua` | cwd-scoping, `current`, `by_slot`. | create |
| `tests/terminal_spec.lua` | registry state machine with fake `spawn_term`. | create |
| `tests/picker_spec.lua` | `items` grouping/labels. | create |
| `README.md`, `doc/herd.txt` | rewrite for the nvim-host / herdr-backend premise. | rewrite |

Decomposition note vs spec: the spec folded target resolution into `init.lua`; this plan extracts it into a pure `lua/herd/target.lua` so it is unit-testable without UI. Slot/clone *naming* lives in `herdr.lua` (it is herdr-naming, not resolution).

---

### Task 1: Test harness + config

**Files:**
- Create: `tests/minimal_init.lua`
- Create: `tests/config_spec.lua`
- Modify: `lua/herd/config.lua` (full rewrite of `defaults`)

**Interfaces:**
- Produces: `Config.setup(opts) -> Config`, `Config.get() -> Config` where
  `Config = { tools: table<string,{cmd:string[], env?:table}>, keys: { toggle, send, hide, select, dashboard }, win: { width:number, height:number, border:string, footer:boolean, winblend:number } }`. No `zoom` field.

- [ ] **Step 1: Write the plenary harness**

Create `tests/minimal_init.lua`:

```lua
-- Minimal init for plenary-busted runs. plenary lives in pack/core/opt.
vim.cmd('packadd plenary.nvim')
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
```

- [ ] **Step 2: Write the failing test**

Create `tests/config_spec.lua`:

```lua
local Config = require('herd.config')

describe('herd.config', function()
  before_each(function()
    Config.options = nil
  end)

  it('defaults: empty tools, the five keys, a win table, no zoom', function()
    local c = Config.setup({})
    assert.are.same({}, c.tools)
    assert.are.equal('<leader><Tab>', c.keys.toggle)
    assert.are.equal('<leader><Tab>', c.keys.send)
    assert.are.equal('<leader><Tab>', c.keys.hide)
    assert.is_truthy(c.keys.select)
    assert.is_truthy(c.keys.dashboard)
    assert.are.equal(0.9, c.win.width)
    assert.are.equal(0.9, c.win.height)
    assert.is_true(c.win.footer)
    assert.is_nil(c.zoom)
  end)

  it('merges user tools and overrides keys', function()
    local c = Config.setup({
      tools = { claude = { cmd = { 'claude' } } },
      keys = { select = false },
    })
    assert.are.same({ 'claude' }, c.tools.claude.cmd)
    assert.is_false(c.keys.select)
    assert.are.equal('<leader><Tab>', c.keys.toggle) -- untouched default
  end)
end)
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/config_spec.lua"
```
Expected: FAIL — assertions on `c.win`, `c.keys.hide`, etc. (current config has `zoom` and no `win`/`hide`).

- [ ] **Step 4: Rewrite `lua/herd/config.lua` defaults**

Replace the `defaults` table and class docs in `lua/herd/config.lua` (keep `setup`/`get`):

```lua
local M = {}

---@class herd.Tool
---@field cmd string[]                  argv to launch the CLI agent
---@field env? table<string, string>    extra environment for the agent process

---@class herd.Keys
---@field toggle string|false   normal: toggle this cwd's agent float (count = slot)
---@field send string|false     visual: send the selection to the active agent
---@field hide string|false     terminal: hide the float from inside
---@field select string|false   normal: grouped picker (switch / spawn)
---@field dashboard string|false normal: pop herdr's full TUI in a float

---@class herd.Win
---@field width number    fraction of columns (0..1)
---@field height number   fraction of lines (0..1)
---@field border string   nvim_open_win border style
---@field footer boolean  show "Herd: <agent>" footer
---@field winblend number terminal-window blend

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field keys herd.Keys
---@field win herd.Win

---@type herd.Config
local defaults = {
  tools = {},
  keys = {
    toggle = '<leader><Tab>',    -- (normal) toggle this cwd's agent; count = slot
    send = '<leader><Tab>',      -- (visual) send selection to the active agent
    hide = '<leader><Tab>',      -- (terminal) hide the float from inside
    select = '<leader>;',        -- (normal) grouped picker
    dashboard = '<leader>\\',    -- (normal) pop herdr's full TUI
  },
  win = {
    width = 0.9,
    height = 0.9,
    border = 'rounded',
    footer = true,
    winblend = 0,
  },
}

---@type herd.Config?
M.options = nil

---@param opts? herd.Config
---@return herd.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', defaults, opts or {})
  return M.options
end

---@return herd.Config
function M.get()
  return M.options or M.setup({})
end

return M
```

- [ ] **Step 5: Run test to verify it passes**

Run the Step 3 command. Expected: PASS (2 successes).

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/minimal_init.lua tests/config_spec.lua lua/herd/config.lua
git commit -m "feat(config): nvim-host config (win + keys), drop zoom; add plenary harness"
```

---

### Task 2: herdr.lua CLI client

**Files:**
- Modify: `lua/herd/herdr.lua`
- Create: `tests/herdr_spec.lua`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `Herdr.run(args, opts?) -> string?` and `Herdr.api(args, opts?) -> table?` (seams; unchanged).
  - `Herdr.agents(cwd?) -> herd.Agent[]`, `herd.Agent = { name:string, pane_id:string, status:string, cwd:string }`.
  - `Herdr.next_name(tool:string) -> string` (first free of `tool`, `tool_2`, …).
  - `Herdr.slot_name(base:string, n:integer) -> string` (`n==1` → `base`, else `base.."_"..n`).
  - `Herdr.spawn(name, cwd, def) -> herd.Agent?` — `herdr agent start <name> --cwd <cwd> --no-focus [--env K=V]... -- <def.cmd...>` (NO `--split`).
  - `Herdr.attach_argv(name) -> string[]` = `{ 'herdr', 'agent', 'attach', name }`.
  - `Herdr.agent_send(name, text)` — runs `herdr agent send <name> <text>`.
  - `Herdr.dashboard_argv() -> string[]` = `{ 'herdr' }`.
  - `Herdr.server_running() -> boolean`, `Herdr.installed() -> boolean` (unchanged).

- [ ] **Step 1: Write the failing test**

Create `tests/herdr_spec.lua`:

```lua
local Herdr = require('herd.herdr')

describe('herd.herdr', function()
  it('attach_argv / dashboard_argv', function()
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, Herdr.attach_argv('claude'))
    assert.are.same({ 'herdr' }, Herdr.dashboard_argv())
  end)

  it('slot_name: 1 is the base, n>1 is suffixed', function()
    assert.are.equal('claude', Herdr.slot_name('claude', 1))
    assert.are.equal('claude_2', Herdr.slot_name('claude', 2))
  end)

  it('next_name picks the first free clone slot', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = { { name = 'claude' }, { name = 'claude_2' } } }
    end
    assert.are.equal('opencode', Herdr.next_name('opencode'))
    assert.are.equal('claude_3', Herdr.next_name('claude'))
    Herdr.api = saved
  end)

  it('agents parses + filters by normalized cwd', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = {
        { name = 'a', pane_id = 'p1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', agent_status = 'working', cwd = '/tmp/y' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    local scoped = Herdr.agents(vim.fs.normalize('/tmp/x'))
    assert.are.equal(1, #scoped)
    assert.are.equal('a', scoped[1].name)
    Herdr.api = saved
  end)

  it('agent_send shells the literal-text send command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args; return '' end
    Herdr.agent_send('claude', 'hello world')
    assert.are.same({ 'agent', 'send', 'claude', 'hello world' }, got)
    Herdr.run = saved
  end)

  it('spawn builds argv with --no-focus and NO --split', function()
    local got
    local saved = Herdr.api
    Herdr.api = function(args) got = args; return { agent = { name = 'claude' } } end
    Herdr.spawn('claude', '/tmp/proj', { cmd = { 'claude', '--foo' }, env = { A = '1' } })
    -- assemble for easy assertions
    local joined = table.concat(got, ' ')
    assert.is_nil(joined:find('--split'))
    assert.is_truthy(joined:find('agent start claude', 1, true))
    assert.is_truthy(joined:find('--cwd /tmp/proj', 1, true))
    assert.is_truthy(joined:find('--no-focus', 1, true))
    assert.is_truthy(joined:find('--env A=1', 1, true))
    assert.is_truthy(joined:find('-- claude --foo', 1, true))
    Herdr.api = saved
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/herdr_spec.lua"
```
Expected: FAIL — `attach_argv`/`slot_name`/`agent_send`/`dashboard_argv` are nil; `spawn` still emits `--split`.

- [ ] **Step 3: Edit `lua/herd/herdr.lua`**

Keep `run`, `api`, `installed`, `server_running`, `agents`, `next_name` (they already work — `agents`/`next_name` are tested above). **Add** `slot_name`, `attach_argv`, `agent_send`, `dashboard_argv`; **rewrite** `spawn` to drop `--split`; **delete** `focus` and `zoom`.

Add after `next_name`:

```lua
--- Clone slot name: slot 1 is the base, slot n>1 is `base_n`.
---@param base string
---@param n integer
---@return string
function M.slot_name(base, n)
  return n <= 1 and base or (base .. '_' .. n)
end
```

Replace `spawn` with:

```lua
--- Spawn an agent in the herdr server. nvim is the host, so the agent is NOT
--- tiled next to nvim — herdr places its pane server-side and we only ever
--- `attach` to it from an nvim float.
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@return herd.Agent?
function M.spawn(name, cwd, def)
  local args = { 'agent', 'start', name, '--cwd', cwd, '--no-focus' }
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  local res = M.api(args)
  return res and res.agent
end
```

Replace `focus`/`zoom`/`send_text` (the old pane helpers) with the new surface:

```lua
--- argv to attach an nvim :terminal to a running agent's PTY (clean stream).
---@param name string
---@return string[]
function M.attach_argv(name)
  return { 'herdr', 'agent', 'attach', name }
end

--- argv to open herdr's full TUI (dashboard escape hatch).
---@return string[]
function M.dashboard_argv()
  return { 'herdr' }
end

--- Send literal text to an agent (no Enter — review then submit).
---@param name string
---@param text string
function M.agent_send(name, text)
  M.run({ 'agent', 'send', name, text })
end
```

Note: `M.agents` currently reads `a.agent_status`; keep that — the test feeds `agent_status`.

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (6 successes).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/herdr_spec.lua lua/herd/herdr.lua
git commit -m "feat(herdr): attach_argv/agent_send/dashboard_argv/slot_name; spawn drops --split"
```

---

### Task 3: target.lua resolution

**Files:**
- Create: `lua/herd/target.lua`
- Create: `tests/target_spec.lua`

**Interfaces:**
- Consumes: `herd.Agent` shape from Task 2 (`{ name, pane_id, status, cwd }`).
- Produces:
  - `Target.scoped(agents, cwd) -> herd.Agent[]` — agents whose normalized cwd equals `cwd`, name-sorted.
  - `Target.current(agents, cwd, target_name?) -> herd.Agent?` — cached `target_name` if still scoped, else first scoped, else nil.
  - `Target.by_slot(agents, cwd, n) -> herd.Agent?` — the n-th scoped agent (1-based), else nil.

- [ ] **Step 1: Write the failing test**

Create `tests/target_spec.lua`:

```lua
local Target = require('herd.target')

local function A(name, cwd, status)
  return { name = name, cwd = cwd, status = status or 'idle', pane_id = name }
end

describe('herd.target', function()
  local agents = {
    A('claude_2', '/p/a'),
    A('claude', '/p/a'),
    A('opencode', '/p/b'),
  }
  local cwd = vim.fs.normalize('/p/a')

  it('scoped filters by cwd and sorts by name', function()
    local s = Target.scoped(agents, cwd)
    assert.are.equal(2, #s)
    assert.are.equal('claude', s[1].name)
    assert.are.equal('claude_2', s[2].name)
  end)

  it('current prefers the cached target when still scoped', function()
    assert.are.equal('claude_2', Target.current(agents, cwd, 'claude_2').name)
  end)

  it('current falls back to first scoped when cache is gone/foreign', function()
    assert.are.equal('claude', Target.current(agents, cwd, 'opencode').name)
    assert.are.equal('claude', Target.current(agents, cwd, nil).name)
  end)

  it('current is nil when nothing runs in this cwd', function()
    assert.is_nil(Target.current(agents, vim.fs.normalize('/p/zzz'), nil))
  end)

  it('by_slot indexes the scoped, sorted list', function()
    assert.are.equal('claude', Target.by_slot(agents, cwd, 1).name)
    assert.are.equal('claude_2', Target.by_slot(agents, cwd, 2).name)
    assert.is_nil(Target.by_slot(agents, cwd, 3))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/target_spec.lua"
```
Expected: FAIL — module `herd.target` not found.

- [ ] **Step 3: Write `lua/herd/target.lua`**

```lua
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (5 successes).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/target_spec.lua lua/herd/target.lua
git commit -m "feat(target): pure cwd-scoped target + slot resolution"
```

---

### Task 4: terminal.lua float manager

**Files:**
- Create: `lua/herd/terminal.lua`
- Create: `tests/terminal_spec.lua`

**Interfaces:**
- Consumes: `Config.get().win` (Task 1); `Herdr.attach_argv(name)` (Task 2).
- Produces:
  - `Terminal.reg` — table `name -> { buf:integer, win?:integer }`.
  - `Terminal.spawn_term(cmd, on_exit) -> integer` — seam wrapping `vim.fn.termopen`; tests replace it.
  - `Terminal.open(name, opts?)` — `opts.cwd?` for footer; show the agent's float (reuse buffer if present).
  - `Terminal.hide(name)` — hide the float window, keep buffer/job alive.
  - `Terminal.is_open(name) -> boolean` — float window currently visible.
  - `Terminal.toggle(name, opts?)` — hide if open else open.

- [ ] **Step 1: Write the failing test**

Create `tests/terminal_spec.lua`:

```lua
local Terminal = require('herd.terminal')

describe('herd.terminal', function()
  local spawned
  before_each(function()
    Terminal.reg = {}
    spawned = {}
    -- fake the PTY spawn so headless tests don't need a real herdr server
    Terminal.spawn_term = function(cmd, _on_exit)
      spawned[#spawned + 1] = cmd
      return 4242 -- fake job id
    end
  end)

  it('open creates one buffer + visible float and runs attach for the name', function()
    Terminal.open('claude')
    local e = Terminal.reg['claude']
    assert.is_truthy(e)
    assert.is_true(vim.api.nvim_buf_is_valid(e.buf))
    assert.is_true(vim.api.nvim_win_is_valid(e.win))
    assert.is_true(Terminal.is_open('claude'))
    assert.are.same({ 'herdr', 'agent', 'attach', 'claude' }, spawned[1])
  end)

  it('hide closes the window but keeps the buffer (agent survives)', function()
    Terminal.open('claude')
    local buf = Terminal.reg['claude'].buf
    Terminal.hide('claude')
    assert.is_false(Terminal.is_open('claude'))
    assert.is_true(vim.api.nvim_buf_is_valid(buf)) -- buffer (job) retained
  end)

  it('re-open after hide reuses the buffer and does NOT re-attach', function()
    Terminal.open('claude')
    local buf = Terminal.reg['claude'].buf
    Terminal.hide('claude')
    Terminal.open('claude')
    assert.are.equal(buf, Terminal.reg['claude'].buf)
    assert.are.equal(1, #spawned) -- still only the first attach
  end)

  it('toggle flips visibility', function()
    Terminal.toggle('claude') -- opens
    assert.is_true(Terminal.is_open('claude'))
    Terminal.toggle('claude') -- hides
    assert.is_false(Terminal.is_open('claude'))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/terminal_spec.lua"
```
Expected: FAIL — module `herd.terminal` not found.

- [ ] **Step 3: Write `lua/herd/terminal.lua`**

```lua
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
  vim.api.nvim_set_current_win(win)
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (4 successes).

> Note: these tests exercise the registry/window state machine with a fake
> `spawn_term`. Real attach rendering is verified in Task 9 against a live herdr.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/terminal_spec.lua lua/herd/terminal.lua
git commit -m "feat(terminal): nvim float manager (open/hide/toggle), hide keeps job"
```

---

### Task 5: picker.lua grouped picker

**Files:**
- Create: `lua/herd/picker.lua`
- Create: `tests/picker_spec.lua`

**Interfaces:**
- Consumes: `herd.Agent[]` (Task 2); `Config.get().tools`; `Terminal.open` (Task 4); `Herdr.agents`/`Herdr.dashboard_argv` (Task 2).
- Produces:
  - `Picker.items(agents, tools) -> Item[]`, `Item = { agent?: herd.Agent, tool?: string, label: string }` — running agents grouped by cwd (sorted by cwd then name), each labelled `name  cwd  [status]`; then `+ <tool>` spawn entries (sorted) for every configured tool.
  - `Picker.open(on_choice)` — `vim.ui.select` over `items`; on pick of an agent calls `on_choice({ agent = a })`, on pick of a tool `on_choice({ tool = t })`.

- [ ] **Step 1: Write the failing test**

Create `tests/picker_spec.lua`:

```lua
local Picker = require('herd.picker')

describe('herd.picker', function()
  it('groups agents by cwd then name, then lists spawn entries', function()
    local agents = {
      { name = 'claude_2', cwd = '/p/b', status = 'working', pane_id = 'x' },
      { name = 'claude', cwd = '/p/a', status = 'idle', pane_id = 'y' },
    }
    local tools = { opencode = {}, claude = {} }
    local items = Picker.items(agents, tools)

    -- agents first, sorted by cwd ('/p/a' < '/p/b')
    assert.are.equal('claude', items[1].agent.name)
    assert.are.equal('claude_2', items[2].agent.name)
    -- labels carry name + status
    assert.is_truthy(items[1].label:find('claude', 1, true))
    assert.is_truthy(items[1].label:find('idle', 1, true))
    -- spawn entries come after, sorted, marked '+'
    assert.are.equal('claude', items[3].tool)
    assert.is_truthy(items[3].label:find('+ claude', 1, true))
    assert.are.equal('opencode', items[4].tool)
  end)

  it('empty agents → only spawn entries', function()
    local items = Picker.items({}, { claude = {} })
    assert.are.equal(1, #items)
    assert.are.equal('claude', items[1].tool)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/picker_spec.lua"
```
Expected: FAIL — module `herd.picker` not found.

- [ ] **Step 3: Write `lua/herd/picker.lua`**

```lua
--- Grouped agent picker built from `herdr agent list`: running agents (grouped
--- by project cwd) plus spawn entries for configured tools. The nvim-side
--- mirror of herdr's agent dashboard.
local Herdr = require('herd.herdr')
local Config = require('herd.config')
local Terminal = require('herd.terminal')

local M = {}

---@class herd.PickItem
---@field agent? herd.Agent
---@field tool? string
---@field label string

--- @param agents herd.Agent[]
--- @param tools table<string, herd.Tool>
--- @return herd.PickItem[]
function M.items(agents, tools)
  local running = vim.deepcopy(agents)
  table.sort(running, function(a, b)
    if (a.cwd or '') ~= (b.cwd or '') then
      return (a.cwd or '') < (b.cwd or '')
    end
    return a.name < b.name
  end)

  local items = {}
  for _, a in ipairs(running) do
    items[#items + 1] = {
      agent = a,
      label = ('%s  %s  [%s]'):format(a.name, vim.fn.fnamemodify(a.cwd or '', ':~'), a.status or '?'),
    }
  end

  local names = vim.tbl_keys(tools)
  table.sort(names)
  for _, n in ipairs(names) do
    items[#items + 1] = { tool = n, label = '+ ' .. n }
  end
  return items
end

--- Open the picker. `on_choice` receives the chosen `herd.PickItem` (or is not
--- called on cancel).
---@param on_choice fun(item: herd.PickItem)
function M.open(on_choice)
  local items = M.items(Herdr.agents(), Config.get().tools)
  if #items == 0 then
    return vim.notify('herd: no agents running and no tools configured', vim.log.levels.WARN)
  end
  vim.ui.select(items, {
    prompt = 'herd:',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      on_choice(i)
    end
  end)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (2 successes).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/picker_spec.lua lua/herd/picker.lua
git commit -m "feat(picker): grouped agent picker from herdr agent list + spawn entries"
```

---

### Task 6: init.lua rewrite (orchestration + keymaps)

**Files:**
- Modify: `lua/herd/init.lua` (full rewrite)

**Interfaces:**
- Consumes: `Config` (Task 1), `Herdr` (Task 2), `Target` (Task 3), `Terminal` (Task 4), `Picker` (Task 5).
- Produces: `M.setup(opts)`, `M.toggle()`, `M.select()`, `M.send()`, `M.spawn(tool)`, `M.dashboard()`, and `M.target` (string agent name or nil). `:Herd [toggle|select|send|spawn|dashboard]`.

- [ ] **Step 1: Write the failing test**

Create `tests/init_spec.lua`:

```lua
local Herd = require('herd')

describe('herd init', function()
  it('setup registers the :Herd command and is idempotent', function()
    Herd.setup({ tools = { claude = { cmd = { 'claude' } } } })
    assert.are.equal(1, vim.fn.exists(':Herd'))
    Herd.setup({}) -- second call must not error
  end)

  it('send is a no-op (no error) when there is no visual selection', function()
    -- not in visual mode + empty register region → returns without notifying error
    assert.has_no.errors(function()
      Herd.send()
    end)
  end)

  it('spawn errors cleanly on an unknown tool', function()
    Herd.setup({ tools = {} })
    local notified
    local saved = vim.notify
    vim.notify = function(msg, lvl) notified = { msg = msg, lvl = lvl } end
    -- stub server check so we reach the unknown-tool branch
    require('herd.herdr').server_running = function() return true end
    Herd.spawn('nope')
    vim.notify = saved
    assert.is_truthy(notified and notified.msg:find('unknown tool', 1, true))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/init_spec.lua"
```
Expected: FAIL — current `init.lua` has no `dashboard`, different `spawn` flow, and `send` references removed helpers.

- [ ] **Step 3: Rewrite `lua/herd/init.lua`**

```lua
--- herd.nvim — drive herdr coding agents from Neovim, with nvim as the host.
---
--- nvim is the top-level UI; herdr runs as a backend daemon that owns each
--- agent's PTY. Agents are shown inside nvim floating terminals attached via
--- `herdr agent attach`, and driven entirely by nvim keybinds — mirroring the
--- sidekick.nvim UX with herdr (not tmux) as the backend.
local Config = require('herd.config')
local Herdr = require('herd.herdr')
local Target = require('herd.target')
local Terminal = require('herd.terminal')
local Picker = require('herd.picker')

local M = {}

--- Name of the agent the next action targets (validated against the live list).
---@type string?
M.target = nil

---@return string
local function cwd()
  return vim.fs.normalize(vim.fn.getcwd())
end

---@return boolean
local function ensure_server()
  if Herdr.installed() and Herdr.server_running() then
    return true
  end
  vim.notify('herd: no herdr server running — launch `herdr` first', vim.log.levels.WARN)
  return false
end

--- Show an agent float and remember it as the target.
---@param a herd.Agent
local function show(a)
  M.target = a.name
  Terminal.open(a.name, { cwd = a.cwd })
end

--- Spawn a configured tool as a new agent and show it.
---@param tool string
function M.spawn(tool)
  if not ensure_server() then
    return
  end
  local def = Config.get().tools[tool]
  if not def then
    return vim.notify('herd: unknown tool ' .. tostring(tool), vim.log.levels.ERROR)
  end
  local agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def)
  if not agent then
    return -- error already surfaced by Herdr.run
  end
  show(agent)
  vim.notify('herd: spawned ' .. agent.name)
end

--- Toggle this cwd's agent float. With a count, target that slot. If the float
--- is already open for the resolved target, hide it; if no agent runs here,
--- open the picker.
function M.toggle()
  if not ensure_server() then
    return
  end
  local count = vim.v.count
  local agents = Herdr.agents()
  local a = (count > 0) and Target.by_slot(agents, cwd(), count)
    or Target.current(agents, cwd(), M.target)
  if not a then
    return M.select()
  end
  M.target = a.name
  Terminal.toggle(a.name, { cwd = a.cwd })
end

--- Grouped picker: switch to a running agent, or spawn a configured tool.
function M.select()
  if not ensure_server() then
    return
  end
  Picker.open(function(item)
    if item.agent then
      show(item.agent)
    else
      M.spawn(item.tool)
    end
  end)
end

--- The current visual selection as one string (getregion, nvim >= 0.10).
---@return string
local function selection()
  local mode = vim.fn.mode()
  if not mode:match('^[vV\22]$') then
    mode = vim.fn.visualmode()
  end
  return table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode }), '\n')
end

--- Send the visual selection to the active agent (no Enter — review then submit).
function M.send()
  local text = selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  if text == '' then
    return
  end
  if not ensure_server() then
    return
  end
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  M.target = a.name
  Herdr.agent_send(a.name, text)
  Terminal.open(a.name, { cwd = a.cwd }) -- land in the agent to submit
  vim.notify('herd → ' .. a.name)
end

--- Pop herdr's full TUI (dashboard) in a float.
function M.dashboard()
  if not ensure_server() then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local w = Config.get().win
  local width = math.max(1, math.floor(vim.o.columns * w.width))
  local height = math.max(1, math.floor(vim.o.lines * w.height))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = w.border,
  })
  vim.wo[win].winblend = w.winblend
  vim.fn.termopen(Herdr.dashboard_argv(), {
    on_exit = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  vim.cmd('startinsert')
end

---@param opts? herd.Config
function M.setup(opts)
  local cfg = Config.setup(opts)
  local map = vim.keymap.set
  if cfg.keys.toggle then
    map('n', cfg.keys.toggle, M.toggle, { desc = 'herd: toggle agent float (count = slot)' })
  end
  if cfg.keys.send then
    map('x', cfg.keys.send, M.send, { desc = 'herd: send selection' })
  end
  if cfg.keys.select then
    map('n', cfg.keys.select, M.select, { desc = 'herd: select / spawn agent' })
  end
  if cfg.keys.dashboard then
    map('n', cfg.keys.dashboard, M.dashboard, { desc = 'herd: herdr dashboard' })
  end
  -- terminal-mode hide is registered per-float by an autocmd so it is buffer-local.
  if cfg.keys.hide then
    vim.api.nvim_create_autocmd('TermOpen', {
      group = vim.api.nvim_create_augroup('herd_term', { clear = true }),
      callback = function(ev)
        -- only herd floats (terminal buffers we created are 'nofile' scratch + termopen)
        for name, e in pairs(Terminal.reg) do
          if e.buf == ev.buf then
            vim.keymap.set('t', cfg.keys.hide, function()
              Terminal.hide(name)
            end, { buffer = ev.buf, desc = 'herd: hide float' })
          end
        end
      end,
    })
  end

  vim.api.nvim_create_user_command('Herd', function(a)
    local sub = a.args ~= '' and a.args or 'toggle'
    local fn = ({ toggle = M.toggle, select = M.select, send = M.send, dashboard = M.dashboard })[sub]
    if fn then
      fn()
    elseif sub:match('^spawn%s') then
      M.spawn(sub:gsub('^spawn%s+', ''))
    else
      vim.notify('herd: unknown subcommand ' .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'toggle', 'select', 'send', 'dashboard', 'spawn' }
    end,
    desc = 'herd',
  })
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (3 successes).

- [ ] **Step 5: Run the whole suite**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
```
Expected: all spec files green (config, herdr, target, terminal, picker, init).

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add tests/init_spec.lua lua/herd/init.lua
git commit -m "feat(init): nvim-host orchestration — toggle/select/send/spawn/dashboard + keymaps"
```

---

### Task 7: health.lua

**Files:**
- Modify: `lua/herd/health.lua`

**Interfaces:**
- Consumes: `Herdr.installed`/`Herdr.server_running` (Task 2); `Config.get().tools` (Task 1).

- [ ] **Step 1: Read the current health file**

Run:
```bash
cat ~/Developer/nvim-plugins/herd.nvim/lua/herd/health.lua
```
Identify any checks that reference the old herdr-host pane model (e.g. "nvim must run inside a herdr pane", pane id lookups).

- [ ] **Step 2: Rewrite `lua/herd/health.lua`**

Replace pane-centric checks with the nvim-host model — verify binary, server, and configured tools' executables:

```lua
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
```

- [ ] **Step 3: Verify it loads**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('herd').setup({ tools = { claude = { cmd = { 'claude' } } } })" \
  -c "checkhealth herd" -c "qa" 2>&1 | head -30
```
Expected: a "herd" health section listing herdr + the claude tool, no Lua errors.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add lua/herd/health.lua
git commit -m "feat(health): nvim-host checks (binary, server, tools); drop pane checks"
```

---

### Task 8: Docs rewrite

**Files:**
- Modify: `README.md` (rewrite premise + features + usage + FAQ)
- Modify: `doc/herd.txt` (rewrite intro, setup, mappings, navigation→persistence)

**Interfaces:** none (documentation deliverable).

- [ ] **Step 1: Rewrite `README.md`**

Replace the "herdr is the host / nvim is a pane" framing throughout with the new model. Required content:
- Tagline: "Drive herdr coding agents from Neovim — **nvim is the host, herdr is the backend daemon**."
- Premise paragraph: nvim top-level; herdr owns agent PTYs (hooks + grouped dashboard); agents shown in nvim floating terminals via `herdr agent attach`; all navigation is nvim keybinds.
- Features: spawn + fullscreen float; toggle (count = slot); send selection; grouped picker; dashboard escape-hatch; persistence across nvim restarts; `:checkhealth herd`.
- Requirements: Neovim ≥ 0.10; herdr ≥ 0.7 on `$PATH` with a running server (may be a headless daemon).
- Installation/config block using the new `keys` (toggle/send/hide/select/dashboard) and `win` table from Task 1 (copy the config shape verbatim from `lua/herd/config.lua` defaults).
- Usage table mapping each default key to its action (mirror the keymap table in Task 6).
- "How it works" table:
  | What | herdr command |
  | --- | --- |
  | discover agents | `herdr agent list` |
  | spawn | `herdr agent start <name> --cwd <p> --no-focus -- <argv>` |
  | show in nvim | nvim float running `herdr agent attach <name>` |
  | send selection | `herdr agent send <name> <text>` |
  | dashboard | `herdr` (full TUI) |
- FAQ: update the "Is this the same as sidekick?" answer to "same host model (nvim hosts), different backend (herdr instead of tmux/zellij), plus herdr's hooks + dashboard." Remove the old navigation/round-trip FAQ entirely (it no longer applies). Add: "Do agents survive closing the float / quitting nvim? Yes — herdr owns the process; hide and `:q` only detach."

- [ ] **Step 2: Rewrite `doc/herd.txt`**

Mirror the README changes in vimdoc: INTRODUCTION (new premise), REQUIREMENTS (server may be a daemon; drop "nvim inside a herdr pane"), SETUP (new keys + win), MAPPINGS (toggle/send/hide/select/dashboard), replace the NAVIGATION section with a PERSISTENCE section (agents live in herdr; hide/`:q` detach without killing; rediscovered via `herdr agent list`), COMMANDS (`:Herd [toggle|select|send|spawn|dashboard]`), HEALTH.

- [ ] **Step 3: Sanity-check the help tags**

Run:
```bash
cd ~/Developer/nvim-plugins/herd.nvim && \
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "helptags doc" -c "qa" 2>&1 | head
```
Expected: no errors (tags generate cleanly).

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/nvim-plugins/herd.nvim
git add README.md doc/herd.txt
git commit -m "docs: rewrite for nvim-host / herdr-backend model"
```

---

### Task 9: Manual acceptance against a live herdr server

This task verifies the integration that unit tests cannot (real attach
rendering, detach-survival, reflow) and closes the spec's four open items. No
code unless a check fails — if one does, stop and open a fix task.

**Precondition:** a herdr server is running (`herdr status server` → `running`)
and nvim is started with herd.nvim loaded against this plugin checkout, with at
least `tools = { claude = { cmd = { 'claude' } } }` configured. Use a throwaway
agent name/cwd; do not disturb real agents.

- [ ] **Step 1: Spawn + render.** In nvim: `:Herd spawn claude`. Expect a
  fullscreen-ish float showing claude's TUI, **no herdr status bar / no `Ctrl-a`
  prefix** inside the float. (Closes open item: clean stream in a real float.)

- [ ] **Step 2: Hide ≠ kill.** Press the `hide` key (default `<leader><Tab>` in
  terminal mode) — float disappears. In a shell: `herdr agent list` still shows
  the agent. Re-press `toggle` (`<leader><Tab>` normal) — same session reappears,
  scrollback intact, no re-attach flicker.

- [ ] **Step 3: Slot addressing.** `2<leader><Tab>` (or `:Herd spawn claude`
  twice then `2<leader><Tab>`) — targets `claude_2`; `herdr agent list` shows two
  agents in this cwd.

- [ ] **Step 4: Send selection.** Visually select lines in a file, press
  `<leader><Tab>` — the text appears in the agent's input **unsent**; the float is
  focused so you can submit.

- [ ] **Step 5: Picker + grouping.** `<leader>;` — picker lists running agents
  with cwd + status and `+ claude` / `+ opencode` spawn rows; selecting an agent
  attaches it.

- [ ] **Step 6: Dashboard escape hatch.** `<leader>\` — herdr's full TUI opens in
  a float (the grouped agent dashboard from the screenshot). Closing it (or its
  quit) closes the float without killing agents.

- [ ] **Step 7: Persistence.** `:qa` nvim, reopen. `herdr agent list` unchanged;
  `<leader>;` → select the still-running agent → it re-attaches. (Closes open
  item: pure-daemon spawn/attach when nvim is not inside a herdr client.)

- [ ] **Step 8: Reflow.** With a float open, resize the nvim window
  (`<C-w>` resize or change the terminal size). The attached agent should reflow
  to the float's new size. If it does not, note it and open a follow-up to send a
  resize (herdr may need an explicit signal) — non-blocking. (Closes open item:
  attach reflow.)

- [ ] **Step 9: Cleanup.** Kill the throwaway agents:
  `herdr agent list` → for each test agent get its `pane_id` →
  `herdr pane close <pane_id>`.

- [ ] **Step 10: Commit any fixes** made during acceptance (if none, nothing to
  commit). Record reflow/double-attach findings in the spec's "Open items" if
  they needed handling.

---

## Self-Review

**Spec coverage:**
- Premise inversion / nvim-host model → Tasks 6 (init), 8 (docs).
- herdr backend (attach, hooks, dashboard) → Tasks 2 (`attach_argv`/`agent_send`/`dashboard_argv`), 6 (`dashboard`), 9 (live verify).
- Module layout (`init`/`config`/`herdr` revised, `terminal`/`picker` new, `health` revised) → Tasks 1–7. `target.lua` added as a testable extraction (noted in File Structure).
- toggleterm-style state (cwd-scoped target, slot/count) → Task 3 + Task 6 `toggle`.
- Numbered clones → Task 2 `next_name`/`slot_name`.
- Keymaps (toggle/send/hide/select/dashboard) → Tasks 1 (config), 6 (registration).
- Float + footer → Task 4.
- Send selection (no Enter) → Task 6 `send`.
- "Both" dashboard (nvim picker + herdr TUI) → Tasks 5 (picker) + 6 (`dashboard`).
- Persistence across restarts → Task 9 Step 7; docs Task 8.
- Open items (multi-line send, daemon spawn placement, reflow, double-attach) → Task 9 Steps 4/7/8 + verified pre-plan that `agent start` without `--split` works.
- Docs rewrite → Task 8.
- Health → Task 7.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every test step shows real assertions; every run step shows the exact command + expected result.

**Type consistency:** `herd.Agent = { name, pane_id, status, cwd }` used uniformly across `herdr.agents`, `target.*`, `picker.items`. `Terminal.open(name, opts?)`/`toggle(name, opts?)` signatures match their callers in `init.lua`. `Herdr.attach_argv` return shape asserted identically in `herdr_spec` and `terminal_spec`. Config keys (`toggle/send/hide/select/dashboard`, `win.{width,height,border,footer,winblend}`) defined in Task 1 and consumed in Tasks 4/6/7 with the same names.
