#!/bin/sh
# herd-run — run the agent CLI, then hand focus back to the editor tab BEFORE
# this pane dies. Reactive watchers can only act after herdr has removed the
# dead tab and flashed a neighbor tab; here the pane still exists, so "is the
# user looking at this agent" is a plain focused check and the editor tab is
# current by the time herdr reaps the tab — no flash.
#
# The check is PANE-level (exactly one pane is focused server-wide): a user
# typing in a sibling split of this tab must not be yanked, so tab-level
# focus is not enough. HERDR_PANE_ID is injected by herdr into every pane it
# owns; HERD_ORIGIN_TAB is passed by herd.nvim at spawn (the editor's tab).
#
# No exec/trap on purpose: the CLI stays a foreground child so its terminal
# behavior is untouched, and the only signal herdr delivers is the PTY-close
# HUP to the whole foreground group (pane teardown — a focus return would be
# moot, and the CLI receives its own HUP directly, not via forwarding).
"$@"
code=$?
if [ -n "$HERD_ORIGIN_TAB" ] && [ -n "$HERDR_PANE_ID" ]; then
  # whitespace-tolerant exact-field match; deliberately not a full JSON parse
  # to keep this dependency-free, but resilient to `"focused": true` spacing
  if herdr pane get "$HERDR_PANE_ID" 2>/dev/null \
    | grep -Eq '"focused"[[:space:]]*:[[:space:]]*true'; then
    herdr tab focus "$HERD_ORIGIN_TAB" >/dev/null 2>&1
  fi
fi
exit $code
