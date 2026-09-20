# MailBridge interface

The bridge reads one JSON object from stdin and emits one JSON response. Resolve the executable from `$MAILBRIDGE_PATH` when set, otherwise use:

```text
$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge
```

## Command completion

When invoking the bridge through `functions.exec`, keep the whole `exec_command` result, including `output`, `session_id`, and `exit_code`. A running command's first output is only a chunk. For example, with a safely prepared bridge command:

```javascript
const outputBudget = 20000;
let result = await tools.exec_command({cmd: preparedBridgeCommand, yield_time_ms: 30000, max_output_tokens: outputBudget});
let output = result.output ?? "";
let truncated = (result.original_token_count ?? 0) > outputBudget;
while (result.session_id !== undefined) {
  result = await tools.write_stdin({session_id: result.session_id, chars: "", yield_time_ms: 30000, max_output_tokens: outputBudget});
  output += result.output ?? "";
  truncated ||= (result.original_token_count ?? 0) > outputBudget;
}
if (truncated || result.exit_code !== 0) throw new Error("MailBridge output incomplete or command failed");
const response = JSON.parse(output);
if (!response || typeof response !== "object" || Array.isArray(response) || response.ok !== true) {
  throw new Error("MailBridge did not return ok: true");
}
text(JSON.stringify(response));
```

Parse only after the original command reaches a terminal result. Size both the command and outer `functions.exec` output budgets for the expected response, and heed any truncation warning even if the command exits. Treat a missing session handle while still running, a missing exit code, truncated or malformed/incomplete JSON, nonzero exit, or `ok: false` as failure or unknown outcome; stop the operation without starting the scan again. If the outer `functions.exec` call yields a cell ID, resume that cell with `functions.wait`; the cell ID is not the inner command's `session_id`. Keep each wait to at most 60 seconds and provide a progress update during longer work.

## Read workflow

- `{"action":"status"}` checks Apple Mail access and lists enabled accounts.
- `{"action":"state.status"}` returns cursors, pending count, shadow-run count, and the real-flag gate.
- `{"action":"rule.list"}` returns explicit sender/domain/subject overrides.
- `{"action":"message.scan","limit":200,"previewCharacters":800}` returns the first page of unprocessed inbox messages. Omit `since` to use the first-run/cursor policy.
- Freeze the returned `details.since` and `details.until`. While `details.hasMore` is `true`, request the next page with the same `since`/`until`, `offset` set to `details.nextOffset`, and the same `limit`/`previewCharacters`.
- `offset` and `nextOffset` count the raw inbox enumeration, including already processed messages; each selected page is sorted for display only after its raw boundaries are fixed. A failed scan page cannot advance. A frozen time window is not a snapshot of a changing inbox, so repeat a window with overlap and fingerprint deduplication rather than assuming concurrent inbox changes are covered by one pass.
- Deduplicate fingerprints across the entire run, not only within one page. New mail arriving after the frozen `until` is deliberately left for the next run.
- `{"action":"message.read","ref":{"accountId":"...","libraryId":1},"maxBodyCharacters":8000}` returns one sanitized body plus attachment metadata.

Each message contains `ref`, `receivedAt`, `sender`, `subject`, `sanitizedText`, current `flagIndex`, a stable `fingerprint`, and a conservative `hint`. The hint is not the final classification.

Scans deduplicate metadata before fetching any body. `previewCharacters: 0` fetches no body, and lookahead/processed/duplicate messages do not fetch previews. Default windows ignore orphan and disabled-account cursors without deleting them; enabled accounts without cursors retain a 24-hour initial window. Preserve the returned `since` and `until` on every subsequent page.

A Mail event times out after 30 seconds. A scan checks a 60-second budget between messages and body reads; an in-flight event can take additional time to return or time out. A timeout or unreadable metadata/body fails the page, never reports it as complete, and must not advance cursors or increment the shadow-run count. Stop and report the incomplete run; a later attempt can use a smaller `limit` and the same frozen window after the original call has ended. SQLite tolerates brief lock contention for up to five seconds without replaying a state mutation.

## Attachments

Use `attachment.export` with a message `ref` and `attachmentId`. The bridge rejects unsafe types, files over 10 MB, or messages whose attachments exceed 20 MB. The response contains a path and `cleanupToken`. After inspection, always call:

```json
{"action":"attachment.cleanup","cleanupToken":"..."}
```

Never execute an attachment or inspect archives/macros.

## Flags

Pass `flags` as message references plus semantic colors (`orange` or `red`).

- `flag.preview` is read-only and reports `would_flag` or `preserved_existing`.
- `flag.commit` additionally requires `confirmed: true` and a previously enabled state gate. It returns a `batchId`.
- `flag.rollback` requires that `batchId` and `confirmed: true`. It refuses to overwrite a flag the user changed after the batch.

## State

After all pages report `hasMore: false` and the report is ready, call `state.record` with:

- `processed`: message ref, fingerprint, receivedAt, final category, optional candidate ID.
- `candidates`: stable candidate records; do not include raw message bodies.
- `cursors`: maximum successfully processed receivedAt per account. Never advance them for a partial page sequence, parsing failure, or failed account.
- `shadowRunsCompleted`: increment only after a complete scheduled shadow report.

Use `state.pending` to restore candidate details. `candidate.resolve` needs explicit candidate IDs, status, and `confirmed: true`.

Enabling real flags uses `state.record` with `flaggingEnabled: true` and `confirmed: true`; only do this in direct response to the user's explicit approval after the preview and two shadow runs.

Long-term rules support fields `sender`, `domain`, and `subject`. `rule.upsert` requires `confirmed: true` and an explicit “from now on” user instruction.

If any response has `ok: false`, stop that operation, report the error, and do not claim success.

## Attachment MIME diagnostics and explicit cursor repair

`message.read` preserves the raw `mimeType` and reports `effectiveMimeType` and
`mimeInferred` for approved attachments, or `rejectionReason` for rejected ones.
Only an empty (whitespace-trimmed) raw MIME may fall back to the exact extension
mapping: png, jpg/jpeg, pdf, csv, tsv, txt, md, docx, xlsx. Nonempty MIME is
lowercased and stripped of parameters, then must match that extension exactly.
Other extensions (including previously accepted html, htm, heic, webp) are rejected.
The 10 MB per-file and 20 MB per-message limits remain in force. Export responses
return the effective MIME and a `details.mimeInferred` diagnostic. Attachments
must never be executed; always clean up exports after inspection.

`state.record` validates every account referenced by processed records, candidates,
and cursors against the currently enabled Apple Mail accounts. Unknown or disabled
IDs reject the entire request without any state writes. Account lookup failures
also fail closed. Cursor timestamps must parse as ISO 8601 and never move backwards.
This does not change the requirement to finish classification for an account before
recording it; attachment failures must never be skipped to advance cursors.

To explicitly remove reviewed orphan cursors, call:

```json
{"action":"state.repair","confirmed":true,"accountIds":["reviewed-orphan-account-id"]}
```

This requires user confirmation of the exact IDs. The entire repair is rejected if
any ID has no cursor or belongs to any current account, including a disabled account.
It deletes only the selected orphan cursors, leaving processed records, candidates,
and settings intact. Startup never silently removes unknown cursors.
