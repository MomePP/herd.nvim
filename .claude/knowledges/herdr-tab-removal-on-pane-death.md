# herdr removes a dead agent's tab instantly (0.7.4)

Observed live (server log, 2026-07-18): when an agent's **only** pane exits,
herdr removes the pane *and its tab* within ~100ms — before a `tab get`
issued from a `wait output` completion callback can see it (`tab_not_found`
at +15ms after the wait returned).

Consequences:

- `lua/herd/herdr.lua`'s `prune_workspace` comment ("herdr removes the pane
  but leaves the (now agentless) tab behind") is **stale for single-pane
  tabs** on 0.7.4. Lingering agentless tabs can still occur (e.g. panes
  closed by other means), so the reaper isn't dead code — but don't design
  around the tab surviving a pane death.
- Anything that needs post-mortem state about a dead agent (its tab's
  `focused` flag, label, position) must capture it **before** the pane dies.
  Inferring it from surviving state was tried (focused-workspace +
  editor-tab-not-focused) and reverted: the inference can't distinguish
  "user was on the dead tab" from "user is on any sibling tab" and steals
  focus. There is no focus-history API (`herdr api` = snapshot/schema only).
  Hence bin/herd-run.sh decides the return trip pre-death, in-pane
  (pane-level `focused` is globally unique — exactly one focused pane
  server-wide), and `herd.watch` never moves focus.
- `herdr wait agent-status --status done` does NOT fire on process exit
  (hangs to timeout). `herdr wait output --match <sentinel>` returns the
  moment the pane dies, with a `pane_not_found` error — that's the reliable
  exit signal.
