# MailBridge interface

The bridge accepts one JSON object on stdin and returns one JSON object. Use `$MAILBRIDGE_PATH` or `$HOME/Applications/MailBridge.app/Contents/MacOS/MailBridge`.

## Completion and paging

Serialize calls. Retain the complete command result; if it returns a session handle, collect all chunks from that same session. Parse the complete JSON after process exit, including nonzero exits. Success requires both exit 0 and `ok: true`; an error JSON is an explicit failure. Truncation, missing terminal results and unknown outcomes cannot advance state. Use a sufficiently large output budget, or a private temporary response file removed after parsing; never leave a raw-mail log. Keep waits within 60 seconds.

For a dispatched background run, use the supplied runtime's `bridge.call` entry point for all requests below. It returns `outcome`, `run_phase`, and successful MailBridge data under `bridge`; it registers failures and finishes `state.record` as recorded/partial automatically. Follow the supplied background procedure for its `recovery` result. Direct MailBridge use below is for manual work.

An explicit error response includes a stable `errorCode`. Operational Apple Mail failures may also include privacy-safe `details`: `operation`, `reason`, `apple_error_number`, and `elapsed_ms`. Use these to distinguish metadata/body stages, Apple-event timeout and the overall scan deadline. Managed runs retain only these allowlisted fields in `last_bridge.diagnostics`; raw AppleScript errors and mail content are not logged. Preserve it when registering operational failures; do not collapse it to an exit code. `request_validation` means correct the request in this task. `permission_required`/`confirmation_required` need user action, and `not_found`/`attachment_limitation` need a bounded content report; none should launch automatic repair. `mail_automation_failure`, `state_storage_failure` and `unexpected_bridge_error` remain eligible operational failures under the runtime's existing deduplication.

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

Increase the body limit up to 40,000 when needed; disclose remaining incompleteness. Body reads decode Mail's MIME source in memory using the system Python standard library. When Mail returns a multipart source with its body boundary missing, the bridge tries Mail's rendered `content` once under the same Apple-event deadline. Empty fallback content remains `source_body_missing`; other malformed MIME is not silently accepted. Plain text is preferred; HTML is converted without executing scripts or fetching resources. Attachments are not body text. Raw MIME input is limited to 40 MB (including encoded attachments), decoded/fallback body text to 10 MB, and decoding to 5 seconds. These are input limits, not a bound on total RAM usage or a disk cache quota.

A size/format/decoding limitation returns `ok: true`, `status: "partial"` and `bodyReadError` on that message. The other messages and pagination remain usable: finish the frozen window, save only successfully classified mail, and report the unread items explicitly. Never mark `bodyReadError` mail processed or infer its body from its subject. `state.deferredBodyCount` counts retained failures; a successful body reread clears its failure. These content limitations do not launch a repair task. Mail permission, metadata, Apple-event timeouts and unknown results remain operational failures; do not treat their incomplete pages as complete. Mail events time out after 30 seconds; scan checks a 60-second budget between events.

## Attachments

For PDF, DOCX, XLSX, TXT, MD, CSV and TSV, prefer one self-cleaning call:
```json
{"action":"attachment.text","ref":{"accountId":"...","libraryId":1},"attachmentId":"...","maxBodyCharacters":16000}
```
It temporarily exports the attachment, extracts text locally, sanitizes it, deletes the export on success or conversion failure, and returns `text` plus `details.cleanup`, `truncated` and `contentScope`. Default 16,000 characters, maximum 40,000. MarkItDown is optional for the bridge; install this converter once with the project's `scripts/install-converter.sh`. No Markdown output files, cloud converters, plugins, network fetching or automatic OCR are used. Text extraction does not verify figures, scanned pages, layout or spreadsheet recalculation. Report truncation and these reading limits where material. A conversion rejection is a content limitation, not an automatic repair trigger.

For images or necessary visual inspection, `attachment.export` returns `attachment.path` and `attachment.cleanupToken`. Always pair inspection with `attachment.cleanup` in a `finally` path. Each bridge invocation also removes its own exports older than 24 hours, including abandoned UUID directories after a process crash. It never cleans Apple Mail's own storage. If no bridge runs, that fallback waits until the next invocation. Converted text returned to Codex remains part of the conversation, even after temporary files are deleted.

Allowed extensions: png, jpg/jpeg, pdf, csv, tsv, txt, md, docx, xlsx. Empty MIME can be inferred from these exact extensions; a nonempty MIME must match. Limit: 10 MB/file, 20 MB/message. Never execute attachments or inspect archives/macros. Read responses expose effective MIME/inference or rejection reason. An intentional policy rejection is a reportable content limitation, not a system fault to bypass.

## State and explicit mutations

After all pages are enumerated and the report is ready, save the successfully classified messages:
```json
{"action":"state.record","state":{"processed":[],"candidates":[],"cursors":[]}}
```

- `processed`: ref, fingerprint, receivedAt, final category, optional candidateId.
- `candidates`: each record has top-level `id`, `kind`, `title`, `accountId`, `libraryId`, `sourceSubject`; account/source fields are not nested under `ref` or `source`. Optional fields are start/end/due/location/short notes. Do not store raw bodies.
- `cursors`: accountId and greatest successfully processed receivedAt. Do not advance an incomplete account/window.

The write is atomic, validates enabled accounts and preserves monotonic cursors. The bridge records only refs/timestamps/error types for unread bodies, rejects attempts to mark them processed, and caps each affected account's cursor before its earliest unread body. Other processed mail remains saved and deduplicated. Reimporting a candidate preserves its accepted/dismissed status. A saved partial result is not a fully completed run.

`state.pending` returns pending candidates. `candidate.resolve` takes `candidateIds`, `candidateStatus` (accepted/dismissed) and `confirmed: true`; the user's clear natural-language instruction supplies confirmation.

`rule.upsert` takes `rule` (field: sender/domain/subject, pattern, category) and `confirmed: true`, after an explicit future-rule request.

For diagnosis only: `status` reads Mail access/accounts; `state.status` reads counts/cursors; `rule.list` reads rules. `setup` can open macOS permission prompts. `state.repair` with confirmed orphan `accountIds` removes only those cursors; current and disabled accounts are protected. Neither is a routine triage prerequisite.
