# Changelog

All notable changes are documented here. This project follows semantic versioning.

## [Unreleased]

- Removed the flag subsystem, its gates and shadow-run counters; existing mail flags and legacy database rows remain unchanged.
- Scan responses include rules and state, removing routine preflight calls.
- Natural-language candidate confirmation stays in the weekly task; resolved candidates remain resolved after reimport.
- Centralized background models and bounded independent repair after returned failures.
- Restored fixed-template permission inheritance for weekly and repair tasks after scheduled ordinary creation regressed to workspace-write/on-request. Resolve the repair CLI through PATH instead of an obsolete app-bundle path.
- Replaced wording-based dispatcher checks with synthetic behavior tests.

## [1.0.0] - 2026-08-24

### Added

- Local Apple Mail JSON bridge with read-only scanning and privacy filtering.
- Incremental SQLite cursors, fingerprint deduplication, candidates, explicit rules, and flag audit batches.
- Attachment allowlist, size limits, temporary export cleanup, and macro/archive rejection.
- Reversible red/orange flags with confirmation gates and existing-flag protection.
- Codex `email-triage` skill with Chinese report and CalendarBridge handoff contracts.
- Weekly-conversation dispatcher template for scheduled inbox reports.
- Apple Silicon and Intel release packaging, automated macOS CI, security guidance, and Chinese documentation.
