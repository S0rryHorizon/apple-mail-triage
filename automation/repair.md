# Independent mailbox repair

The user authorized automatic local repair after returned technical failures. Model/effort come from settings.json. Read runtime.py `repair.get` for the supplied incident_id and call `repair.attach` with this task's actual ID. If automation is paused, stop without restarting it or rescanning.

Diagnose with current project source, the failed task's tool results when accessible, and synthetic tests. You may fix mailbox-project source/configuration, back up and reinstall its bridge/skill, and restart the affected workflow. Preserve unrelated working changes, mailbox state and project identity. Global Codex settings, account login, system permissions and permission prompts need the user's action; report these boundaries when they are the actual blocker.

Do not send or modify mail, loosen attachment protections, use raw mail in fixtures, or create another repair task. Iterate within this task as needed. Back up installed artifacts and use SQLite's backup API for MailTriage state before deployment; never read Apple's private Mail database. Validate only affected behavior.

## Recover once

- A dispatcher cleanup failure can occur while the accepted weekly run is still delivered/running. Observe that existing run first; do not mark it failed, replace it or rescan it. `repair.retry` returns `triage_in_progress` in this case. An unknown outcome remains visible and is not a retry trigger.
- Call `repair.get` again. If the run is already recorded, inspect its actual final report using `wait_threads`/a bounded task read; do not rescan. If the reply was interrupted after state saving, recover the prepared report from that task's existing context. If unavailable, report failure rather than fabricate completion.
- If a fork was registered but naming/delivery is still pending, finish setup on that known child instead of creating another fork.
- Otherwise use at most one `repair.retry`. If the weekly task itself failed, or there is no usable weekly task, fork the blank template identified by `repair.get.template_id`, following [task-creation.md](task-creation.md). Register the returned child with `repair.retry` and replacement_thread_id, rename it to the original run title, then deliver the returned prompt/model/thinking once. The template starts no scan itself. Retain the old task until success. If only the dispatcher failed and the weekly task remains usable, omit replacement_thread_id.
- `repair.retry` returns the exact thread_id/prompt/model/thinking for one `send_message_to_thread`. If a required App tool is absent, local CLI `queue` may deliver that exact prompt once only when no delivery was attempted; use subprocess argument arrays, including configured model/effort, and require exit 0. Never replay an unknown delivery.
- Observe completion with a bounded `wait_threads`, using its cursor when continuing. Check both runtime phase recorded and the actual final report/empty receipt. A queued prompt, successful build or saved state alone is insufficient.
- Call `repair.finish` with success:true and report_delivered:true only after both are confirmed. Archive returned archive_ids serially, acknowledging each with `cleanup.record`. Then report what was repaired and where the recovered report lives.
- On failure, missing required user action, or a second triage failure, call `repair.finish` with success:false, leave broken tasks visible, and report the concrete blocker. An incident remains unresolved and cannot spawn another repairer automatically.

A repair task started through CLI persists as a normal independent Codex task. If its App tool catalog is absent, use available official CLI commands only where their result can establish the same outcome. Do not alter global plugins/settings or bypass unavailable permissions to manufacture success.
