# herd.nvim Native-Mode Round Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give native mode a full agent↔editor round trip — a herdr-side `herd-return` gesture that jumps from any agent tab back to the editor tab that spawned it, and an nvim-side global agent picker for cross-project jumps — plus an agent-first CLI cleanup and an opt-in "editor in the agents panel" experiment.

**Architecture:** All origin-resolution logic lives in a new pure module `lua/herd/origin.lua` (herdr list-tables in → target tab_id out), consumed by a new `bin/herd-return.lua` script run headlessly via `nvim -l` from a herdr `[[keys.command]]` binding. The nvim side extends `picker.lua` with a global (cross-workspace) variant that `M.dashboard()` dispatches to in native mode. No stored state anywhere: the origin link is the `<project>:<agent>` tab label herd already writes at spawn, with the agent's spawn cwd as fallback.

**Tech Stack:** Lua, Neovim 0.10+ (`nvim -l`, `vim.system`, `vim.json`), the `herdr` CLI (≥ 0.7.1), plenary.nvim busted-style tests (vendored via the user's nvim config).

## Global Constraints

- Default `mode` stays `'float'`; float-mode behavior is unchanged **except** `M.dashboard()` gains a native-mode branch (float branch byte-identical).
- herd.nvim key defaults are **unchanged** (`<leader>s` toggle/send/hide, `<leader>S` select, `keys.dashboard = false`). Only the herdr side gains a binding (`prefix+s`, user config).
- No stored origin registry — resolution is stateless over live `herdr tab list` / `pane list` / `agent list` output.
- Neovim ≥ 0.10, herdr ≥ 0.7.1 (existing requirements, unchanged).
- Run a test file with: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/<file>_spec.lua"` from the repo root `/Users/momeppkt/Developer/nvim-plugins/herd.nvim`.
- Repo branch: `main`. Commit with `git -c user.email=13793017+MomePP@users.noreply.github.com commit ...` (the user's gh-account noreply identity).
- A live herdr server runs on this machine (`herdr status server`); Tasks 2 and 7 use it for probes. **Restore any focus state you change** (`herdr tab focus <original>`).
- Design reference (read before starting): `.claude/specs/native-round-trip-design.md` in this repo. Do not re-litigate decisions recorded there (e.g. no state file, notify+no-op fallback).

---

### Task 1: `lua/herd/origin.lua` — pure origin resolution

**Files:**
- Create: `lua/herd/origin.lua`
- Test: `tests/origin_spec.lua` (new file)

**Interfaces:**
- Consumes: nothing (pure module; raw decoded herdr list tables as arguments).
- Produces: `Origin.label_prefix(label: string?) -> string?` (everything before the LAST colon, or nil) and `Origin.resolve(tabs: table[], panes: table[], agents: table[]) -> string?, string?` (origin tab_id, or nil + human-readable reason). Consumed by Task 2 (`bin/herd-return.lua`).

- [ ] **Step 1: Write the failing tests**

Create `tests/origin_spec.lua`:

```lua
local Origin = require('herd.origin')

--- Live-shaped fixtures (herdr 0.7.1 `tab list`/`pane list`/`agent list`).
--- Workspace w6 holds two projects sharing it — "dotfiles" (~/.config) and
--- "local" (~/.local) — each with an editor tab and a native agent tab.
--- w9 has an identically-labelled "dotfiles" tab to prove workspace scoping.
local function fixtures()
  local tabs = {
    { tab_id = 'w6:t1', label = 'dotfiles', workspace_id = 'w6' },
    { tab_id = 'w6:t2', label = 'local', workspace_id = 'w6' },
    { tab_id = 'w6:tD', label = 'dotfiles:claude_2', workspace_id = 'w6' },
    { tab_id = 'w6:tE', label = 'local:claude', workspace_id = 'w6' },
    { tab_id = 'w9:t1', label = 'dotfiles', workspace_id = 'w9' },
  }
  local panes = {
    { pane_id = 'w6:p1', tab_id = 'w6:t1', workspace_id = 'w6', cwd = '/Users/u/.config', focused = false },
    { pane_id = 'w6:p2', tab_id = 'w6:t2', workspace_id = 'w6', cwd = '/Users/u/.local', focused = false },
    { pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6', cwd = '/Users/u/.config', focused = true },
    { pane_id = 'w6:pB', tab_id = 'w6:tE', workspace_id = 'w6', cwd = '/Users/u/.local', focused = false },
    { pane_id = 'w9:p1', tab_id = 'w9:t1', workspace_id = 'w9', cwd = '/Users/u/proj', focused = false },
  }
  local agents = {
    { name = 'claude_2', pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6', cwd = '/Users/u/.config' },
    { name = 'claude', pane_id = 'w6:pB', tab_id = 'w6:tE', workspace_id = 'w6', cwd = '/Users/u/.local' },
  }
  return tabs, panes, agents
end

describe('herd.origin', function()
  describe('label_prefix', function()
    it('splits at the last colon', function()
      assert.are.equal('dotfiles', Origin.label_prefix('dotfiles:claude_2'))
      assert.are.equal('a:b', Origin.label_prefix('a:b:claude'))
    end)

    it('is nil without a colon, with an empty prefix, or for a nil label', function()
      assert.is_nil(Origin.label_prefix('dotfiles'))
      assert.is_nil(Origin.label_prefix(':claude'))
      assert.is_nil(Origin.label_prefix(nil))
    end)
  end)

  describe('resolve', function()
    it('follows the label link to the origin editor tab in the same workspace', function()
      local tabs, panes, agents = fixtures()
      -- focused pane w6:pA sits in "dotfiles:claude_2" → tab labelled
      -- "dotfiles" in w6 (w9's identically-labelled tab is out of scope)
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)

    it('splits editor labels containing colons at the last colon', function()
      local tabs = {
        { tab_id = 'w1:t1', label = 'a:b', workspace_id = 'w1' },
        { tab_id = 'w1:t2', label = 'a:b:claude', workspace_id = 'w1' },
      }
      local panes = {
        { pane_id = 'w1:p1', tab_id = 'w1:t1', workspace_id = 'w1', cwd = '/x', focused = false },
        { pane_id = 'w1:p2', tab_id = 'w1:t2', workspace_id = 'w1', cwd = '/x', focused = true },
      }
      assert.are.equal('w1:t1', (Origin.resolve(tabs, panes, {})))
    end)

    it('falls back to the agent spawn cwd when the label link is broken', function()
      local tabs, panes, agents = fixtures()
      tabs[3].label = 'renamed' -- user renamed the agent tab: no colon, no link
      -- focused agent w6:pA spawn cwd /Users/u/.config → editor pane w6:p1 → tab w6:t1
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)

    it('cwd fallback never lands on another agent pane', function()
      local tabs, panes, agents = fixtures()
      tabs[3].label = 'renamed'
      panes[1].cwd = '/elsewhere' -- the real editor no longer matches...
      agents[2].cwd = '/Users/u/.config' -- ...and the OTHER agent shares the cwd
      panes[4].cwd = '/Users/u/.config'
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('no origin editor here', reason)
    end)

    it('is nil with a reason when the focused pane is not an agent', function()
      local tabs, panes, agents = fixtures()
      panes[3].focused = false
      panes[1].focused = true -- nvim's own editor pane focused
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('not an agent pane', reason)
    end)

    it('is nil with a reason when nothing is focused', function()
      local tabs, panes, agents = fixtures()
      panes[3].focused = false
      local tab_id, reason = Origin.resolve(tabs, panes, agents)
      assert.is_nil(tab_id)
      assert.are.equal('no focused pane', reason)
    end)

    it('first match wins on duplicate editor labels in one workspace', function()
      local tabs, panes, agents = fixtures()
      tabs[#tabs + 1] = { tab_id = 'w6:t7', label = 'dotfiles', workspace_id = 'w6' }
      assert.are.equal('w6:t1', (Origin.resolve(tabs, panes, agents)))
    end)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/origin_spec.lua"`
Expected: every test errors with `module 'herd.origin' not found`.

- [ ] **Step 3: Implement**

Create `lua/herd/origin.lua`:

```lua
--- Origin-editor resolution for the herd-return gesture (native mode).
--- Pure functions over already-decoded herdr `tab list` / `pane list` /
--- `agent list` tables — no CLI calls, no vim UI — so the logic is unit-
--- testable and shared by `bin/herd-return.lua`.
---
--- Native agent tabs are labelled `<origin-tab-label>:<agent>` at spawn
--- (see herdr.spawn_native); nvim's own tab is the bare `<origin-tab-label>`.
--- Resolution dereferences that link, falling back to the agent's spawn cwd.
local M = {}

--- Everything before the LAST colon of a native agent tab label, or nil.
--- Agent names (`next_name` output) never contain colons; editor tab labels
--- may — `a:b:claude` splits to `a:b`, not `a`.
---@param label string?
---@return string?
function M.label_prefix(label)
  if not label then
    return nil
  end
  local prefix = label:match('^(.*):[^:]*$')
  if prefix == nil or prefix == '' then
    return nil
  end
  return prefix
end

--- Resolve the origin editor tab for the globally focused pane.
--- Order: label link (sibling tab in the same workspace whose label equals
--- the focused tab's `<project>` prefix) → cwd fallback (a non-agent pane
--- in the same workspace whose spawn cwd equals the focused agent's).
---@param tabs table[] raw entries from `herdr tab list` (tab_id, label, workspace_id)
---@param panes table[] raw entries from `herdr pane list` (pane_id, tab_id, workspace_id, cwd, focused)
---@param agents table[] raw entries from `herdr agent list` (pane_id, cwd)
---@return string? tab_id origin tab to focus, or nil
---@return string? reason set when tab_id is nil
function M.resolve(tabs, panes, agents)
  local focused
  for _, p in ipairs(panes) do
    if p.focused then
      focused = p
      break
    end
  end
  if not focused then
    return nil, 'no focused pane'
  end

  local focused_agent, agent_panes = nil, {}
  for _, a in ipairs(agents) do
    agent_panes[a.pane_id] = true
    if a.pane_id == focused.pane_id then
      focused_agent = a
    end
  end

  -- 1) label link: focused tab "<project>:<agent>" → sibling tab "<project>"
  local focused_label
  for _, t in ipairs(tabs) do
    if t.tab_id == focused.tab_id then
      focused_label = t.label
      break
    end
  end
  local prefix = M.label_prefix(focused_label)
  if prefix then
    for _, t in ipairs(tabs) do
      if t.workspace_id == focused.workspace_id and t.tab_id ~= focused.tab_id and t.label == prefix then
        return t.tab_id
      end
    end
  end

  -- 2) cwd fallback: only meaningful when the focused pane hosts an agent
  if not focused_agent then
    return nil, 'not an agent pane'
  end
  for _, p in ipairs(panes) do
    if
      p.workspace_id == focused.workspace_id
      and p.tab_id ~= focused.tab_id
      and p.cwd == focused_agent.cwd
      and not agent_panes[p.pane_id]
    then
      return p.tab_id
    end
  end
  return nil, 'no origin editor here'
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/origin_spec.lua"`
Expected: `Success: 9, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/origin.lua tests/origin_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(origin): pure origin-editor resolution (label link + cwd fallback)"
```

---

### Task 2: `bin/herd-return.lua` — the herdr-side gesture

**Files:**
- Create: `bin/herd-return.lua`

**Interfaces:**
- Consumes: `Origin.resolve(tabs, panes, agents)` and `Origin.label_prefix` from Task 1 (via `require('herd.origin')` after a `package.path` prepend).
- Produces: a script runnable as `nvim -l bin/herd-return.lua` from any cwd. Task 8 documents it and binds it in the user's herdr config.

- [ ] **Step 1: Write the script**

Create `bin/herd-return.lua`:

```lua
--- herd-return — jump from the focused herdr agent tab back to the editor
--- tab that spawned it. Run headlessly via `nvim -l`, bound herdr-side in
--- ~/.config/herdr/config.toml:
---
---   [[keys.command]]
---   key = "prefix+s"
---   type = "shell"
---   command = "nvim -l /path/to/herd.nvim/bin/herd-return.lua"
---
--- Stateless: reads live herdr state, resolves via lua/herd/origin.lua, and
--- either focuses the origin tab or shows a herdr notification. Exits 0
--- silently when the server is unreachable (a notification is impossible
--- then, and a keypress must never surface a stack trace).

-- Resolve the plugin root from this script's own path so `require` finds
-- lua/herd/origin.lua no matter where the herdr command runs from.
local self_path = vim.fn.fnamemodify(arg[0] or debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fs.dirname(vim.fs.dirname(self_path))
package.path = ('%s/lua/?.lua;%s'):format(root, package.path)
local Origin = require('herd.origin')

--- `herdr <args>` → decoded JSON `result`, or nil (server down / bad output).
---@param args string[]
---@return table?
local function api(args)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout or '')
  return ok and decoded.result or nil
end

local tabs = api({ 'tab', 'list' })
local panes = api({ 'pane', 'list' })
local agents = api({ 'agent', 'list' })
if not (tabs and panes and agents) then
  return -- herdr unreachable: exit silently
end

local tab_id, reason = Origin.resolve(tabs.tabs or {}, panes.panes or {}, agents.agents or {})
if tab_id then
  api({ 'tab', 'focus', tab_id })
else
  api({ 'notification', 'show', 'herd: ' .. (reason or 'no origin editor here') })
end
```

- [ ] **Step 2: Live smoke test against the running herdr server**

This machine's herdr server is live and this shell runs inside a herdr agent pane, so the script's real path can be exercised. **Capture and restore focus.**

```bash
herdr tab list | grep -o '"focused":true[^}]*"tab_id":"[^"]*"' || herdr tab list
# note the focused tab id as ORIG (e.g. w6:tD) and its label
nvim -l bin/herd-return.lua
herdr tab list   # verify: if ORIG's label was "<project>:<agent>", the tab labelled "<project>" is now focused
herdr tab focus <ORIG>   # RESTORE the user's view
```

Expected: when the focused tab was a herd agent tab, focus moves to its origin editor tab; when it wasn't, a herdr notification appears and focus is unchanged. Either outcome passes — what must not happen is a Lua error or a focus change to an unrelated tab.

- [ ] **Step 3: Verify graceful degradation without a reachable server**

Run: `HERDR_SOCKET_PATH=/nonexistent nvim -l bin/herd-return.lua; echo "exit=$?"`
Expected: no output, `exit=0`. (If herdr ignores `HERDR_SOCKET_PATH` and still answers, skip this check and note it — the `res.code ~= 0` guard is exercised by the unreachable-socket path only.)

- [ ] **Step 4: Commit**

```bash
git add bin/herd-return.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(return): herd-return script — herdr keybind jumps agent → origin editor"
```

---

### Task 3: `herdr.lua` — `workspace_id` on agents, label maps

**Files:**
- Modify: `lua/herd/herdr.lua:44-67` (Agent class + `M.agents`), add after `M.tab_label` (ends line 210)
- Test: `tests/herdr_spec.lua`

**Interfaces:**
- Consumes: `M.api` (existing).
- Produces: `herd.Agent.workspace_id: string` populated by `Herdr.agents()`; `Herdr.workspace_labels() -> table<string, string>` (workspace_id → label); `Herdr.tab_labels() -> table<string, string>` (tab_id → label). Consumed by Task 4 (global picker).

- [ ] **Step 1: Write the failing tests**

In `tests/herdr_spec.lua`, replace the whole `'agents parses, filters by normalized cwd, and drops nameless agents'` test with:

```lua
  it('agents parses, filters by normalized cwd, and drops nameless agents', function()
    local saved = Herdr.api
    Herdr.api = function()
      return { agents = {
        { name = 'a', pane_id = 'p1', tab_id = 't1', workspace_id = 'w1', agent_status = 'idle', cwd = '/tmp/x' },
        { name = 'b', pane_id = 'p2', tab_id = 't2', workspace_id = 'w2', agent_status = 'working', cwd = '/tmp/y' },
        -- detected agent with no assigned name → must be skipped
        { pane_id = 'p3', tab_id = 't3', workspace_id = 'w1', agent_status = 'working', cwd = '/tmp/x' },
      } }
    end
    local all = Herdr.agents()
    assert.are.equal(2, #all)
    assert.are.equal('idle', all[1].status)
    assert.are.equal('t1', all[1].tab_id)
    assert.are.equal('w1', all[1].workspace_id)
    local scoped = Herdr.agents(vim.fs.normalize('/tmp/x'))
    assert.are.equal(1, #scoped) -- only the named 'a', not the nameless p3
    assert.are.equal('a', scoped[1].name)
    Herdr.api = saved
  end)
```

Then add two tests right after the `'tab_label returns a tab\'s label, or nil when absent'` test (the last test in the file):

```lua
  it('workspace_labels maps workspace ids to labels in one call', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same({ 'workspace', 'list' }, args)
      return { workspaces = {
        { workspace_id = 'w6', label = 'dotfiles-config' },
        { workspace_id = 'wA', label = 'tlic-dev' },
      } }
    end
    assert.are.same({ w6 = 'dotfiles-config', wA = 'tlic-dev' }, Herdr.workspace_labels())
    Herdr.api = saved
  end)

  it('tab_labels maps tab ids to labels across all workspaces in one call', function()
    local saved = Herdr.api
    Herdr.api = function(args)
      assert.are.same({ 'tab', 'list' }, args)
      return { tabs = {
        { tab_id = 'w6:tD', label = 'dotfiles:claude_2' },
        { tab_id = 'wA:t8', label = 'ado-badge:claude' },
      } }
    end
    assert.are.same(
      { ['w6:tD'] = 'dotfiles:claude_2', ['wA:t8'] = 'ado-badge:claude' },
      Herdr.tab_labels()
    )
    Herdr.api = saved
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: the `agents` test fails on `assert.are.equal('w1', all[1].workspace_id)` (`nil`), and both new tests error (`attempt to call a nil value`).

- [ ] **Step 3: Implement**

In `lua/herd/herdr.lua`, edit the Agent class and `M.agents` body.

Old:
```lua
---@class herd.Agent
---@field name string
---@field pane_id string
---@field tab_id string
---@field status string
---@field cwd string
```

New:
```lua
---@class herd.Agent
---@field name string
---@field pane_id string
---@field tab_id string
---@field workspace_id string
---@field status string
---@field cwd string
```

Old:
```lua
    if a.name and (not cwd or vim.fs.normalize(a.cwd or '') == cwd) then
      ret[#ret + 1] =
        { name = a.name, pane_id = a.pane_id, tab_id = a.tab_id, status = a.agent_status, cwd = a.cwd }
    end
```

New:
```lua
    if a.name and (not cwd or vim.fs.normalize(a.cwd or '') == cwd) then
      ret[#ret + 1] = {
        name = a.name,
        pane_id = a.pane_id,
        tab_id = a.tab_id,
        workspace_id = a.workspace_id,
        status = a.agent_status,
        cwd = a.cwd,
      }
    end
```

Then add both label-map helpers right after `M.tab_label`'s closing `end` (before the `spawn_native` comment block):

```lua
--- Map of workspace_id → label, from one `workspace list` call. Used by the
--- global picker to render cross-workspace agent rows.
---@return table<string, string>
function M.workspace_labels()
  local list = M.api({ 'workspace', 'list' }, { quiet = true })
  local ret = {}
  for _, w in ipairs(list and list.workspaces or {}) do
    ret[w.workspace_id] = w.label
  end
  return ret
end

--- Map of tab_id → label, from one `tab list` call (all workspaces). Used by
--- the global picker: a native agent tab's label (`<project>:<agent>`) already
--- names both the project and the agent.
---@return table<string, string>
function M.tab_labels()
  local list = M.api({ 'tab', 'list' }, { quiet = true })
  local ret = {}
  for _, t in ipairs(list and list.tabs or {}) do
    ret[t.tab_id] = t.label
  end
  return ret
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"`
Expected: `Success: 21, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/herdr.lua tests/herdr_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(herdr): workspace_id on agents + workspace/tab label maps"
```

---

### Task 4: `picker.lua` — global (cross-project) variant

**Files:**
- Modify: `lua/herd/picker.lua` (add after `M.items`, before `M.open`)
- Test: `tests/picker_spec.lua`

**Interfaces:**
- Consumes: `Herdr.agents()` (no cwd argument = all agents), `Herdr.workspace_labels()`, `Herdr.tab_labels()` (Task 3), `herd.Agent.workspace_id`/`tab_id`.
- Produces: `Picker.items_global(agents, ws_labels, tab_labels) -> herd.PickItem[]` (agent rows only, no spawn rows) and `Picker.open_global(on_choice: fun(item: herd.PickItem))`. Consumed by Task 5 (`M.dashboard`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/picker_spec.lua`, after the `'empty agents → only spawn entries'` test:

```lua
  it('items_global renders "<tab-label>  [status]  · <workspace>" rows sorted by workspace label', function()
    local agents = {
      { name = 'claude', cwd = '/p/a', status = 'idle', pane_id = 'wA:pN', tab_id = 'wA:t8', workspace_id = 'wA' },
      { name = 'claude_2', cwd = '/p/b', status = 'working', pane_id = 'w6:pA', tab_id = 'w6:tD', workspace_id = 'w6' },
    }
    local ws_labels = { w6 = 'dotfiles-config', wA = 'tlic-dev' }
    local tab_labels = { ['w6:tD'] = 'dotfiles:claude_2', ['wA:t8'] = 'ado-badge:claude' }
    local items = Picker.items_global(agents, ws_labels, tab_labels)

    assert.are.equal(2, #items)
    -- sorted by workspace label: dotfiles-config before tlic-dev
    assert.are.equal('claude_2', items[1].agent.name)
    assert.are.equal('dotfiles:claude_2  [working]  · dotfiles-config', items[1].label)
    assert.are.equal('ado-badge:claude  [idle]  · tlic-dev', items[2].label)
  end)

  it('items_global falls back to the agent name and "?" when labels are unknown', function()
    local items = Picker.items_global(
      { { name = 'claude', status = 'idle', pane_id = 'p', tab_id = 'tX', workspace_id = 'wX' } },
      {},
      {}
    )
    assert.are.equal(1, #items)
    assert.are.equal('claude  [idle]  · ?', items[1].label)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/picker_spec.lua"`
Expected: both new tests error with `attempt to call a nil value (field 'items_global')`.

- [ ] **Step 3: Implement**

In `lua/herd/picker.lua`, add after `M.items`'s closing `end` (before the `M.open` comment):

```lua
--- Global rows: every running agent across all workspaces, labelled
--- `<tab-label>  [<status>]  · <workspace-label>` (a native agent's tab label
--- is `<project>:<agent>`, so the row already names both). Sorted by
--- workspace label, then agent name. No spawn rows — spawning stays
--- project-scoped in the `M.items` picker.
---@param agents herd.Agent[]
---@param ws_labels table<string, string> workspace_id → label
---@param tab_labels table<string, string> tab_id → label
---@return herd.PickItem[]
function M.items_global(agents, ws_labels, tab_labels)
  local running = vim.deepcopy(agents)
  table.sort(running, function(a, b)
    local wa = ws_labels[a.workspace_id] or ''
    local wb = ws_labels[b.workspace_id] or ''
    if wa ~= wb then
      return wa < wb
    end
    return a.name < b.name
  end)
  local items = {}
  for _, a in ipairs(running) do
    items[#items + 1] = {
      agent = a,
      label = ('%s  [%s]  · %s'):format(
        tab_labels[a.tab_id] or a.name,
        a.status or '?',
        ws_labels[a.workspace_id] or '?'
      ),
    }
  end
  return items
end

--- Open the global picker over every running agent (cross-project). The
--- nvim-side dashboard for native mode. `on_choice` receives the chosen
--- `herd.PickItem` (not called on cancel).
---@param on_choice fun(item: herd.PickItem)
function M.open_global(on_choice)
  local items = M.items_global(Herdr.agents(), Herdr.workspace_labels(), Herdr.tab_labels())
  if #items == 0 then
    return vim.notify('herd: no agents running', vim.log.levels.WARN)
  end
  vim.ui.select(items, {
    prompt = 'herd (all projects):',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      on_choice(i)
    end
  end)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/picker_spec.lua"`
Expected: `Success: 4, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/picker.lua tests/picker_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(picker): global cross-project agent picker (items_global/open_global)"
```

---

### Task 5: `init.lua` — dashboard dispatches to the global picker in native mode

**Files:**
- Modify: `lua/herd/init.lua:174-184` (`M.dashboard`)
- Test: `tests/init_spec.lua`

**Interfaces:**
- Consumes: `Config.get().mode`, `Picker.open_global` (Task 4), the local `show(a)` (existing).
- Produces: in native mode `M.dashboard()` opens the global picker and focuses the selection via `show`; float mode is byte-for-byte unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `tests/init_spec.lua`, after the `'toggle focuses the agent tab via herdr in native mode (no float)'` test:

```lua
  it('dashboard opens the global agent picker in native mode', function()
    local saved_env = vim.env.HERDR_TAB_ID
    vim.env.HERDR_TAB_ID = 'w6:t1'
    Herd.setup({ mode = 'native' })

    local Herdr = require('herd.herdr')
    local Picker = require('herd.picker')
    local saved_server, saved_ensure = Herdr.server_running, Herdr.ensure_workspace
    local saved_global = Picker.open_global
    Herdr.server_running = function() return true end
    local ensured = false
    Herdr.ensure_workspace = function() ensured = true end
    local opened = false
    Picker.open_global = function() opened = true end

    Herd.dashboard()

    Herdr.server_running, Herdr.ensure_workspace = saved_server, saved_ensure
    Picker.open_global = saved_global
    vim.env.HERDR_TAB_ID = saved_env

    assert.is_true(opened)
    assert.is_false(ensured) -- the dedicated-workspace path is float-only
  end)

  it('dashboard still focuses the dedicated workspace in float mode', function()
    Herd.setup({ mode = 'float' })

    local Herdr = require('herd.herdr')
    local Picker = require('herd.picker')
    local saved_server, saved_ensure, saved_focus_ws =
      Herdr.server_running, Herdr.ensure_workspace, Herdr.focus_workspace
    local saved_global = Picker.open_global
    Herdr.server_running = function() return true end
    Herdr.ensure_workspace = function() return 'wH' end
    local focused
    Herdr.focus_workspace = function(id) focused = id end
    local opened = false
    Picker.open_global = function() opened = true end

    Herd.dashboard()

    Herdr.server_running, Herdr.ensure_workspace, Herdr.focus_workspace =
      saved_server, saved_ensure, saved_focus_ws
    Picker.open_global = saved_global

    assert.are.equal('wH', focused)
    assert.is_false(opened)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: the native-mode test fails (`opened` stays false, `ensured` becomes true — dashboard unconditionally takes the workspace path today); the float test passes already (guards against regression).

- [ ] **Step 3: Implement**

In `lua/herd/init.lua`, edit `M.dashboard`.

Old:
```lua
--- Surface the agent pool: focus the dedicated herd workspace in the herdr client.
function M.dashboard()
  if not ensure_server() then
    return
  end
  local ws = Herdr.ensure_workspace(Config.get().workspace)
  if not ws then
    return vim.notify('herd: could not resolve the herd workspace', vim.log.levels.WARN)
  end
  Herdr.focus_workspace(ws)
end
```

New:
```lua
--- Surface the agent pool. Float mode: focus the dedicated herd workspace in
--- the herdr client. Native mode: agents live in real project workspaces (the
--- dedicated workspace is unused), so open a global picker over every running
--- agent instead — selecting one focuses it, flipping workspace when needed.
function M.dashboard()
  if not ensure_server() then
    return
  end
  if Config.get().mode == 'native' then
    return Picker.open_global(function(item)
      show(item.agent)
    end)
  end
  local ws = Herdr.ensure_workspace(Config.get().workspace)
  if not ws then
    return vim.notify('herd: could not resolve the herd workspace', vim.log.levels.WARN)
  end
  Herdr.focus_workspace(ws)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"`
Expected: `Success: 11, Failed: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add lua/herd/init.lua tests/init_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(init): native-mode dashboard = global cross-project agent picker"
```

---

### Task 6: `experimental.editor_agent` — editor in the agents panel (opt-in)

**Files:**
- Modify: `lua/herd/config.lua` (class annotations + `defaults`)
- Modify: `lua/herd/herdr.lua` (add after `M.agent_send`)
- Modify: `lua/herd/init.lua` (inside `M.setup`, after the native-mode fallback guard)
- Test: `tests/config_spec.lua`, `tests/herdr_spec.lua`, `tests/init_spec.lua`

**Interfaces:**
- Consumes: `Config.get().experimental.editor_agent`, `vim.env.HERDR_PANE_ID`/`HERDR_TAB_ID`, `Herdr.tab_label` (existing).
- Produces: `Herdr.report_editor(pane_id: string, project: string)` (`herdr pane report-agent ... --source herd.nvim --state idle`), `Herdr.release_editor(pane_id: string, project: string)` (`herdr pane release-agent ...`), and a `herd_editor_agent` augroup with a `VimLeavePre` release. Nothing later depends on this task.

- [ ] **Step 1: Write the failing tests**

Add to `tests/config_spec.lua`, after the `'mode can be overridden to native'` test:

```lua
  it('experimental defaults: editor_agent off', function()
    local c = Config.setup({})
    assert.is_false(c.experimental.editor_agent)
  end)
```

Add to `tests/herdr_spec.lua`, after the `tab_labels` test (Task 3):

```lua
  it('report_editor reports nvim as a herd.nvim-sourced agent row', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.report_editor('w6:p1', 'dotfiles')
    assert.are.same(
      { 'pane', 'report-agent', 'w6:p1', '--source', 'herd.nvim', '--agent', 'dotfiles', '--state', 'idle' },
      got
    )
    Herdr.run = saved
  end)

  it('release_editor removes the reported editor row', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.release_editor('w6:p1', 'dotfiles')
    assert.are.same(
      { 'pane', 'release-agent', 'w6:p1', '--source', 'herd.nvim', '--agent', 'dotfiles' },
      got
    )
    Herdr.run = saved
  end)
```

Add to `tests/init_spec.lua`, after the two dashboard tests (Task 5):

```lua
  it('setup reports the editor into the agents panel when editor_agent is on (native)', function()
    local saved_tab, saved_pane = vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID
    vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID = 'w6:t1', 'w6:p1'
    local Herdr = require('herd.herdr')
    local saved_report, saved_label = Herdr.report_editor, Herdr.tab_label
    Herdr.tab_label = function() return 'dotfiles' end
    local reported
    Herdr.report_editor = function(pane, project) reported = { pane, project } end

    Herd.setup({ mode = 'native', experimental = { editor_agent = true } })

    Herdr.report_editor, Herdr.tab_label = saved_report, saved_label
    vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID = saved_tab, saved_pane

    assert.are.same({ 'w6:p1', 'dotfiles' }, reported)
    assert.is_true(#vim.api.nvim_get_autocmds({ group = 'herd_editor_agent' }) > 0)
  end)

  it('setup does not report the editor by default', function()
    pcall(vim.api.nvim_del_augroup_by_name, 'herd_editor_agent')
    local saved_tab, saved_pane = vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID
    vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID = 'w6:t1', 'w6:p1'
    local Herdr = require('herd.herdr')
    local saved_report = Herdr.report_editor
    local reported = false
    Herdr.report_editor = function() reported = true end

    Herd.setup({ mode = 'native' })

    Herdr.report_editor = saved_report
    vim.env.HERDR_TAB_ID, vim.env.HERDR_PANE_ID = saved_tab, saved_pane

    assert.is_false(reported)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run all three files:
```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/config_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"
```
Expected: config test errors (`c.experimental` is nil); both herdr tests error (`attempt to call a nil value`); the first init test errors (stubbing `Herdr.report_editor` assigns fine, but `reported` stays nil since setup never calls it → `assert.are.same` fails).

- [ ] **Step 3: Implement — config**

In `lua/herd/config.lua`, add a class and wire it into `herd.Config` and `defaults`.

Old:
```lua
---@class herd.Config
---@field tools table<string, herd.Tool>
```

New:
```lua
---@class herd.Experimental
---@field editor_agent boolean  native only: report nvim's own pane into herdr's
---                    agents panel (source `herd.nvim`), so herdr's own agent
---                    navigation (next/previous_agent, focus_agent) cycles
---                    editors alongside agents. Unstable — may change or vanish.

---@class herd.Config
---@field tools table<string, herd.Tool>
---@field experimental herd.Experimental
```

Old:
```lua
    mouse = true, -- false hands the mouse to the terminal in floats (plain-drag selection)
  },
}
```

New:
```lua
    mouse = true, -- false hands the mouse to the terminal in floats (plain-drag selection)
  },
  experimental = {
    editor_agent = false, -- native only: show this nvim in herdr's agents panel (unstable)
  },
}
```

- [ ] **Step 4: Implement — herdr**

In `lua/herd/herdr.lua`, add after `M.agent_send`'s closing `end` (before the final `return M`):

```lua
--- EXPERIMENTAL (config.experimental.editor_agent): report nvim's own pane as
--- a herd.nvim-sourced agent row, so it appears in herdr's agents panel next
--- to the agents it spawned and herdr's agent navigation cycles editors too.
---@param pane_id string nvim's own pane ($HERDR_PANE_ID)
---@param project string display label (nvim's tab label / cwd basename)
function M.report_editor(pane_id, project)
  M.run(
    { 'pane', 'report-agent', pane_id, '--source', 'herd.nvim', '--agent', project, '--state', 'idle' },
    { quiet = true }
  )
end

--- Remove the reported editor row (paired with `report_editor`; VimLeavePre).
---@param pane_id string
---@param project string
function M.release_editor(pane_id, project)
  M.run({ 'pane', 'release-agent', pane_id, '--source', 'herd.nvim', '--agent', project }, { quiet = true })
end
```

- [ ] **Step 5: Implement — init**

In `lua/herd/init.lua`, edit the start of `M.setup`.

Old:
```lua
  if cfg.mode == 'native' and not vim.env.HERDR_TAB_ID then
    vim.notify(
      'herd: native mode requires nvim to run inside a herdr pane — falling back to float',
      vim.log.levels.WARN
    )
    cfg.mode = 'float'
  end
  local map = vim.keymap.set
```

New:
```lua
  if cfg.mode == 'native' and not vim.env.HERDR_TAB_ID then
    vim.notify(
      'herd: native mode requires nvim to run inside a herdr pane — falling back to float',
      vim.log.levels.WARN
    )
    cfg.mode = 'float'
  end
  -- experimental: surface this nvim in herdr's agents panel so herdr's own
  -- agent navigation (next/previous_agent, focus_agent) cycles editors too.
  if cfg.mode == 'native' and cfg.experimental.editor_agent and vim.env.HERDR_PANE_ID then
    local pane = vim.env.HERDR_PANE_ID
    local project = Herdr.tab_label(vim.env.HERDR_TAB_ID) or vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
    Herdr.report_editor(pane, project)
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('herd_editor_agent', { clear = true }),
      callback = function()
        Herdr.release_editor(pane, project)
      end,
    })
  end
  local map = vim.keymap.set
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/config_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"
```
Expected: `Success: 4`, `Success: 23`, `Success: 13` — all `Failed: 0, Errors: 0`.

- [ ] **Step 7: Live verification of the reported-row filter**

The spec expects reported agents to be name-less in `agent list` (herd's existing nameless-skip then filters them). Verify against the live server:

```bash
herdr pane report-agent $HERDR_PANE_ID --source herd.nvim --agent plan-probe --state idle
herdr agent list   # inspect: the plan-probe row must have no "name" field (label only)
herdr pane release-agent $HERDR_PANE_ID --source herd.nvim --agent plan-probe
```

If the row **does** carry a `name`, extend the skip in `M.agents` (`lua/herd/herdr.lua`) to also drop `a.source == 'herd.nvim'` entries and add a fixture line for it in the `agents` test. Otherwise no code change — note the outcome in the commit message.

- [ ] **Step 8: Commit**

```bash
git add lua/herd/config.lua lua/herd/herdr.lua lua/herd/init.lua tests/config_spec.lua tests/herdr_spec.lua tests/init_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "feat(experimental): editor_agent — report nvim into herdr's agents panel (opt-in)"
```

---

### Task 7: Agent-first focus — `agent focus` instead of `tab focus` (gated on live probe)

**Files:**
- Modify: `lua/herd/herdr.lua:270-275` (`M.focus_tab` — replaced), `tests/herdr_spec.lua:17-24`
- Modify: `lua/herd/init.lua:33-49` (`show`), `:120-125` (`M.toggle` tail)
- Test: `tests/init_spec.lua` (stub swaps in two existing tests)

**Interfaces:**
- Consumes: `herd.Agent.pane_id` (always present).
- Produces: `Herdr.agent_focus(target: string)` running `herdr agent focus <target>`; `M.focus_tab` is **removed** (its only callers were `show`/`M.toggle`). Task 8's docs reference `agent focus`.

- [ ] **Step 1: Live equivalence probe (GATE — decides whether this task runs)**

Per the spec, `agent focus <pane_id>` must switch the visible tab (and workspace) exactly like `tab focus <tab_id>`. Probe against the live server, then **restore focus**:

```bash
herdr tab list      # note the currently focused tab id as ORIG
herdr agent list    # pick any agent (prefer one in a DIFFERENT workspace); note its pane_id + tab_id
herdr agent focus <pane_id>
herdr tab list      # verify: the agent's tab is now focused:true (and its workspace focused, if different)
herdr tab focus <ORIG>   # RESTORE
```

**If the agent's tab did NOT become focused** (e.g. only the sidebar row highlights): STOP — skip this entire task, keep `focus_tab`, and record the outcome as a dated note in `.claude/knowledges/herdr-cli-gotchas.md` (create the file if missing). Steps 2-6 apply only when the probe passes.

- [ ] **Step 2: Update the failing tests first**

In `tests/herdr_spec.lua`, replace the `focus_tab` test.

Old:
```lua
  it('focus_tab runs the tab focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.focus_tab('wH:t2')
    assert.are.same({ 'tab', 'focus', 'wH:t2' }, got)
    Herdr.run = saved
  end)
```

New:
```lua
  it('agent_focus runs the agent focus command', function()
    local got
    local saved = Herdr.run
    Herdr.run = function(args) got = args end
    Herdr.agent_focus('w6:pQ')
    assert.are.same({ 'agent', 'focus', 'w6:pQ' }, got)
    Herdr.run = saved
  end)
```

In `tests/init_spec.lua`, update the two native-mode tests to stub `agent_focus` (and give the spawned stub agent a `pane_id`).

In `'spawn uses spawn_native and focuses the tab in native mode'` — old:
```lua
    local saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label =
      Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab, Herdr.tab_label
```
new:
```lua
    local saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label =
      Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.agent_focus, Herdr.tab_label
```
old:
```lua
    Herdr.spawn_native = function(name, _cwd, _def, project)
      spawn_project = project
      return { name = name, tab_id = 'w6:t9' }
    end
```
new:
```lua
    Herdr.spawn_native = function(name, _cwd, _def, project)
      spawn_project = project
      return { name = name, tab_id = 'w6:t9', pane_id = 'w6:pQ' }
    end
```
old:
```lua
    local focused
    Herdr.focus_tab = function(id) focused = id end
```
new:
```lua
    local focused
    Herdr.agent_focus = function(id) focused = id end
```
old:
```lua
    Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.focus_tab, Herdr.tab_label =
      saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label
```
new:
```lua
    Herdr.server_running, Herdr.next_name, Herdr.spawn_native, Herdr.prune_workspace, Herdr.agent_focus, Herdr.tab_label =
      saved_server, saved_next, saved_spawn_native, saved_prune, saved_focus, saved_label
```
old:
```lua
    assert.are.same({ 'w6', 'w6:t9', 'dotfiles:' }, pruned)
    assert.are.equal('w6:t9', focused)
```
new:
```lua
    assert.are.same({ 'w6', 'w6:t9', 'dotfiles:' }, pruned)
    assert.are.equal('w6:pQ', focused)
```

In `'toggle focuses the agent tab via herdr in native mode (no float)'` — old:
```lua
    local saved_server, saved_agents, saved_focus = Herdr.server_running, Herdr.agents, Herdr.focus_tab
```
new:
```lua
    local saved_server, saved_agents, saved_focus = Herdr.server_running, Herdr.agents, Herdr.agent_focus
```
old:
```lua
    local focused
    Herdr.focus_tab = function(id) focused = id end
```
new:
```lua
    local focused
    Herdr.agent_focus = function(id) focused = id end
```
old:
```lua
    Herdr.server_running, Herdr.agents, Herdr.focus_tab = saved_server, saved_agents, saved_focus
```
new:
```lua
    Herdr.server_running, Herdr.agents, Herdr.agent_focus = saved_server, saved_agents, saved_focus
```
old:
```lua
    assert.are.equal('w6:t9', focused)
```
new:
```lua
    assert.are.equal('w6:pQ', focused)
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"
```
Expected: `agent_focus` test errors (nil field); both init tests fail (`focused` stays nil — the code still calls `focus_tab`, which the tests no longer stub).

- [ ] **Step 4: Implement**

In `lua/herd/herdr.lua`, replace `M.focus_tab`.

Old:
```lua
--- Focus a specific tab — used by native mode to switch herdr's visible tab
--- between nvim's own tab and an agent's tab, in place, in the same window.
---@param tab_id string
function M.focus_tab(tab_id)
  M.run({ 'tab', 'focus', tab_id }, { quiet = true })
end
```

New:
```lua
--- Focus an agent by its unambiguous pane id — herdr switches the visible tab
--- (and workspace, when the agent lives elsewhere) to the agent's pane. Used
--- by native mode; the agent-first equivalent of `tab focus`, verified
--- behaviorally identical against a live server.
---@param target string pane id (preferred) or unique agent name
function M.agent_focus(target)
  M.run({ 'agent', 'focus', target }, { quiet = true })
end
```

In `lua/herd/init.lua`, edit `show`.

Old:
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

New:
```lua
--- Show an agent (float in 'float' mode, herdr agent focus in 'native' mode)
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
      Herdr.agent_focus(a.pane_id)
    else
      Terminal.open(a.name, { cwd = a.cwd, pane = a.pane_id })
    end
  end)
end
```

Edit the tail of `M.toggle`.

Old:
```lua
  if Config.get().mode == 'native' then
    Herdr.focus_tab(a.tab_id)
  else
    Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
  end
```

New:
```lua
  if Config.get().mode == 'native' then
    Herdr.agent_focus(a.pane_id)
  else
    Terminal.toggle(a.name, { cwd = a.cwd, pane = a.pane_id })
  end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/herdr_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/init_spec.lua"
```
Expected: `Success: 23` and `Success: 13`, both `Failed: 0, Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/herd/herdr.lua lua/herd/init.lua tests/herdr_spec.lua tests/init_spec.lua
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "refactor(herdr): agent-first focus — agent focus <pane_id> replaces tab focus"
```

---

### Task 8: Documentation, user-side wiring, full acceptance

**Files:**
- Modify: `README.md`
- Modify: `doc/herd.txt`
- Modify (dotfiles repo, `/Users/momeppkt/.config`): `herdr/config.toml`

**Interfaces:**
- Consumes: everything above (docs only).
- Produces: nothing — final task.

- [ ] **Step 1: README — round trip + global dashboard**

In `README.md`'s "🧭 Native mode" section, append after the existing return-trip bullet list (the block ending "…not something herd.nvim can configure."):

```markdown
### Round trip: `herd-return`

The bindings above are generic herdr navigation — they don't know *which*
editor spawned the focused agent. `bin/herd-return.lua` does. Bind it in
`~/.config/herdr/config.toml` and one key jumps from any herd agent tab
back to its origin editor tab, no matter how you reached the agent
(sidebar, `next_agent`, tab cycling, workspace hops):

```toml
[[keys.command]]
key = "prefix+s"   # overrides herdr's default `settings` binding —
type = "shell"     # rebind `settings` elsewhere if you use that screen
command = "nvim -l /path/to/herd.nvim/bin/herd-return.lua"
```

Resolution is stateless, from live herdr state: the focused agent tab's
label (`dotfiles:claude_2` → the sibling tab labelled `dotfiles`), falling
back to matching the agent's spawn cwd against your editor panes. When
nothing matches (not a herd tab, editor gone) it shows a herdr notification
and does nothing — herdr has no CLI to re-dispatch the key's default action.

### Dashboard: global agent picker

In native mode `:Herd dashboard` (or `keys.dashboard`) opens a picker over
**every running agent across all projects** — rows read
`dotfiles:claude_2  [working]  · dotfiles-config` — and selecting one
focuses its tab, flipping workspace when the agent lives elsewhere.
(Float mode keeps the old behavior: focus the dedicated herd workspace.)
```

Then, in the "⚙️ Configuration" defaults block, add after the `win = { ... }` table (before the closing `})`):

```lua
  -- Experimental (unstable, may change or vanish):
  experimental = {
    editor_agent = false, -- native only: report this nvim into herdr's agents panel,
                          -- so next/previous_agent cycle editors alongside agents
  },
```

And update the Dashboard row in the "🚀 Usage" table and the "📊 Dashboard" bullet in "✨ Features" to say: float mode focuses the dedicated herd.nvim workspace; native mode opens the global cross-project agent picker.

- [ ] **Step 2: Mirror into `doc/herd.txt`**

In the Options section, extend the `dashboard` line's description with "(native mode: opens the global cross-project agent picker instead — see |herd-native-mode|)". Add to the `NATIVE MODE` section (after the return-trip navigation paragraph): a `herd-return` paragraph (the TOML binding, label-then-cwd resolution, notify+no-op fallback) and a "global dashboard" paragraph — same content as the README, condensed to vimdoc prose. Document `experimental.editor_agent` in the Options section as experimental/unstable.

- [ ] **Step 3: Regenerate helptags and run the full suite**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "helptags doc" -c "qa"
for f in tests/*_spec.lua; do nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile $f"; done
```
Expected: helptags exits 0; every spec file reports `Failed: 0, Errors: 0`
(config 4, herdr 23, init 13, origin 9, picker 4, target and terminal unchanged).

- [ ] **Step 4: Commit the plugin docs**

```bash
git add README.md doc/herd.txt
git -c user.email=13793017+MomePP@users.noreply.github.com commit -m "docs: herd-return round trip, global dashboard picker, editor_agent experiment"
```

- [ ] **Step 5: Wire the user's herdr config (dotfiles repo)**

In `/Users/momeppkt/.config/herdr/config.toml`, next to the existing "herd.nvim return trip" comment for `last_pane`, add:

```toml
# herd.nvim: prefix+s = jump from an agent tab back to the editor that
# spawned it (overrides herdr's default `settings` binding).
[[keys.command]]
key = "prefix+s"
type = "shell"
command = "nvim -l /Users/momeppkt/Developer/nvim-plugins/herd.nvim/bin/herd-return.lua"
```

Note: `[[keys.command]]` entries must come after all plain `key = value` pairs of the `[keys]` table (TOML array-of-tables ends the parent table's inline keys) — place it at the end of the `[keys]` section, following the existing commented `[[keys.command]]` example's position. Then:

```bash
herdr server reload-config
cd /Users/momeppkt/.config && git add herdr/config.toml && git commit -m "feat(herdr): bind prefix+s to herd-return (agent → origin editor)"
```

The user decided `prefix+s` may shadow `settings`; do **not** add a replacement `settings` bind unless they ask.

- [ ] **Step 6: Manual acceptance (user-interactive — hand back a checklist)**

These need real keypresses in the live herdr session; present them to the user rather than simulating:

1. Two editors in one workspace (e.g. `gogo-code`, `gogo-code-lua`), spawn an agent from each (`<leader>S`); wander to the *other* project's agent via the sidebar or `next_agent`; press `prefix+s` → lands on the **correct** editor tab.
2. Rename an agent's tab (`prefix+shift+t`), press `prefix+s` → still returns via the cwd fallback.
3. `prefix+s` on a non-agent tab → herdr notification, focus unchanged.
4. From the `dotfiles` nvim, `:Herd dashboard` → pick an agent in another workspace → herdr flips workspace and focuses it.
5. Set `experimental = { editor_agent = true }` in the nvim config, restart nvim inside herdr → editor row appears in the agents panel; `next_agent` cycles editor ↔ agent; `:q` removes the row; `<leader>S` picker does **not** list the editor as an agent.
