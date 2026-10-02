# MailBridge interface

The bridge accepts one JSON object on stdin and returns one JSON object. Use `$MAILBRIDGE_PATH` or `$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge`.

## Completion and paging

Serialize calls. Retain the complete command result; if it returns a session handle, collect all chunks from that same session. Parse only after exit 0 and require `ok: true`. Truncation, missing terminal results and unknown outcomes cannot advance state. Use a sufficiently large output budget, or a private temporary response file removed after parsing; never leave a raw-mail log. Keep waits within 60 seconds.

Start with:
```json
{"action":"message.scan","limit":200,"previewCharacters":800}
```

The response contains `messages`, `state`, `rules`, and string-valued `details` (`since`, `until`, `hasMore`, `nextOffset`). Keep the same `since`/`until`/limit on later pages and pass `offset: nextOffset` until `hasMore: "false"`. Keep a run-level fingerprint set to handle duplicates across pages.

The first run covers 24 hours; later runs overlap stored per-account cursors by 15 minutes. Disabled/orphan cursors remain stored but do not widen the window. Metadata is deduplicated before previews; `previewCharacters: 0` fetches no body.

Messages contain `ref`, `receivedAt`, `sender`, `subject`, sanitized preview, fingerprint and a classification hint. The hint is not the final classification. For body/attachment metadata:
```json
{"action":"message.read","ref":{"accountId":"...","libraryId":1},"maxBodyCharacters":8000}
```

Increase the body limit up to 40,000 when needed; disclose remaining incompleteness. Mail events time out after 30 seconds; scan checks a 60-second budget between events. A failed page is never a complete scan.

## Attachments

`attachment.export` takes `ref` and `attachmentId`, returning `attachment.path` and `attachment.cleanupToken`. Inspect that file and always finish with `attachment.cleanup` plus `cleanupToken`.

Allowed extensions: png, jpg/jpeg, pdf, csv, tsv, txt, md, docx, xlsx. Empty MIME can be inferred from these exact extensions; a nonempty MIME must match. Limit: 10 MB/file, 20 MB/message. Never execute attachments or inspect archives/macros. Read responses expose effective MIME/inference or rejection reason. An intentional policy rejection is a reportable content limitation, not a system fault to bypass.

## State and explicit mutations

After the frozen window is fully classified and the report is ready, call:
```json
{"action":"state.record","state":{"processed":[],"candidates":[],"cursors":[]}}
```

- `processed`: ref, fingerprint, receivedAt, final category, optional candidateId.
- `candidates`: each record has top-level `id`, `kind`, `title`, `accountId`, `libraryId`, `sourceSubject`; account/source fields are not nested under `ref` or `source`. Optional fields are start/end/due/location/short notes. Do not store raw bodies.
- `cursors`: accountId and greatest successfully processed receivedAt. Do not advance an incomplete account/window.

The write is atomic, validates enabled accounts and preserves monotonic cursors. Reimporting a candidate preserves its accepted/dismissed status.

`state.pending` returns pending candidates. `candidate.resolve` takes `candidateIds`, `candidateStatus` (accepted/dismissed) and `confirmed: true`; the user's clear natural-language instruction supplies confirmation.

`rule.upsert` takes `rule` (field: sender/domain/subject, pattern, category) and `confirmed: true`, after an explicit future-rule request.

For diagnosis only: `status` reads Mail access/accounts; `state.status` reads counts/cursors; `rule.list` reads rules. `setup` can open macOS permission prompts. `state.repair` with confirmed orphan `accountIds` removes only those cursors; current and disabled accounts are protected. Neither is a routine triage prerequisite.
