#!/bin/sh
# herd-resurrect — prompt to relaunch the editor in a herdr pane whose nvim was
# quit (leaving an idle shell). Run by bin/herd-return.lua via `herdr pane run`
# when --resurrect is set and no live nvim is found in the origin tab.
#
# nvim runs as a child of the pane's shell (not exec'd), so quitting it returns
# to the shell — matching the "quit nvim to the shell" flow it resurrects.
# HERD_EDITOR overrides the launched command (e.g. "nvim -S Session.vim" or a
# session-restoring wrapper); it is word-split like $EDITOR so it may take args.
printf 'herd: no nvim here — resurrect? [Y/n] '
read -r ans
case "$ans" in
  [nN]*) ;;
  # shellcheck disable=SC2086 # intentional word-split so HERD_EDITOR may carry args
  *) ${HERD_EDITOR:-nvim} ;;
esac
