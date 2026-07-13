# Editor↔Agent Context Bridge — design (WHAT/WHY)

## Problem

herd.nvim today is a launcher with a one-directional send. Visual `<leader>\`
pushes the **raw** selection text (`init.lua:159 M.send`), and the return
direction — from the agent back into the editor — barely exists. The agent
pane cannot see buffer paths, line numbers, LSP diagnostics, or where the user
is looking; the editor cannot see the files the agent just wrote or referenced.

This is precisely the seam only the editor can own: passing editor context to
the agent, and landing agent output back in the editor. It is the one thing the
stack does that a pure terminal/multiplexer (e.g. agterm) structurally cannot.

## Goals

Make the editor↔agent seam **bidirectional and context-aware**, in five
independent, individually-shippable increments:

1. **Location-aware selection send** — the existing visual send wraps the
   selection as a fenced block prefixed with `path:startline-endline`, so the
   agent knows *where* the code lives without the user pasting a path.
2. **Auto-reload edited buffers on return** — when focus leaves an agent float
   back to the editor, run `checktime` so buffers the agent wrote refresh
   instead of going stale / prompting mid-edit.
3. **Agent → editor jump** — read the agent's recent output, extract
   `path:line` references, populate the quickfix list, and jump to the first.
4. **Send diagnostics** — push the current buffer's LSP diagnostics to the
   agent as text ("here are my errors, fix them").
5. **Linked-agent state in the statusline** — expose this project's agent
   status (working / blocked / idle) as a cached value the user renders in
   their statusline/winbar, so they know when to flip over without leaving nvim.
6. **Resurrect the editor host on return** — the user's normal flow is to *quit
   nvim to the shell* (the herdr pane and its tab persist as an idle shell)
   while the agent keeps running. The `Ctrl-a \` return gesture detects whether
   nvim is actually *live* in the origin tab and, when it isn't, prompts to
   restart nvim **in that same pane** rather than silently focusing a dead
   shell tab. Single key, liveness-detected, native mode only, opt-in.

## Non-goals

- No agent that *controls* the editor or drives herdr layout — that belongs in
  a herdr-side integration, not this editor plugin (explicit user decision).
  (#6 is the *user's* return gesture launching the host, not the agent driving
  anything — a different thing.)
- No session-state restoration inside herd — #6 launches `nvim` in the right
  cwd; whether it reloads the project's session is the user's nvim-config job
  (VimEnter / resession autoload). herd provides the launch seam, not the state.
- No new multiplexer choreography; window/pane management stays herdr's job.
- No change to the spawn / picker / dashboard / native-vs-float model.

## Design

### Shared principles
- **Backward compatible.** Every feature is gated by a new config key with a
  sensible default; existing keymaps and behavior are unchanged unless opted in.
- **Editor-only context.** Each feature derives from state only nvim holds
  (buffer path, line range, filetype, `vim.diagnostic`, agent output parsing).
- **Reuse the existing seam.** Sends go through `Herdr.agent_send(pane_id, …)`
  targeting `Target.current`; reads add one thin `Herdr.agent_read` wrapper.
- **Testable.** Pure formatting/parsing lives in small functions unit-tested
  against the existing busted `_spec.lua` + `minimal_init.lua` harness, with the
  `Herdr.*` CLI calls stubbed as the current tests already do.

### 1. Location-aware selection send
`selection()` (`init.lua:146`) currently discards the line range. Refactor it to
also return `{ text, sline, eline }` (from `getpos('v')`/`getpos('.')`).
`M.send` builds a context header from `fnamemodify(bufname, ':.')` (path
relative to cwd), the line range, and `vim.bo.filetype` for the fence:

```
src/herd.lua:120-135:
```lua
<selection>
```
```

- Config: `send.context` — `true` (default), `false`, or a `function(ctx) ->
  string` formatter for full control. `ctx = { path, sline, eline, ft, text }`.
- When `false`, behavior is byte-identical to today (raw text).

### 2. Auto-reload on return
Add a `checktime` on leaving a herd float. The `herd_mouse` augroup already has
a `BufLeave` autocmd keyed on `Terminal.is_float_buf` (`init.lua:268`); mirror
that guard in a new autocmd (or extend it) to `vim.schedule(function()
vim.cmd('checktime') end)`. Also fire on `FocusGained` (agent may edit while
nvim is unfocused). Respects `'autoread'` — silent reload when set, prompt when
not, which is still strictly better than a silently stale buffer.
- Config: `reload` — `true` (default) / `false`.

### 3. Agent → editor jump
New `Herdr.agent_read(target, { source = 'recent', lines = N })` wrapping
`herdr agent read <target> --source recent --lines N --format text`. New
`M.goto()`:
- read the current target's recent output,
- scan for `path:line(:col)?` tokens, resolve each relative to the agent's cwd,
  keep only those that `stat` to a real file (drops prose false-positives),
  dedup,
- set the quickfix list and `:cfirst`; notify if none found.
- Exposed as `:Herd goto` + `require('herd').goto()`. **No default keymap** —
  user opts in (avoids claiming a key).

### 4. Send diagnostics
New `M.diagnostics()`: format `vim.diagnostic.get(0)` as one block —
`path:line:col [SEVERITY] message (source)` per entry, with a file header —
then the same `agent_send` + `show` path as `M.send`. Empty → notify, no send.
- Exposed as `:Herd diagnostics` + API. **No default keymap** — user opts in.

### 6. Resurrect the editor host on return (native mode)
Key correction over the naive design: quitting nvim in native mode leaves the
herdr **pane and tab alive as an idle shell** — so `Origin.resolve`
(`origin.lua:36`) *does* find the origin tab via its `<project>` label link, and
today's `herd-return.lua:50` `tab focus` succeeds but drops the user onto a
**dead (nvim-less) shell tab**. The right signal is therefore **nvim liveness in
the resolved tab**, not tab existence.

- Keep `Origin.resolve` returning the origin tab. Add liveness detection:
  `herd-return.lua` calls `herdr pane process-info` (or `pane get`) on the
  resolved tab's pane(s) and asks "is any foreground process `nvim`?". Add a
  pure helper in `origin.lua` (`Origin.editor_pane(tabs, panes, tab_id)` →
  the pane id to target) so pane selection stays unit-testable.
- **nvim live** → `tab focus`, silent. Unchanged fast path — no prompt when the
  editor is still there.
- **nvim not live** → focus the tab, then `herdr pane run <pane_id>
  "<resurrect-prompt>"` to inject an **interactive** prompt into that live shell
  pane: `herd: no nvim here — resurrect? [Y/n]`; `y` → `exec ${HERD_EDITOR:-nvim}`
  (user's resession autoload restores state), `n` → left at the shell. Reuses
  the existing pane — no new tab — so the label link is untouched.
- **Interactivity without a UI:** `herd-return.lua` stays headless (`nvim -l`) —
  it only decides live-vs-dead and issues CLI calls. The prompt runs in the
  destination shell via `pane run`, so no interactive surface is needed in the
  return script itself. Ship the prompt as `bin/herd-resurrect.sh` for sane
  quoting; `HERD_EDITOR` overrides the launched command (session-restore seam).
- **Gating is a script arg, not `setup()` config:** the headless script never
  loads `require('herd').setup()`. Without `--resurrect` behavior is unchanged
  (focus the tab, live or dead). The user adds `--resurrect` to their herdr
  `config.toml` `[[keys.command]]` binding to enable the liveness prompt.
- **Native mode only:** float mode has no herdr pane for the host; `herd-return`
  is already native-only. Out of scope for float.

### 5. Linked-agent state in the statusline
Calling the herdr CLI on every statusline redraw is far too expensive (a
`vim.system` spawn per redraw). Introduce a cache refreshed on a `vim.uv` timer
(interval configurable, default ~2s) plus on `BufEnter`/`FocusGained`.
`require('herd').status()` returns `{ name, status } | nil` for the current
cwd's agent (from `Herdr.agents(cwd)[…].status`); `require('herd').statusline()`
returns a short formatted string with an icon. The poller only starts when
opted in.
- Config: `status_poll` — `false` (default) / `true`, `status_interval_ms`.
- Heaviest, most optional; ship last.

## Risks / tradeoffs
- **#1 default-on** changes what the agent receives for existing users. Mitigated
  by the `context = false` escape hatch and by it being obviously-better for the
  code-send case herd.nvim is built around.
- **#2** on a misconfigured `'noautoread'` setup surfaces the reload prompt; this
  is standard nvim behavior, not a regression.
- **#3** path parsing is heuristic; the `stat`-must-exist filter is the guard
  against garbage quickfix entries.
- **#5** adds a background timer + periodic CLI spawn; strictly opt-in for that
  reason, and cheap (one `agent list` every couple seconds only while enabled).
- **#6** prompts (never auto-spawns) on a keypress; opt-in via `--resurrect`,
  native-only. It only prompts when nvim is confirmed dead in the resolved tab,
  and reuses the existing pane — worst case if `HERD_EDITOR` is wrong: a failed
  command echoed at a shell you were already headed to. No data loss, no new
  tabs, label link preserved.

## Success criteria
Each feature: unit tests green for its pure logic, `:checkhealth herd` still
clean, and a manual end-to-end check (send with context lands a fenced block in
the agent; edit-from-agent then return reloads the buffer; `:Herd goto` opens a
referenced file; `:Herd diagnostics` delivers errors; `status()` reflects a
blocked agent).
