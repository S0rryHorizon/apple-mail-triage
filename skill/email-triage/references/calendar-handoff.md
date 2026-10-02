# Calendar/reminder handoff

Before this handoff, apply the task-scope rules in [SKILL.md](../SKILL.md). A candidate confirmation or correction does not replace an active dispatched triage; finish its full scan, state recording, run registration and report first unless the user explicitly pauses, cancels or replaces it. Once the run is finished, handle the user's calendar request separately without restarting the scan or replaying an old confirmation.

Use the installed `$apple-calendar-assistant` and its CalendarBridge interface in the current weekly task. A natural-language confirmation of the listed candidates is authorization; no separate task, copied candidate ID or second routine confirmation is needed.

1. Read `state.pending` and resolve the user's wording to specific pending IDs. If the selection is ambiguous, ask which item. Never expand “这个截止日” to all candidates.
2. Ask for missing dates. Fixed-time commitments become events; tasks/deadlines become reminders. Preserve `Asia/Singapore`; notes contain only a short source reference.
3. Preview the selected drafts. Conflicts, duplicates or materially uncertain fields need a decision. A clean preview can commit the exact candidates already confirmed, including a clearly confirmed group.
4. Return the saved result and CalendarBridge `batchId`, then mark only successfully saved candidates `accepted` through `candidate.resolve` with `confirmed: true`.

A request to discard candidates similarly resolves their IDs and marks them `dismissed`. If calendar saving succeeds but candidate resolution fails, report the saved batch and repair only candidate status; do not create the calendar items again. Do not automatically retry a failed or uncertain calendar mutation.
