# Security and privacy

MailBridge is intentionally local-only. It uses Apple Mail's supported automation interface and does not read Mail's private database or account credentials.

Never commit any of the following:

- `~/Library/Application Support/MailTriage/` or another state directory;
- exported attachments;
- Codex automation memory or generated inbox reports;
- real email samples, authentication tokens, verification codes, account IDs, or message IDs.

Use synthetic messages for tests and issue reports. If you find a vulnerability, report it privately to the repository owner instead of opening a public issue with sensitive data.
