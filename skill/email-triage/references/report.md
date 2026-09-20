# Report contract

Write in Chinese, preserving original sender names and meaningful subjects/proper nouns. Lead with required actions, important changes, and exceptions. Omit empty sections.

- Important messages normally need 2–4 sentences: specific experiment/meeting/course/task name, what it concerns, date/time/place, and required action or deadline. Combine related messages around the latest supported arrangement; do not mistake quoted older text for a new instruction. Preserve source account and subject for traceability.
- For relevant missing fields, say “原文未提供”; if unreadable, say “未能读取，待核查”. Do not invent details or treat a failed/truncated read as proof that a message is unimportant. Read necessary body/approved attachments before summarizing; summarize rather than pasting raw text.
- Show calendar/reminder candidates with their stable IDs and missing required fields, and invite confirmation of concrete candidates. Avoid repeating the same content in a separate summary. Never create calendar items automatically.
- Describe security concerns with a concrete reason and next step. Never repeat codes, tokens, sensitive links or card suffixes.
- Routine advertising, codes and low-value notices need no individual report unless requested. Do not archive, delete or change read state.
- Hide normal scan counts, skipped duplicates, cursor progress, scheduling delay and shadow flag results. Show operational details only on explicit request or when they explain a material exception. Preserve real flag batch IDs internally for rollback; current scheduled runs remain flag.preview only.
- After all pages complete and state.record succeeds, always send a final report or a short completion receipt in the current triage task. If the entire run found zero new unprocessed messages and no exception, reply exactly “本次整理未发现新邮件。” If new messages were found but none contains worthwhile information and there is no exception, reply exactly “本次整理未发现需要关注的新内容。” Do not describe low-value new mail as no new mail, or leave a successful run silent.
- For partial failures, state what completed, what remains unread/unprocessed, and the next step. Do not claim a clean inbox or successful completion from an uncertain result.

Do not write a local Markdown report or persist raw bodies/attachments. Keep routine completion receipts to one sentence; provide diagnostic detail when directly requested or when reporting an exception.
