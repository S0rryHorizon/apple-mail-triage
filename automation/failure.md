# Returned failure handling

Applies to dispatcher/background triage operations that return an explicit failure, including unavailable required App tools. It does not apply to missing user details, attachment-policy rejection, a fully hung/no-result call, or calendar writes. Report unknown outcomes without replaying them. Never resume a user-paused schedule.

1. Call runtime.py `incident.open` with run_id when known, current thread_id, stage, a short lowercase error_code, and outcome `failed` or `unavailable`. Save only a type such as `mail_timeout`, not raw error output containing private content. If `repair: false`, report the existing incident; do not create another repairer.
2. Call `repair.prepare` with the incident_id. When `launch: true`, use returned `task` with [task-creation.md](task-creation.md). Both repair and triage inherit the blank template's mailbox permissions; do not use ordinary `create_thread` for the repairer.
3. Only if required App fork/archive tools are absent, or creation definitely failed before creating a task, call `repair.cli` with incident_id and reason `tool_unavailable` or `creation_definitely_failed`. It launches one local Codex CLI repair task with explicit full mailbox-workflow execution permissions and the configured repair model. The CLI is resolved from `CODEX_CLI_PATH` or PATH, so app bundle layout changes do not break it. Never use this fallback after an unknown creation result or a known child threadId. An explicit user denial of a creation or permission request stops that action; it is not authorization for a fallback.
4. Leave the failed task visible, state the incident and repair status, and stop this run. The repairer decides recovery success. If launch itself fails, report that failure; do not recursively launch repairers.

The helper allows one repair task per unresolved stage/error incident. Later encounters add affected task IDs to that incident. No timer, daemon or independent hang detector runs.
