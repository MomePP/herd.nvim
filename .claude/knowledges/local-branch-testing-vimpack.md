# Testing a herd.nvim branch in the live nvim — vim.pack ignores dev=true

Cost us a full debugging detour (2026-07-03): with `dev = true` set on the
herd.nvim spec, the user's nvim still ran a **stale/wrong plugin version**,
which looked like feature bugs (dashboard fell into the old float-only path;
`<leader>s` "stopped working" because an ancient GitHub clone with different
default keys got installed).

Why: the user's plugin manager (zpack over nvim's builtin vim.pack) installs
to `~/.local/share/nvim/site/pack/core/opt/herd.nvim`. zpack's `dev = true`
registers the local source (`~/Developer/nvim-plugins/herd.nvim`) — zpack
state even shows it — but vim.pack keeps loading the already-installed clone
under the same name, and a fresh install can still clone from GitHub.

**The working procedure** (same one used for both feature branches so far):

    rm -rf ~/.local/share/nvim/site/pack/core/opt/herd.nvim
    git clone --branch <branch> ~/Developer/nvim-plugins/herd.nvim \
        ~/.local/share/nvim/site/pack/core/opt/herd.nvim
    # restart nvim; verify: :lua= require('herd.picker').open_global ~= nil

- It is a real clone, not a link: after each new commit on the checkout,
  `git -C <pack path> pull origin <branch>` and restart nvim again.
- When done, re-point to main the same way (or fetch+checkout main in the
  clone). Keep GitHub pushed — a stale remote is what made the accidental
  GitHub clone so confusing.

Diagnosis shortcut for "is nvim running the code I think it is":
`git -C ~/.local/share/nvim/site/pack/core/opt/herd.nvim log --oneline -1`.
Note the herdr-side `bin/herd-return.lua` is independent of all this — the
herdr keybind runs it straight from the `~/Developer` checkout path, so it
can be "new" while the loaded plugin is old (exactly the split-brain symptom
we saw: return trip worked, dashboard didn't).
