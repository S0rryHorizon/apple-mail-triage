# Report contract

Write in Chinese while preserving original sender names, subjects, and proper nouns. Use this fixed order:

1. **高风险核查** — concise reason and safe next step; no codes, card suffixes, or sensitive links.
2. **候选日程与待办** — stable ID, kind, title, effective date/time, source account/subject, and missing fields. Tell the user they can confirm IDs.
3. **重要信息摘要** — one or two Chinese sentences per useful non-action message.
4. **广告、验证码与普通通知** — one compact line per message with sender and original subject. For a code say only “收到验证码”.
5. **运行统计** — planned schedule slot, actual start time, delay, frozen scan window, backlog page count, per-account counts, category totals, skipped duplicates, attachment failures, account errors, flag preview/commit results, and next rollout step.

Do not write a local Markdown report. Do not include the sanitized body verbatim when a summary is sufficient.

During shadow mode, say which messages *would* receive orange/red flags and leave Mail unchanged. After real flagging is enabled, include the returned flag `batchId` for rollback.

For a delayed run, explicitly say that it is catching up from the last successful cursor. If paging or an account fails, label the report partial and do not claim that the backlog was cleared.
