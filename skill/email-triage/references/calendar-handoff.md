# CalendarBridge handoff

Use the installed `$apple-calendar-assistant`. Resolve its bridge from `$CALENDAR_BRIDGE_PATH` when set, otherwise use:

```text
$HOME/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

1. Load candidates with `state.pending` and select only IDs the user explicitly confirmed.
2. Ask for any missing due/start date. A fixed-time commitment maps to an event; a task/deadline maps to a reminder.
3. Build the smallest CalendarBridge drafts, preserving `Asia/Singapore` and adding the source subject only as a short `sourceRef`/note.
4. Call `batch.preview`. If it reports conflicts, duplicates, or ambiguity, stop and show them for a new decision.
5. A clean preview may be committed for the exact IDs the user already confirmed. Return the CalendarBridge `batchId`.
6. Mark only successfully saved candidates `accepted` through `candidate.resolve`. Do not retry a failed calendar mutation automatically.

Ordinary promotional events never reach this handoff.
