# herd.nvim Native Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mode = 'native'` to herd.nvim — instead of showing an agent in an nvim floating terminal, spawn it as a sibling herdr tab in nvim's own workspace and drive focus through the herdr CLI, with no nvim window involved at all.

**Architecture:** Every place `init.lua` currently means "show this agent" (`show()`, `M.toggle()`, `M.spawn()`) dispatches on `Config.get().mode`: `'float'` keeps today's exact behavior (`Terminal.*`); `'native'` calls a new `Herdr.focus_tab(tab_id)` / `Herdr.spawn_native(name, cwd, def)` pair instead. `target.lua` and `picker.lua` are untouched — they already operate purely on `herdr agent list` and don't know how an agent is displayed.

**Tech Stack:** Lua, Neovim 0.10+ API, the `herdr` CLI (shelled out via `vim.system`), plenary.nvim's busted-style test harness (already vendored at `pack/core/opt/plenary.nvim`).

## Global Constraints

- Default `mode` must stay `'float'` — zero behavior change for existing users who don't set `mode`.
- Native mode requires nvim to run **inside a herdr pane** (`$HERDR_TAB_ID` set). Missing it is a `WARN` + fallback to float for the session, not a hard error.
- No new files. All additions land in the existing `lua/herd/config.lua`, `lua/herd/herdr.lua`, `lua/herd/init.lua`.
- Native-mode dead-tab cleanup reuses the existing lazy reap-on-next-spawn pattern (`Herdr.prune_workspace`) — no background timer/poller.
- `win.*` config and `keys.hide`/`keys.newline` apply to `mode = 'float'` only; native mode has no herd-owned nvim terminal buffer for them to affect.
- Neovim >= 0.10, herdr >= 0.7.1 (existing project requirements, unchanged).
- Run a test file with: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/<file>_spec.lua"` (run from the repo root, `/Users/momeppkt/Developer/nvim-plugins/herd.nvim`).
- Design reference (read before starting): `.claude/specs/native-mode-design.md` in this repo — it documents *why* each decision below was made, including a rejected nvim-tabpage-based alternative. Do not reintroduce that alternative.

---

### Task 1: Config — `mode` option

**Files:**
- Modify: `lua/herd/config.lua:27-58`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Produces: `Config.get().mode` — `'float'` (default) | `'native'`. Consumed by Tasks 4–6.

- [ ] **Step 1: Write the failing tests**

Edit `tests/config_spec.lua` — add a `mode` assertion to the existing defaults test, and a new override test:

```lua
local Config = require('herd.config')

describe('herd.config', function()
  before_each(function()
    Config.options = nil
  end)

  it('defaults: empty tools, sidekick-style keys, fullscreen win, no zoom', function()
    local c = Config.setup({})
    assert.are.same({}, c.tools)
    assert.are.equal('float', c.mode)
    assert.are.equal('<leader>s', c.keys.toggle)
    assert.are.equal('<leader>s', c.keys.send)
    assert.are.equal('<leader>s', c.keys.hide)
    assert.are.equal('<leader>S', c.keys.select)
    assert.is_false(c.keys.dashboard)
    assert.are.equal('<S-CR>', c.keys.newline)
    assert.are.equal(1, c.win.width)
    assert.are.equal(1, c.win.height)
    assert.is_true(c.win.footer)
    assert.are.equal('', c.win.winhighlight)
    assert.is_true(c.win.mouse)
    assert.are.same({ '', '', '', '', ' ', ' ', ' ', '' }, c.win.border)
    assert.is_nil(c.zoom)
    assert.are.equal('herd.nvim', c.workspace)
  end)

  it('merges user tools and overrides keys', function()
    local c = Config.setup({
      tools = { claude = { cmd = { 'claude' } } },
      keys = { select = false },
    })
    assert.are.same({ 'claude' }, c.tools.claude.cmd)
    assert.is_false(c.keys.select)
    assert.are.equal('<leader>s', c.keys.toggle) -- untouched default
  end)

  it('mode can be overridden to native', function()
    local c = Config.setup({ mode = 'native' })
    assert.are.equal('native', c.mode)
  end)
end)
```

- [ ] **Step 2: Run tests to verify the new assertions fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/config_spec.lua"`
Expected: the `mode` assertion in the first test fails (`nil` ~= `'float'`), and the new `mode can be overridden to native` test errors (`c.mode` is `nil`).

- [ ] **Step 3: Implement**

In `lua/herd/config.lua`, replace the class annotation block and the `tools`/`workspace` lines of `defaults`:

Old:
```lua
---@class herd.Config
---@field tools table<string, herd.Tool>
---@field keys herd.Keys
---@field win herd.Win
---@field workspace string  herdr workspace label that hosts spawned agents

---@type herd.Config
local defaults = {
  tools = {},
  workspace = 'herd.nvim', -- dedicated workspace label; signals nvim-spawned agents
```

New:
```lua
---@class herd.Config
---@field tools table<string, herd.Tool>
---@field mode 'float'|'native'  display backend: 'float' (default) hosts each
---                    agent in an nvim floating terminal; 'native' shows it as
---                    a sibling herdr tab in nvim's own workspace instead —
---                    requires nvim to run inside a herdr pane. `win.*` and
---                    `keys.hide`/`keys.newline` only apply to 'float'.
---@field keys herd.Keys
---@field win herd.Win
---@field workspace string  herdr workspace label that hosts spawned agents

---@type herd.Config
local defaults = {
  tools = {},
  mode = 'float', -- 'native' requires nvim to run inside a herdr pane; see README
  workspace = 'herd.nvim', -- dedicated workspace label; signals nvim-spawned agents
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/config_spec.lua"`
Expected: `Success: 3, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/config.lua tests/config_spec.lua
git commit -m "feat(config): add mode option ('float' default | 'native')"
```

---

### Task 2: Herdr — `focus_tab` + `tab_id` on `agents()`

**Files:**
- Modify: `lua/herd/herdr.lua:44-49` (Agent class), `:53-65` (`M.agents`), add near `:200-204` (`M.focus_workspace`)
- Test: `tests/herdr_spec.lua`

**Interfaces:**
- Consumes: `M.run` (existing).
- Produces: `Herdr.focus_tab(tab_id: string)` — runs `herdr tab focus <tab_id>`. `herd.Agent.tab_id: string` field, populated by `Herdr.agents()`. Consumed by Task 5/6 (`init.lua` dispatch) and Task 3 (`spawn_native` sets it directly on its own return value, independent of this).

- [ ] **Step 1: Write the failing tests**

In `tests/herdr_spec.lua`, replace the existing `'agents parses, filters by normalized cwd, and drops nameless agents'` test with a version that also covers `tab_id`, and add a new `focus_tab` test right after the existing `focus_workspace` test:

```lua
  it('focus_workspace runs the workspace focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.focus_workspace('wH')
    assert.are.same({ 'workspace', 'focus', 'wH' }, got)
    Herdr.run = saved
  end)

  it('focus_tab runs the tab focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.focus_tab('wH:t2')
    assert.are.same({ 'tab', 'focus', 'wH:t2' }, got)
    Herdr.run = saved
  end)
```

And replace the `agents` test body:

```lua
  it('agents parses, filters by normalized cwd, and drops nameless agents', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = {
        { name = 'a', pane_id = 'p1', tab_id = 't1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', tab_id = 't2', agent_status = 'working', cwd = '/tmp/y' },
        -- detected agent with no assigned name → must be skipped
        { pane_id = 'p3', tab_id = 't3', agent_status = 'working', cwd = '/tmp/x' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    assert.are.equal('t1', all[1].tab_id)
    local scoped = Herdr.agents(vim.fs.normalize('/tmp/x'))
    assert.are.equal(1, #scoped) -- only the named 'a', not the nameless p3
    assert.are.equal('a', scoped[1].name)
    Herdr.api = saved
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: `focus_tab runs the tab focus command` errors (`attempt to call a nil value`), and the `agents` test fails on `assert.are.equal('t1', all[1].tab_id)` (`nil` ~= `'t1'`).

- [ ] **Step 3: Implement**

In `lua/herd/herdr.lua`, add `tab_id` to the `herd.Agent` class and populate it in `M.agents`:

Old:
```lua
---@class herd.Agent
---@field name string
---@field pane_id string
---@field status string
---@field cwd string

--- Live agents, optionally scoped to a spawn-cwd.
---@param cwd? string normalized cwd to filter by
---@return herd.Agent[]
function M.agents(cwd)
  local res = M.api({ 'agent', 'list' }, { quiet = true })
  local ret = {} ---@type herd.Agent[]
  for _, a in ipairs(res and res.agents or {}) do
    -- herdr also lists DETECTED agents with no assigned name (a coding-agent
    -- process it spotted in some pane). herd targets by name, so skip the
    -- nameless ones — they break next_name / picker labels and aren't reachable.
    if a.name and (not cwd or vim.fs.normalize(a.cwd or '') == cwd) then
      ret[#ret + 1] = { name = a.name, pane_id = a.pane_id, status = a.agent_status, cwd = a.cwd }
    end
  end
  return ret
end
```

New:
```lua
---@class herd.Agent
---@field name string
---@field pane_id string
---@field tab_id string
---@field status string
---@field cwd string

--- Live agents, optionally scoped to a spawn-cwd.
---@param cwd? string normalized cwd to filter by
---@return herd.Agent[]
function M.agents(cwd)
  local res = M.api({ 'agent', 'list' }, { quiet = true })
  local ret = {} ---@type herd.Agent[]
  for _, a in ipairs(res and res.agents or {}) do
    -- herdr also lists DETECTED agents with no assigned name (a coding-agent
    -- process it spotted in some pane). herd targets by name, so skip the
    -- nameless ones — they break next_name / picker labels and aren't reachable.
    if a.name and (not cwd or vim.fs.normalize(a.cwd or '') == cwd) then
      ret[#ret + 1] =
        { name = a.name, pane_id = a.pane_id, tab_id = a.tab_id, status = a.agent_status, cwd = a.cwd }
    end
  end
  return ret
end
```

Then add `focus_tab` right after `M.focus_workspace`:

Old:
```lua
--- Focus a workspace in the herdr client (used to surface the agent pool).
---@param id string workspace id
function M.focus_workspace(id)
  M.run({ 'workspace', 'focus', id }, { quiet = true })
end
```

New:
```lua
--- Focus a workspace in the herdr client (used to surface the agent pool).
---@param id string workspace id
function M.focus_workspace(id)
  M.run({ 'workspace', 'focus', id }, { quiet = true })
end

--- Focus a specific tab — used by native mode to switch herdr's visible tab
--- between nvim's own tab and an agent's tab, in place, in the same window.
---@param tab_id string
function M.focus_tab(tab_id)
  M.run({ 'tab', 'focus', tab_id }, { quiet = true })
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: `Success: 15, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/herdr.lua tests/herdr_spec.lua
git commit -m "feat(herdr): add focus_tab and thread tab_id through agents()"
```

---

### Task 3: Herdr — `spawn_native`

**Files:**
- Modify: `lua/herd/herdr.lua` (add after `M.spawn`, i.e. after line 189 of the current file)
- Test: `tests/herdr_spec.lua`

**Interfaces:**
- Consumes: `vim.env.HERDR_WORKSPACE_ID` (real env var herdr sets on any pane it spawns, including nvim's own pane when nvim runs inside herdr), `M.api`.
- Produces: `Herdr.spawn_native(name: string, cwd: string, def: herd.Tool) -> herd.Agent?` — the returned table has `.name`, `.pane_id` (from the raw `agent start` response) and `.tab_id` (set locally from the tab just created, not assumed to be in the raw response). Returns `nil` if tab creation fails, without ever starting an agent. Consumed by Task 5 (`init.lua`'s `M.spawn`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/herdr_spec.lua`, after the `'spawn creates a labelled tab and starts the agent in it (not --workspace)'` test:

```lua
  it('spawn_native creates a tab in the env workspace, starts the agent, and closes the spare pane via the tab-create response (no pane list)', function()
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = 'w6'
    local calls = {}
    local saved_api = Herdr.api
    Herdr.api = function(args)
      calls[#calls + 1] = args
      if args[1] == 'tab' and args[2] == 'create' then
        return { tab = { tab_id = 'w6:t9' }, root_pane = { pane_id = 'w6:pS' } }
      end
      if args[1] == 'agent' and args[2] == 'start' then
        return { agent = { name = 'claude', pane_id = 'w6:pQ' } }
      end
      return {}
    end

    local agent = Herdr.spawn_native('claude', '/tmp/proj', { cmd = { 'claude' } })

    local tabcmd = table.concat(calls[1], ' ')
    assert.are.equal('tab', calls[1][1])
    assert.are.equal('create', calls[1][2])
    assert.is_truthy(tabcmd:find('--workspace w6', 1, true))
    assert.is_truthy(tabcmd:find('--label claude', 1, true))
    assert.is_truthy(tabcmd:find('--cwd /tmp/proj', 1, true))
    assert.is_truthy(tabcmd:find('--no-focus', 1, true))

    local startcmd = table.concat(calls[2], ' ')
    assert.is_truthy(startcmd:find('agent start claude', 1, true))
    assert.is_truthy(startcmd:find('--tab w6:t9', 1, true))
    assert.is_nil(startcmd:find('--workspace'))
    assert.is_nil(startcmd:find('--split'))

    -- the spare pane id came straight from the tab-create response — no
    -- follow-up `pane list` round trip, unlike float mode's M.spawn.
    assert.are.same({ 'pane', 'close', 'w6:pS' }, calls[3])
    assert.are.equal(3, #calls)

    assert.are.equal('claude', agent.name)
    assert.are.equal('w6:t9', agent.tab_id)

    Herdr.api = saved_api
    vim.env.HERDR_WORKSPACE_ID = saved_ws
  end)

  it('spawn_native returns nil and never starts the agent when tab creation fails', function()
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = 'w6'
    local calls = {}
    local saved_api = Herdr.api
    Herdr.api = function(args)
      calls[#calls + 1] = args
      return {} -- 'tab create' fails: no `.tab` in the response
    end

    local agent = Herdr.spawn_native('claude', '/tmp/proj', { cmd = { 'claude' } })

    assert.is_nil(agent)
    assert.are.equal(1, #calls) -- only the failed tab-create call, no agent start

    Herdr.api = saved_api
    vim.env.HERDR_WORKSPACE_ID = saved_ws
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: both new tests error with `attempt to call a nil value (field 'spawn_native')`.

- [ ] **Step 3: Implement**

In `lua/herd/herdr.lua`, add this function after `M.spawn` (after its closing `end` on line 189, before the `attach_argv` comment block):

```lua
--- Spawn an agent as a sibling herdr tab in nvim's own workspace (native
--- mode) instead of a dedicated hidden workspace: `tab create` (no explicit
--- `--workspace`; caller's `$HERDR_WORKSPACE_ID`, so the tab lands in the
--- real project workspace nvim's own pane already lives in) → `agent start
--- --tab` → close the spare pane the tab was created with, using the pane id
--- `tab create` already returned (no `pane list` round trip needed).
---@param name string unique agent name
---@param cwd string
---@param def herd.Tool
---@return herd.Agent?
function M.spawn_native(name, cwd, def)
  local ws = vim.env.HERDR_WORKSPACE_ID
  local created = M.api({ 'tab', 'create', '--workspace', ws, '--cwd', cwd, '--label', name, '--no-focus' })
  local tab = created and created.tab and created.tab.tab_id
  if not tab then
    return nil -- error already surfaced by Herdr.run; no safe fallback placement
  end
  local spare_pane = created.root_pane and created.root_pane.pane_id
  local args = { 'agent', 'start', name, '--cwd', cwd, '--tab', tab, '--no-focus' }
  for k, v in pairs(def.env or {}) do
    vim.list_extend(args, { '--env', ('%s=%s'):format(k, tostring(v)) })
  end
  args[#args + 1] = '--'
  vim.list_extend(args, def.cmd)
  local started = M.api(args)
  local agent = started and started.agent
  if agent then
    agent.tab_id = tab
    if spare_pane then
      M.api({ 'pane', 'close', spare_pane })
    end
  end
  return agent
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: `Success: 17, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/herdr.lua tests/herdr_spec.lua
git commit -m "feat(herdr): add spawn_native for native-mode agent placement"
```

---

### Task 4: init.lua — startup guard for native mode

**Files:**
- Modify: `lua/herd/init.lua` (start of `M.setup`, currently lines 165-167)
- Test: `tests/init_spec.lua`

**Interfaces:**
- Consumes: `Config.setup` (existing), `vim.env.HERDR_TAB_ID`.
- Produces: after `M.setup({ mode = 'native' })` runs, `Config.get().mode` is `'native'` if `vim.env.HERDR_TAB_ID` was set at call time, else `'float'` (with a `WARN` notification). Consumed by Task 5/6, which trust `Config.get().mode` without re-checking the env.

- [ ] **Step 1: Write the failing tests**

Add to `tests/init_spec.lua`, after the existing `setup registers the :Herd command and is idempotent` test:

```lua
  it('setup falls back to float when native mode is requested without HERDR_TAB_ID', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = nil
    local notified
    local saved_notify = vim.notify
    vim.notify = function(msg, lvl) notified = { msg = msg, lvl = lvl } end

    Herd.setup({ mode = 'native' })

    vim.notify = saved_notify
    vim.env.HERDR_TAB_ID = saved_env
    assert.is_truthy(notified)
    assert.is_truthy(notified.msg:find('native mode requires nvim', 1, true))
    assert.are.equal(vim.log.levels.WARN, notified.lvl)
    assert.are.equal('float', require('herd.config').get().mode)
  end)

  it('setup keeps native mode when HERDR_TAB_ID is present', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    local notified = false
    local saved_notify = vim.notify
    vim.notify = function() notified = true end

    Herd.setup({ mode = 'native' })

    vim.notify = saved_notify
    vim.env.HERDR_TAB_ID = saved_env
    assert.is_false(notified)
    assert.are.equal('native', require('herd.config').get().mode)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: the first new test fails (`notified` is falsy — nothing warns yet); the second fails (`Config.get().mode` is `'native'` already, so this one may actually pass by coincidence once Task 1 lands — re-run after Step 3 regardless to confirm both pass together).

- [ ] **Step 3: Implement**

In `lua/herd/init.lua`, edit the start of `M.setup`:

Old:
```lua
---@param opts? herd.Config
function M.setup(opts)
  local cfg = Config.setup(opts)
  local map = vim.keymap.set
```

New:
```lua
---@param opts? herd.Config
function M.setup(opts)
  local cfg = Config.setup(opts)
  if cfg.mode == 'native' and not vim.env.HERDR_TAB_ID then
    vim.notify(
      'herd: native mode requires nvim to run inside a herdr pane — falling back to float',
      vim.log.levels.WARN
    )
    cfg.mode = 'float'
  end
  local map = vim.keymap.set
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: `Success: 5, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/init.lua tests/init_spec.lua
git commit -m "feat(init): warn and fall back to float when native mode has no HERDR_TAB_ID"
```

---

### Task 5: init.lua — mode dispatch (`show`, `M.toggle`, `M.spawn`, `M.send`)

**Files:**
- Modify: `lua/herd/init.lua:33-44` (`show`), `:46-71` (`M.spawn`), `:73-101` (`M.toggle`), `:131-150` (`M.send`)
- Test: `tests/init_spec.lua`

**Interfaces:**
- Consumes: `Config.get().mode` (Task 1/4), `Herdr.focus_tab` (Task 2), `Herdr.spawn_native` (Task 3).
- Produces: in native mode, `show(a)`/`M.toggle()` call `Herdr.focus_tab(a.tab_id)` instead of any `Terminal.*` function; `M.spawn(tool)` calls `Herdr.spawn_native` instead of `Herdr.spawn`/`Herdr.ensure_workspace`. In float mode, behavior is byte-for-byte unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `tests/init_spec.lua`:

```lua
  it('spawn uses spawn_native and focuses the tab in native mode', function()
    local saved_tab_env, saved_ws_env = vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID = 'w6:t1', 'w6'
    Herd.setup({ mode = 'native', tools = { claude = { cmd = { 'claude' } } } })

    local Herdr = require('herd.herdr')
    local saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus =
      Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab
    Herdr.server_running = function() return true end
    Herdr.next_name = function(tool) return tool end
    Herdr.spawn_native = function(name) return { name = name, tab_id = 'w6:t9' } end
    local pruned
    Herdr.prune_workspace = function(ws, keep) pruned = { ws, keep } end
    local focused
    Herdr.focus_tab = function(id) focused = id end
    local saved_notify = vim.notify
    vim.notify = function() end

    Herd.spawn('claude')
    vim.wait(200, function() return focused ~= nil end, 5) -- show() defers via vim.schedule

    vim.notify = saved_notify
    Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab =
      saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus
    vim.env.HERDR_TAB_ID, vim.env.HERDR_WORKSPACE_ID = saved_tab_env, saved_ws_env

    assert.are.same({ 'w6', 'w6:t9' }, pruned)
    assert.are.equal('w6:t9', focused)
  end)

  it('toggle focuses the agent tab via herdr in native mode (no float)', function()
    local saved_tab_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    Herd.setup({ mode = 'native' })

    local Herdr = require('herd.herdr')
    local Terminal = require('herd.terminal')
    local saved_server, saved_agents, saved_focus = Herdr.server_running, Herdr.agents, Herdr.focus_tab
    local saved_toggle = Terminal.toggle
    Herdr.server_running = function() return true end
    Herdr.agents = function()
      return { { name = 'claude', pane_id = 'w6:pQ', tab_id = 'w6:t9', status = 'idle', cwd = vim.fn.getcwd() } }
    end
    local focused
    Herdr.focus_tab = function(id) focused = id end
    local toggled = false
    Terminal.toggle = function() toggled = true end

    Herd.toggle()

    Herdr.server_running, Herdr.agents, Herdr.focus_tab = saved_server, saved_agents, saved_focus
    Terminal.toggle = saved_toggle
    vim.env.HERDR_TAB_ID = saved_tab_env

    assert.are.equal('w6:t9', focused)
    assert.is_false(toggled)
  end)
```

Note: `M.send`'s success path (after a real visual selection) is not given its own dispatch test here — it now delegates to the same local `show()` function `M.spawn`'s test above already exercises for both branches, and simulating a genuine headless visual-mode selection to drive `M.send()` end-to-end would test the pre-existing, unchanged `selection()` capture logic rather than this task's dispatch change. The existing `'send is a no-op (no error) when there is no visual selection'` test (unchanged) continues to guard the early-return path.

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: both new tests fail — `pruned`/`focused` stay `nil` because `M.spawn`/`M.toggle` still call the float-only path unconditionally.

- [ ] **Step 3: Implement**

In `lua/herd/init.lua`, edit `show`:

Old:
```lua
--- Show an agent float and remember it as the target.
---@param a herd.Agent
local function show(a)
  M.target = a.name
  -- Defer the float open: when show() runs inside a vim.ui.select callback (the
  -- picker), opening the float + attach synchronously races the picker teardown
  -- and the attach process gets killed (float blinks shut). A scheduled open runs
  -- after the callback returns and is reliable from every caller.
  vim.schedule(function()
    Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id })
  end)
end
```

New:
```lua
--- Show an agent (float in 'float' mode, herdr tab focus in 'native' mode)
--- and remember it as the target.
---@param a herd.Agent
local function show(a)
  M.target = a.name
  -- Defer: when show() runs inside a vim.ui.select callback (the picker),
  -- acting synchronously races the picker teardown (float mode: the attach
  -- process gets killed, float blinks shut). A scheduled action runs after
  -- the callback returns and is reliable from every caller, in both modes.
  vim.schedule(function()
    if Config.get().mode == 'native' then
      Herdr.focus_tab(a.tab_id)
    else
      Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id })
    end
  end)
end
```

Edit `M.spawn`:

Old:
```lua
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
  local ws = Herdr.ensure_workspace(Config.get().workspace)
  -- Tag the agent's tab with the originating project so the herdr sidebar reads
  -- "<herd> · <project>" instead of a bare "herd". Prefer the focused workspace's
  -- label (nvim's project), falling back to the cwd folder name.
  local project = Herdr.focused_workspace_label(Config.get().workspace)
    or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  local agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def, ws, project)
  if not agent then
    return -- error already surfaced by Herdr.run
  end
  if ws then
    Herdr.prune_workspace(ws, agent.tab_id) -- reap tabs left by killed agents
  end
  show(agent)
  vim.notify('herd: spawned ' .. agent.name)
end
```

New:
```lua
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
  local agent, prune_ws
  if Config.get().mode == 'native' then
    agent = Herdr.spawn_native(Herdr.next_name(tool), vim.fn.getcwd(), def)
    prune_ws = vim.env.HERDR_WORKSPACE_ID
  else
    local ws = Herdr.ensure_workspace(Config.get().workspace)
    -- Tag the agent's tab with the originating project so the herdr sidebar reads
    -- "<herd> · <project>" instead of a bare "herd". Prefer the focused workspace's
    -- label (nvim's project), falling back to the cwd folder name.
    local project = Herdr.focused_workspace_label(Config.get().workspace)
      or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
    agent = Herdr.spawn(Herdr.next_name(tool), vim.fn.getcwd(), def, ws, project)
    prune_ws = ws
  end
  if not agent then
    return -- error already surfaced by Herdr.run
  end
  if prune_ws then
    Herdr.prune_workspace(prune_ws, agent.tab_id) -- reap tabs left by killed agents
  end
  show(agent)
  vim.notify('herd: spawned ' .. agent.name)
end
```

Edit the end of `M.toggle`:

Old:
```lua
  if not a then
    return M.select()
  end
  M.target = a.name
  Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
end
```

New:
```lua
  if not a then
    return M.select()
  end
  M.target = a.name
  if Config.get().mode == 'native' then
    Herdr.focus_tab(a.tab_id)
  else
    Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
  end
end
```

Edit the end of `M.send` (replace the manual target-set + scheduled `Terminal.open` with the shared `show()`):

Old:
```lua
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  M.target = a.name
  Herdr.agent_send(a.pane_id, text) -- target the unambiguous pane, not the name
  vim.schedule(function()
    Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id }) -- land in the agent to submit
  end)
  vim.notify('herd → ' .. a.name)
end
```

New:
```lua
  local a = Target.current(Herdr.agents(), cwd(), M.target)
  if not a then
    return vim.notify('herd: no agents running in this project', vim.log.levels.WARN)
  end
  Herdr.agent_send(a.pane_id, text) -- target the unambiguous pane, not the name
  show(a) -- land in the agent to submit
  vim.notify('herd → ' .. a.name)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: `Success: 7, Failed: 0, Errors: 0`

Also re-run the full suite to confirm no float-mode regression:

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua" && nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/terminal_spec.lua" && nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/target_spec.lua" && nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/picker_spec.lua"`
Expected: all four report `Failed: 0, Errors: 0`.

- [ ] **Step 5: Commit**

```bash
git add lua/herd/init.lua tests/init_spec.lua
git commit -m "feat(init): dispatch show/toggle/spawn/send on mode (float vs native)"
```

---

### Task 6: init.lua — gate float-only autocmds on mode

**Files:**
- Modify: `lua/herd/init.lua` (the `TermOpen` block and the `win.mouse` block, both currently inside `M.setup`, after the keymap registrations)
- Test: `tests/init_spec.lua`

**Interfaces:**
- Consumes: `Config.get().mode` (Task 1/4).
- Produces: in native mode, the `herd_term` and `herd_mouse` augroups are never created (no `TermOpen`-based `keys.hide`/`keys.newline` registration, no `win.mouse` passthrough) since there is no herd-owned nvim terminal buffer for them to affect. Float mode behavior is unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `tests/init_spec.lua`:

```lua
  it('native mode skips the float-only TermOpen and mouse-passthrough autocmds', function()
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_term')
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_mouse')
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'

    Herd.setup({ mode = 'native', keys = { hide = '<leader>s', newline = '<S-CR>' }, win = { mouse = false } })

    vim.env.HERDR_TAB_ID = saved_env
    assert.has_error(function()
      vim.api.nvim_get_autocmds({ group = 'herd_term' })
    end)
    assert.has_error(function()
      vim.api.nvim_get_autocmds({ group = 'herd_mouse' })
    end)
  end)

  it('float mode still registers the TermOpen and mouse-passthrough autocmds', function()
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_term')
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_mouse')

    Herd.setup({ mode = 'float', keys = { hide = '<leader>s', newline = '<S-CR>' }, win = { mouse = false } })

    assert.is_true(#vim.api.nvim_get_autocmds({ group = 'herd_term' }) > 0)
    assert.is_true(#vim.api.nvim_get_autocmds({ group = 'herd_mouse' }) > 0)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: the native-mode test fails — both augroups get created regardless of mode today, so `nvim_get_autocmds` does not error.

- [ ] **Step 3: Implement**

In `lua/herd/init.lua`, gate both blocks on `cfg.mode == 'float'`:

Old:
```lua
  -- terminal-mode hide/newline are registered per-float by an autocmd so they are buffer-local.
  if cfg.keys.hide or cfg.keys.newline then
```

New:
```lua
  -- terminal-mode hide/newline are registered per-float by an autocmd so they are
  -- buffer-local. Float-only: native mode has no herd-owned nvim terminal buffer.
  if cfg.mode == 'float' and (cfg.keys.hide or cfg.keys.newline) then
```

Old:
```lua
  -- win.mouse = false: hand the mouse to the terminal (Ghostty) while an agent
  -- float is focused, so a plain click-drag does native terminal selection instead
  -- of being forwarded to the agent. Restored on leaving the float.
  if cfg.win.mouse == false then
```

New:
```lua
  -- win.mouse = false: hand the mouse to the terminal (Ghostty) while an agent
  -- float is focused, so a plain click-drag does native terminal selection instead
  -- of being forwarded to the agent. Restored on leaving the float. Float-only:
  -- native mode has no herd-owned nvim terminal buffer to hand the mouse away from.
  if cfg.mode == 'float' and cfg.win.mouse == false then
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: `Success: 9, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/init.lua tests/init_spec.lua
git commit -m "feat(init): skip float-only autocmds (TermOpen keys, win.mouse) in native mode"
```

---

### Task 7: Documentation — README + vimdoc

**Files:**
- Modify: `README.md`
- Modify: `doc/herd.txt`

**Interfaces:**
- Consumes: nothing (docs only).
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Update the README config example**

In `README.md`, in the "Defaults" code block under "⚙️ Configuration", add `mode` right after `tools`:

Old:
```lua
require('herd').setup({
  -- Spawnable agents. Key = tool name, `cmd` = argv, `env` = extra environment.
  tools = {},

  workspace = 'herd.nvim',  -- herdr workspace label that hosts spawned agents (kept off your project tabs)
```

New:
```lua
require('herd').setup({
  -- Spawnable agents. Key = tool name, `cmd` = argv, `env` = extra environment.
  tools = {},

  mode = 'float',  -- 'native' shows agents as herdr tabs instead of nvim floats
                    -- (requires nvim to run inside a herdr pane). See "Native mode" below.

  workspace = 'herd.nvim',  -- herdr workspace label that hosts spawned agents (kept off your project tabs)
```

- [ ] **Step 2: Add a "Native mode" section to the README**

In `README.md`, insert a new section right before `## ❓ FAQ`:

```markdown
## 🧭 Native mode

`mode = 'native'` swaps the display backend: instead of showing an agent in
an nvim floating terminal, herd.nvim spawns it as a **sibling herdr tab in
nvim's own workspace** and drives focus through the herdr CLI. There is no
nvim window (float or tab) for the agent at all — scrolling, clicking, and
drag-select are native Ghostty-over-herdr behavior, with none of the
`win.mouse` trade-off float mode has.

**Requires nvim to run inside a herdr pane** (native mode reads
`$HERDR_TAB_ID`/`$HERDR_WORKSPACE_ID` from the environment herdr sets on any
pane it spawns). Without it, `setup()` warns and falls back to float mode for
the session.

`win.*` and `keys.hide`/`keys.newline` only apply to `mode = 'float'` —
native mode has no herd-owned nvim terminal buffer for them to affect.

Going *to* an agent is an nvim action (`<leader>s`/`<leader>S`, same keys as
float mode); coming *back* is not — nvim isn't focused/receiving input while
herdr shows another tab, so the return trip is ordinary herdr tab/pane
navigation instead:

- `last_pane` (tmux-style last-pane toggle) if your herdr config binds it —
  jumps back to whichever pane you were on before.
- `previous_tab`/`next_tab` as a fallback, cycling tabs within the workspace.
- `next_agent`/`previous_agent` to jump directly to a specific agent via
  herdr's own agents sidebar, independent of the round trip.

Bind these in `~/.config/herdr/config.toml`'s `[keys]` section — they're
herdr-native navigation, not something herd.nvim can configure.
```

- [ ] **Step 3: Mirror both changes into `doc/herd.txt`**

In `doc/herd.txt`, add `mode` to the Options section right after `tools`:

Old:
```
    tools   table<string, { cmd: string[], env?: table }>   (default: {})
            Spawnable agents. The key is the tool name; `cmd` is the argv.

    keys    { toggle, send, hide, select, dashboard, newline }
```

New:
```
    tools   table<string, { cmd: string[], env?: table }>   (default: {})
            Spawnable agents. The key is the tool name; `cmd` is the argv.

    mode    'float'|'native'                                (default: "float")
            'float' hosts each agent in an nvim floating terminal (unchanged
            default behavior). 'native' shows it as a sibling herdr tab in
            nvim's own workspace instead, with no nvim window at all —
            requires nvim to run inside a herdr pane; see |herd-native-mode|.
            `win.*` and `keys.hide`/`keys.newline` apply to 'float' only.

    keys    { toggle, send, hide, select, dashboard, newline }
```

Then add a new section after `PERSISTENCE` (before `COMMANDS`):

Old:
```
Agents are rediscovered via `herdr agent list`; as long as the herdr server
is running, sessions persist across nvim restarts.

==============================================================================
COMMANDS                                                      *herd-commands*
```

New:
```
Agents are rediscovered via `herdr agent list`; as long as the herdr server
is running, sessions persist across nvim restarts.

==============================================================================
NATIVE MODE                                               *herd-native-mode*

`mode = 'native'` spawns an agent as a sibling herdr tab in nvim's own
workspace and focuses it via the herdr CLI, instead of an nvim floating
terminal. There is no nvim window (float or tab) for the agent — scrolling,
clicking, and drag-select are native Ghostty-over-herdr behavior.

Requires nvim to run inside a herdr pane (`$HERDR_TAB_ID` must be set);
otherwise `setup()` warns and falls back to "float" for the session.

Going to an agent is an nvim action (same keys as float mode). Coming back is
not — nvim isn't focused while herdr shows another tab, so it's ordinary
herdr tab/pane navigation instead: `last_pane` (if bound), `previous_tab` /
`next_tab`, or `next_agent` / `previous_agent`. Configure these in
`~/.config/herdr/config.toml`'s `[keys]` section, not in herd.nvim.

==============================================================================
COMMANDS                                                      *herd-commands*
```

- [ ] **Step 4: Regenerate helptags and verify**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "helptags doc" -c "qa"`
Expected: exit code 0, no error output (matches this project's existing docs-change convention).

- [ ] **Step 5: Run the full test suite one more time**

Run: `for f in tests/*_spec.lua; do nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile $f"; done`
Expected: every file reports `Failed: 0, Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add README.md doc/herd.txt
git commit -m "docs: document mode option and native-mode return-trip keybinds"
```
