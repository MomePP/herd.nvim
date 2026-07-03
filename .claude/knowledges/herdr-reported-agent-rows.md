# herdr reported-agent rows are name-less

Verified live against herdr 0.7.1 (2026-07-02): a row created via
`herdr pane report-agent <pane> --source <src> --agent <label> --state idle`
appears in `herdr agent list` with an `agent` field (the label) but **no
`name` field** — so herd's nameless-skip in `Herdr.agents()` filters
reported rows out of discovery automatically.

Also learned during the same probe: reporting an agent on a pane that
already hosts a live detected agent produces no separate observable row —
probe reported rows on an agentless pane.

History: the `experimental.editor_agent` feature (report nvim itself into
the agents panel so `next_agent`/`previous_agent` cycle editors too) was
built on this, live-tested 2026-07-03, and **removed the same day** — the
owner's verdict: the agents panel should contain only agents; with several
editor instances it becomes a mess. The full implementation lives in git
history (added `c3662f2`/`87a00b0`, removed in the follow-up commit on
`feat/native-round-trip`) if it's ever wanted again.
