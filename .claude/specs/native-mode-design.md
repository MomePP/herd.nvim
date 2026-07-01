# herd.nvim — native mode (herdr-native display, no nvim window)

## Premise

herd.nvim currently has exactly one display backend: a floating nvim
`:terminal` that attaches to the agent's PTY (`herdr agent attach <pane>`).
This works everywhere (nvim doesn't need to run inside a herdr pane at all)
but has one structural cost: because the agent's mouse events are forwarded
through nvim's terminal-buffer mouse handling, you can't get plain
click-drag-to-copy without giving up wheel-scroll (`win.mouse`), and every
spawned agent lives in a dedicated hidden `herd.nvim` herdr workspace so it
never visually intrudes on the user's real project workspaces — which also
means herdr's own status/notification indicators for that agent show up
against the hidden `herd.nvim` workspace, not the project the agent is
actually working on.

**Native mode** adds a second display backend for users who always run nvim
*inside* a herdr pane: instead of showing the agent through an nvim window at
all, the agent is spawned as a **sibling herdr tab in nvim's own workspace**,
and "toggling" to it means asking herdr to switch its visible tab — a pure
herdr-side operation. nvim never attaches to the agent's PTY, so there is no
window, no float, no terminal-buffer mouse forwarding, and no `win.mouse`
trade-off: scrolling and click-drag-select are just native Ghostty-over-herdr
behavior. And because the agent's tab lives in the *real* project workspace,
herdr's own status/notification indicators attribute it there instead of to
the hidden workspace.

Float mode remains the default and is unaffected. Native mode is opt-in via
one config field and requires nvim to run inside a herdr pane.

## Goals

- `mode = 'native'` config option; default stays `mode = 'float'`
  (fully backward compatible — no behavior change for existing users).
- Agent spawned in native mode lands as its own tab in **nvim's own herdr
  workspace** (read from `$HERDR_WORKSPACE_ID`), not the hidden `herd.nvim`
  workspace — so herdr's status hooks/notifications attribute it to the real
  project.
- The agent's tab is a **fullscreen single pane**, not a split — same
  guarantee float mode already gives via the spare-pane-close trick.
- Existing keybinds/UX (`<leader>s` toggle incl. `<count>` slots, `<leader>S`
  picker, visual send) work unchanged from the user's side; only the
  *display* mechanism swaps per mode.
- Dead agent tabs (process exited) get cleaned up without requiring a
  background poller.

## Non-goals

- No nvim-side window of any kind for the agent in native mode (no float, no
  tabpage) — this was explicitly decided against in favor of the herdr-native
  model (see "Rejected alternative" below).
- No change to float mode's behavior, module layout, or config shape.
- No herd.nvim-side keybind for the "return to nvim" leg of the round trip —
  that is herdr's own tab/pane navigation, out of the plugin's control
  (see "Return-trip UX").
- No immediate-on-exit tab cleanup for native mode (no free exit signal
  exists for it — see "Cleanup").

## Rejected alternative: nvim tabpage display

An earlier iteration of this design considered a *third* display backend:
drop the float, but keep nvim as the host by opening the agent in a real nvim
**tabpage** (`:tabnew` + `termopen(herdr agent attach ...)`), with a
`{ tabpage, origin_tabpage }` registry driving a round-trip toggle.

This was dropped for two reasons, confirmed during design:

1. **It doesn't solve the motivating problem.** nvim's terminal-buffer mouse
   forwarding (`win.mouse`) behaves identically whether the buffer sits in a
   floating window or a plain tabpage window — the click-drag-vs-scroll
   trade-off is unrelated to which nvim window container is used.
2. **"Hidden, keybind-only" and "ambient tabpage" are contradictory.** nvim
   has no concept of a tabpage that's excluded from the tabline/`gt`
   cycling — every tabpage is a visible peer. The one thing that *does* give
   "a full nvim surface, hidden until explicitly summoned, round-trips for
   free" is a fullscreen float, which herd.nvim already has.

The user's actual intent (confirmed in discussion) was the herdr-tab model
described above, not an nvim tabpage — "native" meaning "herdr's own native
tab switching," not "nvim's native tab feature."

## Architecture

```
          nvim (runs *inside* a herdr pane; $HERDR_WORKSPACE_ID / $HERDR_TAB_ID)
            │
   <leader>s (normal)
            │
            ▼
   Herdr.focus_tab(agent.tab_id)  ──▶  herdr tab focus <tab_id>
                                              │
                                              ▼
                                   herdr switches its visible tab,
                                   in the SAME workspace nvim's own
                                   pane lives in — no window/app
                                   switch, no nvim involvement in
                                   what's rendered from here on.

   Return trip: herdr's own tab/pane navigation (e.g. last_pane,
   previous_tab/next_tab) — not mediated by herd.nvim at all, since
   nvim isn't focused/receiving input while another tab is active.
```

Native-mode agents are spawned into `$HERDR_WORKSPACE_ID` (nvim's own
workspace, read once from env) rather than the dedicated hidden `herd.nvim`
workspace float mode uses. Discovery, target resolution (cwd/slot addressing)
and the picker are unchanged — they already operate purely on
`herdr agent list` and don't know or care how an agent is displayed.

### Startup guard

At `setup()`, if `mode == 'native'` and `vim.env.HERDR_TAB_ID` is unset (nvim
is not running inside a herdr pane), `vim.notify` a `WARN` ("herd: native
mode requires nvim to run inside a herdr pane — falling back to float") and
treat the session as `mode = 'float'` — same warn-and-degrade style as the
existing `ensure_server()` check, not a hard error.

### `herdr.lua` additions (no new files)

- `M.focus_tab(tab_id)` — `herdr tab focus <tab_id>`. One-liner, same shape as
  the existing `M.focus_workspace(id)`.
- `M.spawn_native(name, cwd, def)` — mirrors `M.spawn`, simplified:
  1. `tab create --workspace $HERDR_WORKSPACE_ID --cwd <cwd> --label <name>
     --no-focus` (workspace is nvim's own — deterministic, not "whatever is
     currently focused").
  2. `agent start <name> --cwd <cwd> --tab <tab_id> --no-focus -- <argv>`
     (plus `--env` pairs, same as `M.spawn`).
  3. Close the spare pane the tab was created with, using
     `root_pane.pane_id` from step 1's response directly — confirmed via a
     live probe that `tab create` already returns this, so unlike `M.spawn`,
     no follow-up `pane list --workspace` round trip is needed.
  4. No `tab_label`/project-tagging parameter — redundant, since the tab
     already lives in the real project workspace.
- `M.agents()` gains a `tab_id` field on each returned `herd.Agent` (already
  present in the raw `agent list` JSON, currently dropped).
- `M.prune_workspace(ws_id, keep_tab)` is reused as-is for native mode's
  lazy reap, called with `$HERDR_WORKSPACE_ID` instead of the hidden
  workspace id.

### `init.lua` wiring

Every call site that currently means "show this agent" dispatches on
`Config.get().mode`:

- `show(a)` (used by spawn, picker-select, and `M.send`'s "land in the agent
  to submit"): float → `Terminal.open(...)` (unchanged); native →
  `Herdr.focus_tab(a.tab_id)`.
- `M.toggle()`: float → unchanged (`Terminal.toggle`, which hides if the
  float is open); native → same dispatch as `show()`. There is no separate
  "hide" branch to pick in native mode — see "Why toggle is one-directional
  in native mode" below.
- `M.spawn()`: float → `Herdr.spawn` (unchanged); native → `Herdr.spawn_native`.
  Both paths still call `Herdr.prune_workspace`, scoped to the relevant
  workspace id per mode.

Gated on `mode == 'float'` (skipped entirely in native mode, since there is
never a herd-owned nvim terminal buffer for them to attach to):

- The `TermOpen`-based registration of `keys.hide` / `keys.newline`
  buffer-local terminal-mode keymaps.
- The `win.mouse` mouse-passthrough `BufEnter`/`BufLeave` autocmd pair.

### Why toggle is one-directional in native mode

In float mode, `<leader>s` can mean either "show" or "hide" depending on
whether the float is currently open, because nvim keeps running (and
receiving that keypress) regardless of what's drawn on screen.

In native mode this is structurally different: once herdr's visible tab is
the agent's tab, **nvim is not the focused pane** and is not receiving
keystrokes at all — the CLI tool in the agent's tab is. This means
`M.toggle()`'s nvim-side keybind can only ever fire while nvim already has
input focus (i.e. herdr is already showing nvim's tab). So there is no
"currently open, hide it" case to handle from nvim's side — the action is
always "focus the target agent's tab." This was confirmed as a hard
consequence of the herdr-native model, not a simplification of scope.

### Return-trip UX (out of herd.nvim's control)

Getting back to nvim after `<leader>s` switches herdr to an agent's tab is
ordinary herdr tab/pane navigation — not something herd.nvim can bind or
mediate, since nvim isn't focused to receive a keypress at that point. The
user's own `~/.config/herdr/config.toml` already has:

```toml
last_pane = "prefix+;"   # tmux last-pane | default: "" (unset)
# "herd.nvim return trip: Ctrl-a ; jumps back to the last (nvim) pane"
```

Verified empirically during design (via the herdr CLI, restoring state
afterward): `herdr tab focus <id>` **is** a real state change — it updates
`active_tab_id` and, if the target tab is in a different workspace than the
one currently shown, also flips the globally-focused workspace. Since native
mode always spawns into nvim's own already-focused workspace, this "flip
workspace" case doesn't arise for the nvim↔agent round trip.

**Not verified** (no CLI primitive exists to trigger a keybind action
directly, only to query/change state): whether herdr's `last_pane` tracker
treats an API-driven `tab focus` (what herd.nvim issues) the same as an
interactive keypress. This must be checked empirically once native mode is
implemented: spawn an agent, `<leader>s` to it, then press `Ctrl-a ;` in the
live session and confirm it lands back on nvim's tab.

**Documentation task**: the native-mode README section should document
`last_pane` (`Ctrl-a ;`) as the recommended return gesture, with
`previous_tab`/`next_tab` (bound to both `prefix+ctrl+h`/`prefix+ctrl+l` and
`prefix+left`/`prefix+right` in the reference config) as the fallback if
`last_pane` turns out not to pick up API-driven focus changes.
`next_agent`/`previous_agent` (`prefix+down`/`prefix+up`) are also worth a
mention as a complementary way to reach a specific agent directly via
herdr's own agents sidebar, independent of the round trip.

### Cleanup

Float mode gets tab/pane cleanup for free: nvim's `termopen(herdr agent
attach ...)` job naturally exits when the agent's process does, and that
`on_exit` callback already closes the float. Native mode has **no such local
signal** — nvim never attaches to the agent's PTY, so there is nothing to
hook an exit callback into. `herdr wait`'s subcommands (`wait output`,
`wait agent-status`) were checked and do not cover "notify when this pane is
gone" either.

Decision: native mode reuses the existing **lazy reap-on-next-spawn** pattern
(`prune_workspace`), scoped to `$HERDR_WORKSPACE_ID` instead of the hidden
workspace. This avoids adding a background poller/timer for a "tiny plugin,"
at the cost of an exited agent's tab sitting empty in the user's live project
workspace until the next spawn there reaps it (same trade-off float mode
already accepts for its hidden workspace, just now more visible).

## Configuration (proposed addition)

```lua
require('herd').setup({
  mode = 'float', -- 'float' (default, unchanged) | 'native' (herdr-tab display,
                   -- requires nvim to run inside a herdr pane)

  -- win.* and keys.hide/keys.newline apply to mode = 'float' only.
})
```

## Data flow (native mode)

- **Spawn**: keymap → `M.spawn(tool)` → `Herdr.spawn_native` (tab create in
  `$HERDR_WORKSPACE_ID` → agent start --tab → close spare pane) →
  `Herdr.prune_workspace($HERDR_WORKSPACE_ID, new_tab)` → `show(agent)` →
  `Herdr.focus_tab(agent.tab_id)`.
- **Toggle**: keymap → resolve cwd/slot target (unchanged `Target` logic) →
  `Herdr.focus_tab(a.tab_id)`.
- **Send**: visual keymap → capture selection → `Herdr.agent_send(pane_id,
  text)` → `Herdr.focus_tab(a.tab_id)` ("land in the agent to submit").
- **Pick**: `<leader>S` → picker (unchanged, reads `herdr agent list`) →
  select → `show(agent)` dispatches per mode.
- **Return**: herdr-native tab/pane navigation, outside herd.nvim.

## Error handling

- `mode = 'native'` without `$HERDR_TAB_ID` → warn once at `setup()`, fall
  back to float for the session (see "Startup guard").
- All other error paths (no herdr server, unknown tool, spawn failure) are
  unchanged from float mode — `ensure_server()` and `Herdr.run`'s existing
  error surfacing apply identically.

## Testing / verification

- Mirror the existing test structure: `herdr_spec.lua` gains cases for
  `spawn_native` (tab create → agent start --tab → spare-pane close using the
  tab-create response's pane id, no `pane list` call) and `focus_tab`;
  `init_spec.lua` gains cases for mode dispatch in `show`/`M.toggle`/`M.spawn`
  and the startup-guard fallback.
- Manual acceptance against a real herdr server (nvim running inside a herdr
  pane):
  1. `mode = 'native'`, spawn a tool → new tab appears in nvim's own
     workspace (not `herd.nvim`), fullscreen (single pane), herdr sidebar
     shows it under the real project.
  2. `<leader>s` → herdr switches to the agent's tab; nvim's own pane is no
     longer receiving input.
  3. `Ctrl-a ;` (or documented fallback) → back on nvim's tab.
  4. `<count><leader>s` → targets the correct slot's tab.
  5. Visual `<leader>s` → text delivered, herdr switches to the agent's tab.
  6. Exit the agent process → its tab sits empty; spawning a second agent in
     the same project reaps it.
  7. `mode = 'native'` with nvim run standalone (no `$HERDR_TAB_ID`) → warn
     shown, behaves as float mode.
- `:checkhealth herd` unaffected (binary/server/tools checks are
  mode-independent).

## Open items (resolve during implementation; not blockers)

- Confirm whether `last_pane` picks up API-driven `tab focus` (see
  "Return-trip UX") and adjust the README's recommended keybind accordingly.
- Confirm `tab create`'s spare-pane-close-via-response-pane-id approach
  (used only by the new `spawn_native`) before considering porting the same
  simplification back into the existing float-mode `M.spawn` — that would be
  an unrelated cleanup, out of scope for this feature.
