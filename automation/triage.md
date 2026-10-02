# Background triage

This prompt applies only when a dispatcher supplies a run_id. Manual skill use and later user candidate confirmation in this weekly task use the current installed skill normally.

1. Call runtime.py with `{"action":"triage.begin","run_id":"<supplied ID>"}`. It registers this task and claims the run. If `should_run` is false, stop; do not repeat scanning.
2. Execute the current installed `$email-triage`. The scan supplies state and rules. Finish pagination, prepare the report, then save processed records/candidates/cursors.
3. Once MailBridge `state.record` succeeds, call `{"action":"triage.recorded","run_id":"...","state_recorded":true}`, then deliver the actual report or skill-defined empty receipt as your final reply. A recorded phase alone does not prove that a report was delivered.
4. A returned operational failure follows [failure.md](failure.md). Never mark a partial run complete. Attachments rejected by policy, missing candidate dates and calendar conflicts are content/user decisions, not auto-repair triggers.

The dispatcher already selects this role's configured model. Do not spawn a substitute model task or perform flags. Do not act on historical prompts that demand old flag checks, special receipts, or a separate confirmation task.
