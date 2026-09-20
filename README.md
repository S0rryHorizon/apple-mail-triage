# Apple Mail Triage

A local macOS bridge and Codex skill for privacy-minimized Apple Mail triage. MailBridge exposes a narrow JSON stdin/stdout API; `email-triage` classifies sanitized messages, produces Chinese reports, extracts reviewable task/calendar candidates, and applies only explicitly enabled, reversible flags.

**[中文下载与使用说明](docs/使用说明.md)** · [Latest release](https://github.com/S0rryHorizon/apple-mail-triage/releases/latest)

## Safety model

- Uses Apple Mail's automation interface—never its private database or account passwords.
- Cannot send, draft, move, archive, junk, delete, or mark messages read.
- Removes verification codes, auth/reset tokens, sensitive query parameters, phone/order identifiers, and payment-card suffixes before model use.
- Stores cursors, fingerprints, categories, candidates, rules, and flag audit data in SQLite; it does not persist message bodies or attachments.
- Treats all message and attachment content as untrusted instructions.
- Preserves existing flags and audits committed batches for rollback.

## Requirements

- macOS 14 or newer
- Apple Mail with at least one enabled account
- Xcode Command Line Tools with Swift 6
- Codex desktop for the skill and optional scheduled reports

## Install

```sh
./scripts/install.sh
printf '%s' '{"action":"setup"}' \
  | "$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge"
```

The first `setup` may open a macOS Automation permission prompt for Apple Mail. Reinstalling a build with a different bundle identifier requires granting permission again.

The installer places:

- `MailBridge.app` in `$HOME/Applications`;
- the `email-triage` skill in `${CODEX_HOME:-$HOME/.codex}/skills`.

Set `MAILBRIDGE_PATH` or `CALENDAR_BRIDGE_PATH` when using non-default bridge locations.

## JSON interface

```sh
BRIDGE="$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge"

printf '%s' '{"action":"status"}' | "$BRIDGE"
printf '%s' '{"action":"state.status"}' | "$BRIDGE"
printf '%s' '{"action":"message.scan","limit":200,"previewCharacters":800}' | "$BRIDGE"
```

The first scan covers the previous 24 hours. Later scans use persisted cursors and a 15-minute overlap. A run freezes its `since`/`until` window and follows `nextOffset` until `hasMore` is false before advancing successful account cursors. See [the full interface contract](skill/email-triage/references/interface.md).

Scanning fetches metadata before deduplication and reads previews only for new messages on the current page. `previewCharacters: 0` does not fetch bodies. Default windows consider only currently enabled accounts; an account without a cursor gets the initial 24-hour lookback, while orphan and disabled-account cursors remain stored without widening the window. Receive times come directly from Mail and do not drift with scan duration.

Mail events have a 30-second timeout. Scans also enforce a 60-second budget between messages and preview reads (an in-flight Mail event must return or time out first). Metadata/body failures return an error rather than a successful partial page. SQLite waits up to five seconds for a transient lock; existing state reads avoid acquiring a writer lock for defaults. No scan advances state, and failed scans must never be recorded as complete.

Real flagging is disabled in a fresh state database. After reviewing shadow-mode results and explicitly deciding to enable it:

```sh
./scripts/enable-flagging.sh
```

This only opens the state gate. Each `flag.commit` still needs `confirmed: true`, never overwrites an existing flag, and returns a rollback batch ID.

## Reports and weekly conversations

Install this directory as a saved local Codex project. The recommended standalone automation runs at 08:00 and 20:00 in `Asia/Singapore`, invokes `$email-triage`, and routes results to one managed task per ISO week:

```text
邮箱整理｜2026-W35｜08.24–08.30
```

Keep the current and previous weekly tasks visible and archive only older managed weekly tasks. Manual discussions and candidate-confirmation tasks are never auto-archived. The local dispatcher keeps a permission-restricted weekly-thread index outside the repository, so migrated or delegated threads with incomplete App project metadata can still be continued by their verified stable ID; routine continuation validates that index locally and sends directly, avoiding a hanging `read_thread` call. After successful delivery it also archives only stale, idle dispatcher tasks with exact project/host/title/automation metadata; active or ambiguous tasks are left alone. An unknown exact-title collision still stops the dispatcher instead of creating a duplicate. Routine runs with no worthwhile new information or exceptions stay silent. Important mail receives a concrete, concise summary; normal statistics and shadow state remain hidden. See [the portable dispatcher template](automation/weekly-dispatcher.md).

If a background run temporarily lacks the Codex App thread tool catalog, an already-registered weekly target may use one local session-queue delivery attempt; discovery and creation still require the managed App tools. After delivery is accepted, stale-task cleanup is best-effort and deferred when listings are unavailable, while the dispatcher independently attempts self-archival. An uncertain delivery stops with the dispatcher visible; an uncertain self-archive needs later read-only verification.

Troubleshoot missing tools against the actual catalog in that scheduled turn: `codex_app` reporting ready does not establish which thread tools are available. An absent `send_message_to_thread` permits the single queue fallback above only for a validated registered target; absent listing tools defer cleanup. A delivery attempt with no result must not be sent again. When idle, a person may use the official app to unarchive and reload a dispatcher for read-only diagnosis. Do not automate archive/reload/requeue loops or change built-in plugins, private libraries, permissions, model, or architecture to mask the incident.

After accepted delivery, record the acceptance and completed/deferred cleanup in automation memory before the single, final self-archive call. A confirmed successful archive can end that same turn as `aborted` without a returned result or final reply; silence is not proof of failure or continued visibility. Check archived state later through a separate read-only diagnostic without unarchiving merely to verify.

Scheduled runs require the Mac to be awake, Codex desktop to be available, and this project path to remain accessible. Delayed runs catch up from the last successful cursor and remain assigned to the ISO week of their planned slot.

## Calendar and reminder handoff

Email triage only creates stable candidates. The user must confirm candidate IDs before the installed `apple-calendar-assistant` previews a CalendarBridge batch. Duplicates, conflicts, or missing dates stop the handoff for another decision.

## Development and tests

```sh
swift build
swift run MailBridgeSelfTest
python3 -m unittest Tests/integration_test.py
python3 -m unittest Tests/dispatcher_contract_test.py
swift run MailBridgeSyntheticDemo
```

The Python integration command runs `MailBridgeSyntheticTests` through SwiftPM. It exercises the existing attachment policy, account validation, and orphan-cursor repair checks, plus raw-order pagination, failed-page behavior, and resolved-candidate replay against the real service and a temporary SQLite database. It does not hand-link Swift object files.

The demo prints two pages of a deliberately unordered synthetic inbox, records three processed items and a reminder after `hasMore=false`, confirms the reminder, then replays `state.record` to show that it stays resolved. Both commands use injected accounts and scan results: they do not open Apple Mail, install the app, or touch its real state. A failed scan page returns no advanceable response; the caller must record progress only after the complete window succeeds. Offset pagination does not guarantee a snapshot if the real inbox changes during a multi-page scan. Live Apple Mail permissions, script parsing, and read-only smoke tests remain manual and unverified here.

## Repository privacy

Local SQLite state, exported attachments, Codex automation memory, generated reports, and build products are ignored and must never be committed. See [SECURITY.md](SECURITY.md).

## License

Released under the [MIT License](LICENSE).

### Weekly task permission inheritance

New weeks use a same-directory fork of the fixed minimal `邮箱周任务模板` task. This avoids the desktop `create_thread` delegated fallback that can start a new task in workspace-write even when the email project is configured for full access. Each week remains independent and archivable; previous reports never enter the template. A fork is registered as pending before naming, becomes ready after successful setup, and receives exactly one triage prompt. Pending setup stops delivery and prevents duplicate creation. The template is excluded from cleanup.

The template and one test fork were checked on 2026-09-07 using actual turn-context records: approval policy `never`, sandbox `danger-full-access`. The existing mail, flag-preview, and Calendar/Reminders boundaries remain in effect.

The fixed template stays archived between runs. Before a new week, the dispatcher temporarily unarchives only that template, forks it, registers the child ID, then archives the template again. This is a dedicated template operation; normal weekly cleanup never selects the template.
