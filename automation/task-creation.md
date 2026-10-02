# Create a task with mailbox permissions

Use the fixed blank template in the private registry's `templateThreadId`. Its saved context has `approval_policy: never` and `sandbox_policy: danger-full-access`, scoped to the mailbox workflow. Ordinary `create_thread` lost those settings in the scheduled W40 run despite the project config; it is not used for weekly or repair tasks.

Given runtime's `task` object:

1. Unarchive `task.fork_args.threadId`, then call `fork_thread` with `task.fork_args` (same directory). Do not fork a report or dispatcher. The blank template contains no mail history.
2. After a complete fork result, immediately retain its real threadId. For a new week call `week.register` with run_id and thread_id; for a repairer call `repair.attach` with incident_id and thread_id. For a recovery replacement, call `repair.retry` with replacement_thread_id. These calls prevent duplicate creation if later setup fails.
3. Re-archive the template once the fork call has returned. Hide failures do not justify another fork. Never overlap these App calls or replay an unknown fork result.
4. Name the child using `task.title`, then send `task.prompt` once with `task.model` and `task.thinking`. Forking alone does not start triage. Record accepted weekly delivery with `dispatch.delivered`; `triage.begin` also finalizes the registered week's ready state.

The template stays archived between creations. Existing weeks continue by their registered ID. Model choices remain in settings.json; permission inheritance does not require copying prior weekly history, changing global settings or repeating a permission audit on each run.
