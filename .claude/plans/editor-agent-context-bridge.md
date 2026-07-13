# Editor↔Agent Context Bridge — implementation plan (HOW)

Spec: `.claude/specs/editor-agent-context-bridge.md`. Five independent
increments, ordered risk-ascending so each phase ships on its own. Test harness:
busted `tests/*_spec.lua` with `tests/minimal_init.lua`; `Herdr.*` CLI calls are
stubbed as in `tests/herdr_spec.lua`/`tests/init_spec.lua`.

---

## Phase 1 — Auto-reload on return (#2)  ·  smallest, near-zero risk

1. In `M.setup` (`init.lua`), add an autocmd (reuse/extend the `herd_mouse`
   augroup pattern, `init.lua:254`) on `BufLeave` guarded by
   `Terminal.is_float_buf(ev.buf)`, and on `FocusGained`, that calls
   `vim.schedule(function() vim.cmd('checktime') end)`.
   → verify: edit a file from the agent, `<leader>\` back, buffer shows new
   content (`:e!` no longer needed); manual.
2. Gate on `Config.get().reload ~= false`; add `reload = true` default in
   `config.lua`.
   → verify: `reload = false` → autocmd not registered; `config_spec` assertion.
3. Test: `init_spec` — stub `vim.cmd`, assert `checktime` fired on float
   `BufLeave` and skipped when `reload = false`.
   → verify: `busted` green.

## Phase 2 — Location-aware selection send (#1)  ·  high value

1. Refactor `selection()` (`init.lua:146`) → returns `{ text, sline, eline }`
   (line numbers from `getpos('v')`/`getpos('.')`); keep the mode-detection.
   → verify: unit test the return shape for charwise/linewise/blockwise.
2. Add `format_context(ctx)` pure helper building the `path:sline-eline` +
   fenced (`vim.bo.filetype`) block; `path = fnamemodify(bufname, ':.')`.
   → verify: `init_spec` snapshot of the produced string.
3. Wire `M.send` to wrap via `Config.get().send.context`: `true` → default
   formatter, `function` → user formatter, `false` → raw `text` (today's path).
   Send the wrapped string through the existing `Herdr.agent_send(a.pane_id,…)`.
   → verify: stub `agent_send`, assert payload wrapped (default) and raw (false).
4. Add `send = { context = true }` default to `config.lua` (back-compat: a bare
   `send` string keymap must still work — keep keymap under `keys.send`, put the
   new option under a separate `send` table or `keys.send_context`; pick the
   non-colliding shape and document it).
   → verify: `config_spec` back-compat assertions.

## Phase 3 — Send diagnostics (#4)  ·  parallel to send

1. Add `M.diagnostics()`: `vim.diagnostic.get(0)` → `format_diagnostics()` pure
   helper (`path:line:col [SEVERITY] message (source)`, file header) → reuse the
   `Target.current` + `agent_send` + `show` flow from `M.send`.
   → verify: stub `vim.diagnostic.get` + `agent_send`; assert formatted payload;
   empty list → notify, no send.
2. Expose `:Herd diagnostics` (extend the dispatch table `init.lua:280`) +
   `require('herd').diagnostics()`. No default keymap.
   → verify: `:Herd diagnostics` dispatches; completion lists it.

## Phase 4 — Agent → editor jump (#3)  ·  adds a read + parser

1. Add `Herdr.agent_read(target, opts)` wrapping `herdr agent read <target>
   --source recent --lines N --format text`; return stdout or nil.
   → verify: `herdr_spec` — stub `M.run`, assert argv.
2. Add `parse_refs(text, cwd)` pure helper: match `([%w./_%-]+):(%d+)(:%d+)?`,
   resolve rel to `cwd`, keep only `vim.uv.fs_stat`-existing files, dedup,
   return quickfix items `{ filename, lnum, col }`.
   → verify: unit test — real refs kept, prose (`foo:bar`, nonexistent) dropped,
   dedup works.
3. Add `M.goto()`: read current target's output, `parse_refs`, `setqflist` +
   `:cfirst`; notify if empty. Expose `:Herd goto` + API. No default keymap.
   → verify: stub `agent_read` returning fixture output; assert qflist contents
   and `cfirst`; empty → notify.

## Phase 5 — Linked-agent state in statusline (#5)  ·  heaviest, opt-in

1. Add a cache module: `vim.uv` timer (interval `status_interval_ms`, default
   2000) + `BufEnter`/`FocusGained` refresh, storing `Herdr.agents(cwd)` status
   for the current cwd. Timer starts only when `Config.get().status_poll`.
   → verify: stub the clock/timer; assert refresh updates cache, and no timer
   when `status_poll = false`.
2. Add `M.status()` → `{ name, status } | nil`, and `M.statusline()` → short
   iconed string.
   → verify: unit test both against a seeded cache.
3. Config defaults + README: `status_poll = false`, `status_interval_ms = 2000`.
   Document a lualine/statusline snippet.
   → verify: `config_spec`; `:checkhealth herd` clean.

## Phase 6 — Resurrect the editor host on return (#6)  ·  native mode, opt-in

Touches `origin.lua` + `bin/herd-return.lua` + new `bin/herd-resurrect.sh` (not
the `init.lua` seam). Model: the origin tab persists as an idle shell after nvim
quits, so `Origin.resolve` still finds it — the signal is **nvim liveness in the
resolved tab**, and on death we prompt to resurrect in that same pane.

0. Verify the herdr contract first: `herdr pane process-info` / `pane get`
   output shape — confirm it exposes the pane's foreground process so nvim can
   be detected. (One `herdr` call against a live nvim pane vs a shell pane.)
   → verify: know the field before coding the detector.
1. Add pure `Origin.editor_pane(tabs, panes, tab_id)` → pane id to target in the
   resolved origin tab (the non-agent pane, cwd-preferred). Keep `resolve`
   unchanged.
   → verify: `origin_spec` — picks the shell pane in the origin tab; existing
   `resolve` tests untouched.
2. In `herd-return.lua`: parse `--resurrect`. After `resolve` returns a tab,
   check liveness via `pane process-info` on `editor_pane`'s pane(s):
   - nvim live → `tab focus <tab_id>` (today's silent path, live or dead when
     `--resurrect` absent).
   - nvim dead **and** `--resurrect` set → `tab focus` + `herdr pane run
     <pane_id> "<root>/bin/herd-resurrect.sh"`.
   → verify: stub the `api()` calls; assert focus-only when live, and
   focus+`pane run` when dead+flag; unchanged when flag absent.
3. Add `bin/herd-resurrect.sh`: print `herd: no nvim here — resurrect? [Y/n]`,
   read one key, `y`/⏎ → `exec "${HERD_EDITOR:-nvim}"`, `n` → exit 0 (stay at
   shell). Portable `read` (works in the user's shell).
   → verify: run the script directly, answer y and n; y execs the editor, n
   returns to the prompt.
4. Manual end-to-end: quit nvim to the shell, let the agent run, `Ctrl-a \`
   (with `--resurrect`): the prompt appears in the focused shell pane; `y`
   restores the session, `n` leaves you at the shell. With nvim still running,
   `Ctrl-a \` is silent-focus (no prompt).
5. Docs: README "Native mode" + return-trip section — `--resurrect` flag, the
   liveness-prompt behavior, native-only scope, and `HERD_EDITOR` override.
   → verify: `origin_spec` green; `herd-return.lua` still exits 0 silently when
   herdr is unreachable (regression guard on the existing contract).

---

## Cross-cutting / done criteria
- Each phase: its `_spec.lua` green, existing suite still green, `:checkhealth
  herd` clean, one manual end-to-end check from the spec's success criteria.
- Config: all new keys optional with documented defaults; no existing config
  breaks. Update README usage table + Configuration block per phase.
- Commit per phase (conventional-commit style matching the repo), so each
  increment is independently revertible.

## Suggested order rationale
1 (invisible glue, ~3 lines) → 2 (visible prompt-quality win) → 3 (cheap, same
seam) → 4 (new read+parse, self-contained) → 5 (background poller, opt-in) → 6
(return-trip resurrection, touches origin.lua/herd-return.lua, opt-in). Stop
after any phase and the plugin is in a shippable state. Phase 6 is independent
of 1–5 (different files), so it can also be pulled forward if the "closed the
editor, agent kept working" flow is the priority.
