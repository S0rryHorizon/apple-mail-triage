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

Keep the current and previous weekly tasks visible and archive only older managed weekly tasks. Manual discussions and candidate-confirmation tasks are never auto-archived. The local dispatcher keeps a permission-restricted weekly-thread index outside the repository, so migrated or delegated threads with incomplete App project metadata can still be continued by their verified stable ID; routine continuation validates that index locally and sends directly, avoiding a hanging `read_thread` call. An unknown exact-title collision still stops the dispatcher instead of creating a duplicate. A successful empty scan adds one compact receipt; new messages or errors produce the complete report. See [the portable dispatcher template](automation/weekly-dispatcher.md).

Scheduled runs require the Mac to be awake, Codex desktop to be available, and this project path to remain accessible. Delayed runs catch up from the last successful cursor and remain assigned to the ISO week of their planned slot.

## Calendar and reminder handoff

Email triage only creates stable candidates. The user must confirm candidate IDs before the installed `apple-calendar-assistant` previews a CalendarBridge batch. Duplicates, conflicts, or missing dates stop the handoff for another decision.

## Development and tests

```sh
swift build
swift run MailBridgeSelfTest
python3 -m unittest Tests/integration_test.py
python3 -m unittest Tests/dispatcher_contract_test.py
```

The automated suite uses synthetic data and a temporary SQLite directory. It does not open Apple Mail. Live Apple Mail permission and read-only smoke tests remain manual by design.

## Repository privacy

Local SQLite state, exported attachments, Codex automation memory, generated reports, and build products are ignored and must never be committed. See [SECURITY.md](SECURITY.md).

## License

Released under the [MIT License](LICENSE).
