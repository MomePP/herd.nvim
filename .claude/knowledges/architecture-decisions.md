# Architecture decisions — rationale and rejected alternatives

Distilled from the shipped float-mode, native-mode, and round-trip designs
(specs retired; full history in git). Current behavior: README / doc/herd.txt.
This file keeps the WHY and the don't-re-propose list.

## The nvim-host inversion (float mode)

nvim is the top-level host; herdr is an invisible backend daemon owning each
agent's PTY, shown via `herdr agent attach` in an nvim floating :terminal.
Load-bearing properties, verified empirically (0.7.1 spike):

- `agent attach` emits ONLY the agent's own PTY stream — no herdr chrome, no
  prefix bar — so the "two keybind worlds" problem can't reappear in a float.
- Detach ≠ kill: killing the attach client leaves the agent running in herdr.
  Hiding the float (or quitting nvim) never kills an agent.
- The attached agent stays the same `agent list` entry, so herdr's status
  hooks and dashboard keep working — the reason herdr over tmux/zellij.

## Rejected — don't re-propose

- **nvim tabpage display backend** (a third mode): dropped twice-over.
  (1) It doesn't solve the mouse trade-off — terminal-buffer mouse
  forwarding behaves identically in a float and a tabpage window.
  (2) nvim has no "hidden tabpage" concept — every tabpage is a visible
  peer in the tabline/`gt` cycle; the thing that gives "full surface,
  hidden until summoned, free round-trip" IS the fullscreen float.
- **Stored origin registry** (state file mapping agent → editor): herdr tab
  labels (`<project>:<agent>` vs bare `<project>`) already persist that
  link across restarts; a registry duplicates it and adds a stale-entry
  lifecycle. Resolution stays stateless over live `tab/pane/agent list`.
- **Second multiplexer / embedded tmux** and **NES-style edit suggestions**
  (sidekick-specific): out of scope by design.
- **Editor row in herdr's agents panel** (`experimental.editor_agent`):
  worked mechanically, rejected on UX — the panel should contain only
  agents. Facts preserved in [[herdr-reported-agent-rows]].

## Structural consequences worth remembering

- **Native-mode toggle is one-directional from nvim.** Once herdr shows the
  agent's tab, nvim isn't focused and receives no keystrokes — an nvim-side
  keybind can only ever mean "go to the agent". The return leg must be
  herdr-side (herd-return binding, last_pane, tab nav); this is a hard
  consequence of the model, not a scope cut.
- **Native cleanup evolution**: pre-0.7.5 there was no exit signal, so
  cleanup was lazy reap-on-next-spawn (`prune_workspace`). 0.7.5's
  server-side `agent wait` added prompt exit detection (watch.lua owns
  return + reap). Both still run — the watcher for the focused-agent case,
  prune-on-spawn as the catch-all for tabs the watcher missed.
- Float mode's dedicated hidden workspace exists so agents never tile next
  to nvim inside a herdr session; the cost (status indicators attribute to
  the hidden workspace, not the project) is exactly what native mode fixes
  by spawning into `$HERDR_WORKSPACE_ID`.
