#!/bin/sh
# herd-run — run the agent CLI, then hand focus back to the editor tab BEFORE
# this pane dies. Reactive watchers (herd.watch) can only act after herdr has
# removed the dead tab and flashed a neighbor tab; here the pane (and its tab)
# still exist, so "is the user looking at this agent" is a plain focused check
# and the editor tab is current by the time herdr reaps the tab — no flash.
#
# HERDR_TAB_ID is injected by herdr into every pane it owns (this agent's own
# tab); HERD_ORIGIN_TAB is passed by herd.nvim at spawn (the editor's tab).
"$@"
code=$?
if [ -n "$HERD_ORIGIN_TAB" ] && [ -n "$HERDR_TAB_ID" ]; then
  if herdr tab get "$HERDR_TAB_ID" 2>/dev/null | grep -q '"focused":true'; then
    herdr tab focus "$HERD_ORIGIN_TAB" >/dev/null 2>&1
  fi
fi
exit $code
