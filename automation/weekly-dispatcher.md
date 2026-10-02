# Weekly dispatcher

Run in the saved local mailbox project at 08:00 and 20:00 Asia/Singapore. This task only routes work; reports and candidate confirmation belong in one task per ISO week. Models live in [settings.json](settings.json), shared state in the existing private `~/.codex/automations/apple/` directory.

Call [runtime.py](runtime.py) with a JSON request on stdin. It returns JSON with `ok`; current thread ID defaults from `CODEX_THREAD_ID`. The helper owns week/slot calculation, duplicate prevention and the managed-task registry, so do not repeat title scans, private session-index searches or routine `read_thread` checks.

1. Call `{"action":"dispatch.plan"}`. Pass `planned_at` only when the scheduler supplies its ISO timestamp. Otherwise the helper chooses the latest 08:00/20:00 slot. Stop on `paused`. For `already_registered`, do not redeliver; a prepared/running/failed record means an unfinished or uncertain run, so leave it visible and report its state.
2. For `deliver`, call `send_message_to_thread` with returned thread_id, prompt, model, thinking and local host. For `fork`, follow [task-creation.md](task-creation.md) using returned `task`: fork the hidden blank template, register, rename, and deliver once. This preserves the mailbox permissions that ordinary scheduled creation did not inherit.
3. Record `dispatch.delivered` (run_id) only after explicit acceptance. A registered but pending child must be finished or repaired, never replaced by an automatic second fork.
4. After accepted delivery, ask `cleanup.plan` (run_id, current thread_id). Serially archive only returned IDs and acknowledge successful archives through `cleanup.record` (that archived thread_id). Then make one final self-archive attempt. The helper keeps this and last week, active runs and unresolved failure tasks. Older tasks not in the managed registry are untouched. Self-archive may end the turn without a final response.

App task operations are serial. Explicit returned failures or unavailable required tools follow [failure.md](failure.md). An ambiguous/no-result creation or delivery must never be retried or replaced. No independent watchdog is installed.

## Configuration

The 2026-09-25 manual creation probe did not establish scheduled inheritance. The actual W40 task on 2026-09-28 started in workspace-write/on-request while its dispatcher was danger-full-access/never. Weekly and repair task creation therefore share the fixed-template path. The template ID lives in the private weekly registry and its recovery identity snapshot.

To change a role, call `config.set` with role, model and reasoning_effort. Roles are triage, dispatcher and repair. New triage/repair work reads these settings immediately. For dispatcher changes, call `config.sync`, read the existing automation TOML, then use the App `automation_update` tool to update its model, reasoningEffort and prompt while preserving its other fields, including schedule, status and notifications. Never edit scheduler files directly.

Installation calls `initialize` once to validate the existing registry and preserve an identity snapshot for repair. The helper stores IDs, timestamps, phases and error types only; no mail content or credentials.
