# herd.nvim — native-mode round trip (agent ↔ origin editor)

> **Status: SHIPPED** (merge `8fbe29b`, 2026-07-03). Historical design
> record. Superseded details: key defaults became the leader-doubled scheme
> (`<leader>\` toggle/send/hide, `<leader>s` picker, `<leader>S` dashboard)
> and herd-return moved to `prefix+\`; the Snacks rendering was scoped to
> the dashboard only; the editor_agent experiment was removed (see the
> Outcome note in its section). Current behavior: README / doc/herd.txt.

## Premise

Native mode's forward leg (editor → agent) works well, but two navigation
gaps remain when several projects share a herdr workspace:

1. **Agent → origin editor is unassisted mental work.** After wandering
   between agents (sidebar, `next_agent`, tab cycling, workspace hops),
   getting back to *the editor tab that spawned the focused agent* requires
   recalling the workspace, scanning the tab strip, and matching agent tabs
   to editor tabs by eye. herdr's `last_pane` only covers the immediate
   round trip — it forgets as soon as you wander.
2. **Cross-project agent jumps from nvim have no entry point.** The
   `<leader>S` picker is cwd-scoped, and `:Herd dashboard` still focuses the
   dedicated `herd.nvim` workspace — a float-mode concept native mode does
   not use (a real leftover misalignment).

The fix leans on state herdr already persists rather than inventing new
state: native agent tabs are labelled `<origin-tab-label>:<agent>`
(e.g. `dotfiles:claude_2`, from `Herdr.tab_label($HERDR_TAB_ID)` at spawn),
and nvim's own tab is the bare `<origin-tab-label>`. Today only the reaper
reads that link; this revision dereferences it for navigation.

Verified against a live herdr 0.7.1 server during design:

- `herdr tab list` / `pane list` mark exactly **one** entry `focused:true`
  globally — a detached script can always tell "where am I" with no env.
- herdr sets `HERDR_PANE_ID` (in addition to `HERDR_TAB_ID` /
  `HERDR_WORKSPACE_ID`) on every pane it spawns.
- `herdr tab focus <id>` flips the visible workspace when the target lives
  elsewhere — cross-workspace jumps need no extra handling.
- There is **no CLI primitive to trigger a keybind's default action** or to
  focus an arbitrary pane by id (`pane focus` is directional-only). This
  bounds what the `herd-return` fallback can do (see below).

## Goals

- **`herd return` gesture (herdr-side, `prefix+s`)**: from an agent tab,
  jump back to the editor tab that spawned it — regardless of how the agent
  was reached.
- **Global agent picker (nvim-side)**: `:Herd dashboard` / `keys.dashboard`
  in native mode lists *all* agents across workspaces and jumps to the
  selection.
- **Agent-first CLI alignment**: focus agents via `herdr agent focus
  <pane_id>` instead of `tab focus <tab_id>` where equivalent.
- **Experiment (opt-in)**: register nvim itself in herdr's agents panel so
  `next_agent`/`previous_agent`/`focus_agent` cycle through editors too.

## Non-goals

- No change to float mode's behavior (dashboard included: float mode keeps
  focusing the dedicated workspace).
- No stored origin registry (state file). The label link + cwd fallback
  cover it; an explicit registry was considered and rejected — it
  replicates state herdr's tab labels already persist across restarts,
  at the cost of a stale-entry lifecycle.
- No change to herd.nvim's keybind defaults — `keys.toggle`/`send`/`hide`
  (`<leader>s`) and `keys.select` (`<leader>S`) stay as they are; only the
  herdr side gains a binding.
- No literal "re-dispatch herdr's default action" fallback for
  `prefix+s` — impossible via CLI (verified above); see "Fallback
  semantics".
- No change to the spawn dance (`tab create --label` → `agent start --tab`
  → close spare pane). A hypothetical `agent start --workspace` one-shot is
  rejected: the custom tab label *is* the origin link.

## Keybinds

herd.nvim's key defaults are **unchanged** (`<leader>s`
toggle/send/hide, `<leader>S` picker, `keys.dashboard` unmapped —
in native mode the dashboard becomes the global agent picker, see below).

The only new binding is herdr-side (user's `~/.config/herdr/config.toml`,
documented in the README — herd.nvim cannot configure it):

```toml
[[keys.command]]
key = "prefix+s"
type = "shell"
command = "nvim -l <plugin-path>/bin/herd-return.lua"
```

`prefix+s` **deliberately overrides herdr's default `settings` binding**.
The custom command shadows it on every tab; the settings screen stays
reachable only if the user rebinds `settings` to another chord (user
decision at implementation time — noted in Open items).

## `herd return` — the back leg

### Shipping shape

- `lua/herd/origin.lua` — **pure resolution module**: takes the already
  parsed `tab list` / `pane list` / `agent list` tables, returns the target
  tab_id (or nil + reason). All matching logic lives here; unit-tested in
  plenary with fixture tables.
- `bin/herd-return.lua` — thin executable wrapper for `nvim -l`: resolves
  the plugin root from `arg[0]` and prepends it to `package.path`, shells
  the three list commands via `vim.system`, calls `origin.resolve(...)`,
  then runs `herdr tab focus <id>` or `herdr notification show ...`.

`nvim -l` keeps the script dependency-free (no jq/python); nvim ≥ 0.10 is
already a plugin requirement, and ~50 ms of startup is fine for a keypress.

### Resolution order (stateless, all live queries)

1. Focused tab from `herdr tab list` (`focused:true`; exactly one).
2. **Label link**: split the focused tab's label at the **last** colon
   (agent names — `next_name()` output — never contain colons; editor
   labels may). If a prefix exists, focus the tab **in the same workspace**
   whose label equals it: `dotfiles:claude_2` → `dotfiles`. First match
   wins on duplicate labels.
3. **cwd fallback** (label renamed, or an agent herd didn't spawn): if the
   focused pane is an agent (present in `agent list`), find a non-agent
   pane in the same workspace whose `cwd` equals the agent's spawn `cwd`
   (the same key herd uses forward) and focus its tab. Match on the pane's
   `cwd` field (spawn cwd — static), not `foreground_cwd`.
4. Nothing matches, or the focused pane is not an agent at all →
   `herdr notification show "herd: no origin editor here"` and exit 0.

### Fallback semantics (the "herdr default" wish)

The requested behavior — "agent unrelated to any editor → fall back to
herdr's default" — cannot be implemented literally: herdr exposes no CLI
to trigger a keybind action, so the script cannot open the shadowed
`settings` screen (or any other default) when resolution fails. Closest
faithful behavior, adopted here: **notify + no-op** (step 4). The user
rebinds `settings` to another chord if they want it back on a key (see
"Keybinds").

### Error handling

- herdr server down / CLI error → exit silently (a notification is
  impossible then too).
- Non-herd tab focused → step 4's notification (the cwd fallback still
  rescues manually-created agent tabs whose cwd matches an editor).

## Global agent picker — the cross-project forth leg

In **native mode**, `M.dashboard()` (and thus `:Herd dashboard` /
`keys.dashboard`) becomes a global picker instead of focusing the unused
dedicated workspace:

- Rows: every agent from `herdr agent list` (nameless detected agents
  skipped, as everywhere), formatted
  `"<tab-label>  [<status>]  · <workspace-label>"` — workspace labels
  resolved once via `herdr workspace list`, tab labels via the agent's
  `tab_id` against `herdr tab list` (one call each, not per row).
- Selection → the existing `show(agent)` (native: focus; herdr flips the
  workspace when the agent lives elsewhere).
- No spawn rows — spawning is project-scoped and stays in `keys.select`.
- Float mode's `M.dashboard()` is unchanged (focus the dedicated
  workspace).

Implementation reuses `picker.lua`'s `vim.ui.select` plumbing with a
global variant (running agents only, cross-cwd, richer labels).

## Agent-first CLI alignment

`show()` and `M.toggle()`'s native branch switch from
`Herdr.focus_tab(a.tab_id)` to `Herdr.agent_focus(a.pane_id)` (`herdr
agent focus <pane_id>`) — herd speaks herdr's agent abstraction, and
`pane_id` is always present. **Verify behavioral equivalence at
implementation** (must switch the visible tab and flip workspace exactly
like `tab focus`); if it differs, keep `tab focus` and drop this item.
`tab_id` threading through `agents()` stays either way (reaper's
`keep_tab` and the global picker's labels use it).

## Experiment: editor in the agents panel (opt-in)

New config: `experimental = { editor_agent = false }` (default off,
documented as experimental/unstable).

When `true` and mode is native, `setup()` registers nvim's own pane as a
reported agent so it appears in herdr's agents panel alongside the agents
it spawns:

```
herdr pane report-agent $HERDR_PANE_ID --source herd.nvim \
  --agent <project> --state idle
```

(`<project>` = nvim's tab label, same derivation as the spawn prefix.)
Released via `herdr pane release-agent` on a `VimLeavePre` autocmd.

Effect: `next_agent` / `previous_agent` / `focus_agent` cycle through
editors *and* agents — herdr's own panel becomes a both-way navigation
hub (`agent_panel_sort = "spaces"` groups rows by workspace).

Risks, to verify at implementation:

- Herd's own `agents()` must not see the editor row as a real agent.
  Expected: reported agents carry a label but no `name`, so the existing
  nameless-skip already filters them; if not, add a `source == 'herd.nvim'`
  filter.
- Crash cleanup: a dead nvim may leave its row until herdr prunes it —
  acceptable for an experiment; check whether report-agent rows expire.
- Panel/notification noise (sounds, toasts) from a permanently-idle editor
  row.

If the experiment misbehaves, the flag flips off and no other feature in
this spec depends on it.

**Outcome (2026-07-03, live trial):** worked mechanically (row appeared,
panel cycling included the editor, release on quit was clean, no discovery
pollution) but was rejected on UX grounds — the agents panel should contain
only agents; with several editor instances it becomes a mess. The feature
was removed entirely (see `.claude/knowledges/herdr-reported-agent-rows.md`
for the herdr facts it established and where the code lives in history).

## Configuration (proposed shape)

```lua
require('herd').setup({
  mode = 'float', -- unchanged default

  -- keys.* unchanged; keys.dashboard now opens the global agent picker
  -- in native mode (float mode: focuses the dedicated workspace, as before).

  experimental = {
    editor_agent = false, -- native only: report nvim into herdr's agents panel
  },
})
```

## Testing / verification

- Plenary specs:
  - `origin_spec.lua` — resolution matrix over fixture tables: label hit,
    label with colons in the editor label, renamed label → cwd fallback,
    non-agent focused tab, duplicate editor labels, no match.
  - `picker_spec.lua` — global variant rows/format and selection dispatch.
  - `init_spec.lua` — dashboard dispatch per mode; `editor_agent`
    report/release calls (stubbed `Herdr.api`).
  - `config_spec.lua` — `experimental` table default (existing key
    defaults unchanged).
- Manual acceptance (real herdr server, the actual pain scenario):
  1. Two editors in one workspace (e.g. `gogo-code`, `gogo-code-lua`),
     spawn an agent from each; wander to the other project's agent via
     sidebar/`next_agent`; `prefix+s` lands on the *correct* editor tab.
  2. Rename an agent's tab label, `prefix+s` still returns via cwd
     fallback.
  3. `prefix+s` on a non-agent tab → notification, no-op.
  4. From `dotfiles` nvim, global picker → jump to an agent in another
     workspace; herdr flips workspace.
  5. `experimental.editor_agent = true` → editor row appears in the panel,
     `next_agent` cycles editor ↔ agent, row disappears on `:q`, and
     `<leader>s` picker does *not* list the editor as an agent.

## Addendum: Snacks picker integration (post-acceptance follow-up)

User feedback during acceptance: the `vim.ui.select`-rendered pickers are
tiny, and rows alone don't tell you what an agent is doing. Decision
(defaults chosen per user's setup — snacks.nvim is their `vim.ui.select`
provider anyway):

- **Both pickers** (project `<leader>S` and the global dashboard) render
  through `Snacks.picker.pick` when snacks.nvim is available, falling back
  to `vim.ui.select` unchanged when it is not. No new config option —
  detection via `pcall(require, 'snacks.picker')`.
- **Preview pane = metadata header + live agent output**: agent rows show
  name/status/cwd/workspace-tab header, a separator, then the agent's
  recent terminal output via a new `Herdr.agent_read(pane_id, lines)`
  (`herdr agent read <pane> --lines 40 --format text`, quiet). Spawn rows
  (`+ tool`) preview the tool's argv and env.
- Glue lives in a new `lua/herd/snackspicker.lua`; `picker.lua` keeps the
  pure item builders (which gain `ws`/`tab_label` fields on global items
  for the header) and dispatches through one internal chooser. Confirm
  path mirrors snacks' own ui_select provider: close picker, then
  `vim.schedule` the `on_choice` callback.
- Size comes free: `Snacks.picker.pick` uses the full default layout with
  a preview split, unlike the compact `ui_select` layout.

## Open items (resolve during implementation; not blockers)

- Confirm `herdr agent focus <pane_id>` is behaviorally identical to
  `tab focus` for visible-tab switching (else keep `tab focus`).
- Confirm `[[keys.command]]` `type = "shell"` runs detached with the
  server reachable (expected; it's the documented detached variant).
- Confirm reported-agent rows are name-less in `agent list` (else add the
  `source` filter).
- Decide whether to rebind herdr's `settings` action (displaced from
  `prefix+s` by the herd-return command) to another chord (herdr config,
  user-side).
