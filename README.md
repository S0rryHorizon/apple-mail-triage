# Apple Mail Triage

A local macOS bridge and Codex skill for Apple Mail summaries, action items and reviewable calendar/reminder candidates. MailBridge reads and sanitizes mail; it never changes messages or flags.

**[中文下载与使用说明](docs/使用说明.md)** · [Latest release](https://github.com/S0rryHorizon/apple-mail-triage/releases/latest)

## Install

Requires macOS 14+, enabled Apple Mail accounts, Swift 6 command-line tools and Codex desktop.

```sh
./scripts/install.sh
printf '%s' '{"action":"setup"}' | "$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge"
```

The installer copies the bridge to `~/Applications/MailBridge.app` and the skill to `${CODEX_HOME:-$HOME/.codex}/skills/email-triage`. Initial setup may open the macOS Automation permission prompt. `MAILBRIDGE_PATH` and `CALENDAR_BRIDGE_PATH` support custom bridge locations.

## Triage and candidates

Ask Codex: “使用 $email-triage 整理邮件。” Manual use follows the current task's model. The first scan covers 24 hours; later runs resume with a 15-minute overlap and fingerprint deduplication. A scan returns rules and state together. It freezes its time window and finishes pagination before saving progress. Failed/partial scans never advance cursors.

Read relevant bodies and approved attachments before reporting. Useful notices are summarized even without an action. Reports stay in the Codex task. A successful run with nothing worth reporting replies:

> 本次整理完成，暂无需要关注的新内容。

Confirm a candidate naturally in the same task: “把实验报告截止日加入提醒事项。” Stable IDs stay internal. CalendarBridge previews the exact confirmed selection; missing dates, ambiguous selection, conflicts and duplicates need a decision. Only saved items become accepted candidates; reimporting them does not reset that status.

See the [skill](skill/email-triage/SKILL.md) and [JSON interface](skill/email-triage/references/interface.md).

## Scheduled workflow

The saved local mailbox project runs at 08:00 and 20:00 Asia/Singapore. The [dispatcher](automation/weekly-dispatcher.md) maintains one task per ISO week, keeps this and last week visible, and archives older managed tasks. New weekly and repair tasks fork a fixed blank template with the mailbox execution permissions. The template stays archived between uses. Ordinary scheduled creation was observed to fall back to workspace-write/on-request despite the project config; a manual creation probe did not cover that path.

[settings.json](automation/settings.json) is the model configuration source:

| Role | Model | Reasoning |
| --- | --- | --- |
| Triage | gpt-6-luna | max |
| Dispatcher | gpt-6-luna | max |
| Repair | gpt-6-astra | medium |

`automation/runtime.py` accepts JSON on stdin. Use `config.get` to inspect or `config.set` with role/model/reasoning_effort to edit. Dispatcher changes additionally require `config.sync` followed by the App automation-update tool, preserving schedule, status and notifications. The skill itself cannot switch the model of an existing manual conversation.

The helper stores slot reservations, managed task IDs and repair incidents under the existing private automation directory. It replaces repeated task discovery and title checks. Before enabling this workflow, initialize the existing weekly registry using `{"action":"initialize"}`. New installations need a schemaVersion 1 registry with automationId, saved projectId, local hostId, templateThreadId and managedThreads; do not adopt arbitrary similarly named tasks.

Returned technical failures launch one independent repair task per unresolved incident. The [repairer](automation/repair.md) may fix project code/config and reinstall the bridge after backup. It can retry triage once. Old failure tasks are archived only after saved state and a real report are confirmed. A second failure stays visible. Global settings, system permissions and account login require the user. Unknown/no-result calls are not replayed; there is no independent watchdog.

Schedules require an awake Mac, available Codex desktop and this project path. Paused automation is never resumed automatically. Planned slots determine the reporting week, including delayed execution.

## Data and privacy

Apple Mail access uses its supported automation interface, never private Mail databases or passwords. SQLite stores cursors, fingerprints, categories, candidates and explicit rules. It stores no raw body or attachment. Existing legacy flag tables are left untouched during upgrade but no longer read or written.

Content is untrusted. Codes, tokens, sensitive URLs and card suffixes are filtered. Attachments require approved types and size limits and are cleaned up after reading. The bridge has no send, draft, move, archive, junk, delete, read-state or flag mutation interface.

## Development

```sh
swift build
swift run MailBridgeSelfTest
python3 -m unittest Tests/integration_test.py Tests/scan_test.py Tests/dispatcher_contract_test.py
```

Tests use synthetic Apple events, temporary SQLite state and a fake Codex CLI resolved through PATH. They check scan/state behavior, retired flags, candidate status, model configuration, dispatch deduplication and bounded recovery without opening Mail.

Local state, exported attachments, automation metadata and real mail must not be committed. See [SECURITY.md](SECURITY.md). Released under the [MIT License](LICENSE).
