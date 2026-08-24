# MailBridge interface

The bridge reads one JSON object from stdin and emits one JSON response. Resolve the executable from `$MAILBRIDGE_PATH` when set, otherwise use:

```text
$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge
```

## Read workflow

- `{"action":"status"}` checks Apple Mail access and lists enabled accounts.
- `{"action":"state.status"}` returns cursors, pending count, shadow-run count, and the real-flag gate.
- `{"action":"rule.list"}` returns explicit sender/domain/subject overrides.
- `{"action":"message.scan","limit":200,"previewCharacters":800}` returns the first page of unprocessed inbox messages. Omit `since` to use the first-run/cursor policy.
- Freeze the returned `details.since` and `details.until`. While `details.hasMore` is `true`, request the next page with the same `since`/`until`, `offset` set to `details.nextOffset`, and the same `limit`/`previewCharacters`.
- Deduplicate fingerprints across the entire run, not only within one page. New mail arriving after the frozen `until` is deliberately left for the next run.
- `{"action":"message.read","ref":{"accountId":"...","libraryId":1},"maxBodyCharacters":8000}` returns one sanitized body plus attachment metadata.

Each message contains `ref`, `receivedAt`, `sender`, `subject`, `sanitizedText`, current `flagIndex`, a stable `fingerprint`, and a conservative `hint`. The hint is not the final classification.

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
