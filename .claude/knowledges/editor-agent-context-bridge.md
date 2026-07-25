# Editor↔agent context bridge — final state

The bidirectional, context-aware editor↔agent seam (shipped via #1 and #2;
spec/plan history lives in those MRs). What only the editor can own: passing
editor context to the agent, and landing agent output back in the editor.

## Editor → agent

- **Context-aware visual send** — `send.context` (default `true`): the visual
  send wraps the selection as a `path:sline-eline:` header + filetype-fenced
  block via the public `format_context(ctx)`;
  `ctx = { path, ft, sline, eline, text }`. `false` sends raw text
  (pre-bridge behavior); a `function(ctx) → string` fully controls the shape.
  `send` may itself be non-table (`send = false`) — code guards before
  indexing `.context`.
- **`:Herd diagnostics`** — `vim.diagnostic.get(0)` → `format_diagnostics`
  (file header, then `line:col [SEVERITY] message (source)` per entry,
  multi-line messages collapsed) → the shared `deliver()` seam. Clean buffer
  → notify, no send. No default keymap (user opts in).
- `deliver()` (init.lua) is the one send path: resolve `Target.current` →
  `pane send-text <pane_id>` (never by agent name) → `show()` to land in the
  agent for review/submit. No Enter is ever appended.

## Agent → editor

- **`:Herd jump`** — `Herdr.agent_read(pane, { source = 'recent', lines =
  200 })` → `parse_refs(text, agent.cwd)`: `path:line(:col)?` tokens,
  resolved relative to the agent's cwd, kept only when they `fs_stat` to a
  real file (guards against prose false-positives), deduped → quickfix +
  `:cfirst`. Named `jump` because `goto` is a reserved Lua keyword. No
  default keymap.
- **Auto-reload** — `reload` (default `true`): `checktime` on `FocusGained`
  (agents edit while nvim is unfocused) and, float mode, on `BufLeave` of an
  agent float. Respects `'autoread'`.

## Return trip (native mode)

- **Auto-return** — `auto_return` (default `true`): focusing an agent arms
  watch.lua's blocking `herdr agent wait <pane> --until unknown`. On agent
  exit: if the agent's pane is still `focused` (the user was looking at it)
  → focus the origin tab first, then reap the agent tab unless the user
  split it (`pane_count > 1`). `FocusGained` in nvim disarms the watcher.
  Generation counter invalidates superseded callbacks.
- **`--resurrect`** — opt-in arg on the herdr-side herd-return binding, NOT
  `setup()` config (the headless `nvim -l` script never loads setup). Key
  insight: quitting nvim leaves its herdr pane/tab alive as an idle shell,
  so the liveness signal is **"is nvim a foreground process in the origin
  tab's editor pane"** (`pane process-info` → `Origin.has_nvim`), never tab
  existence. nvim dead → `pane run bin/herd-resurrect.sh` injects an
  interactive `[Y/n]` prompt into that live shell pane (no UI needed in the
  headless script); `y` → `exec ${HERD_EDITOR:-nvim}` in the same pane
  (label link preserved). Session restore is the user's nvim-config job
  (resession autoload etc.), not herd's.

## Dropped — don't re-propose

- **Linked-agent state in the statusline**: implemented, then removed.
  Redundant with herdr's own sidebar (already shows each agent's status);
  a poll-backed second copy inside nvim wasn't worth the background CLI
  cost.
- An agent that *controls* the editor / drives herdr layout: explicit user
  decision that this belongs herdr-side, not in the editor plugin.
