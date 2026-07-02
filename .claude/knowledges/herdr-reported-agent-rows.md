# herdr reported-agent rows are name-less (editor_agent depends on this)

Verified live against herdr 0.7.1 (2026-07-02): a row created via
`herdr pane report-agent <pane> --source herd.nvim --agent <label> --state idle`
appears in `herdr agent list` with an `agent` field (the label) but **no
`name` field**.

Why it matters: `Herdr.agents()` filters agents by `a.name` (the
nameless-skip for detected agents). The `experimental.editor_agent` flag
reports nvim itself into the agents panel and relies on that same skip to
keep the editor row out of herd's own discovery (picker rows, next_name,
targeting). There is **no automated guard** for this — if a future herdr
version starts assigning `name` to reported rows, the editor will show up
as a pickable "agent" in `<leader>S` and pollute `next_name`. The fix at
that point: extend the skip in `M.agents` to also drop rows with
`source == 'herd.nvim'` (fixture + test sketch exists in
`.claude/plans/native-round-trip.md` Task 6 Step 7 contingency).

Also learned during the same probe: reporting an agent on a pane that
already hosts a live detected agent produces no separate observable row —
probe reported rows on an agentless pane.
