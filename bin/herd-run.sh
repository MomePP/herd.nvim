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
"$@"
code=$?
if [ -n "$HERD_ORIGIN_TAB" ] && [ -n "$HERDR_PANE_ID" ]; then
  if herdr pane get "$HERDR_PANE_ID" 2>/dev/null | grep -q '"focused":true'; then
    herdr tab focus "$HERD_ORIGIN_TAB" >/dev/null 2>&1
  fi
fi
exit $code
