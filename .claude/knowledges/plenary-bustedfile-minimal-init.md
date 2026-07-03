# PlenaryBustedFile ignores minimal_init — use test_directory for the suite

`:PlenaryBustedFile <file>` (the command form) calls `test_file()` with no
opts table, so plenary never passes `-u <minimal_init>` to the nested nvim
child it spawns — the child loads the REAL `~/.config/nvim` (zpack, snacks,
everything). Cost us a false test failure (2026-07-03): a test asserting
`pcall(require, 'snacks.picker') == false` passed in-process but failed
under the command because the child could require the real snacks.

Run the suite with the harness function instead, which forwards it:

    nvim --headless --noplugin -u tests/minimal_init.lua -c \
      "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua', sequential = true })"

Historical per-file `PlenaryBustedFile` commands in old plan docs work only
for tests with no environment-sensitive assertions.
