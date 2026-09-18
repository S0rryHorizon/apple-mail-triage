"""Regression tests for the safe orchestration contract in the dispatcher template."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROMPT_PATH = ROOT / "automation" / "weekly-dispatcher.md"


class DispatcherContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prompt = PROMPT_PATH.read_text(encoding="utf-8")

    def test_app_tools_are_explicitly_serialized(self):
        required_phrases = (
            "Call at most one of `read_thread`, `list_threads`, `list_archived_threads`, `list_projects`, `send_message_to_thread`, `fork_thread`, `set_thread_title`, `create_thread`, or `set_thread_archived` at a time",
            "Never put these calls in `Promise.all`, parallel JavaScript, multi-agent work, or any other parallel wrapper",
            "If the host exposes them through `functions.exec`, invoke exactly one App tool inside the wrapper",
            "Do not issue another App call or start a retry while the previous call is pending",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_app_tool_order_is_documented(self):
        self.assertIn(
            "For a registry-owned target use local registry validation → one `send_message_to_thread` call. Use `read_thread` only in the recovery/discovery path after a direct delivery explicitly reports a missing or stale ID. After a successful delivery, a separate serialized `list_threads` cleanup pass may identify stale dispatcher tasks; never use that pass to validate or rediscover the weekly target. For discovery use `list_threads` → `list_archived_threads` →, only when creating, `list_projects` → fixed-template `fork_thread` → registry update (setupState=pending) → `set_thread_title` → registry update (setupState=ready) → one `send_message_to_thread` → cleanup calls → `set_thread_archived`",
            self.prompt,
        )

    def test_registry_route_bypasses_hanging_thread_read(self):
        self.assertIn(
            "If the current week's entry exists and passes the local schema/week/title/host/thread-ID checks, call `send_message_to_thread` directly with that stable ID",
            self.prompt,
        )
        self.assertIn(
            "Do not call `read_thread` in this routine path",
            self.prompt,
        )
        self.assertIn(
            "if it returns no result, stop and leave the dispatcher visible",
            self.prompt,
        )
        self.assertIn(
            "If the registry entry is absent or `send_message_to_thread` explicitly reports that the ID no longer exists",
            self.prompt,
        )

    def test_missing_app_tool_catalog_has_scoped_queue_fallback(self):
        required_phrases = (
            "The Codex App tool catalog can be temporarily absent in a background run",
            "use the local session queue exactly once as an alternate delivery operation",
            "/Applications/ChatGPT.app/Contents/Resources/codex queue --thread <validated-thread-id> --message <complete-triage-prompt>",
            "Treat a successful exit (`exit code 0`) as delivery accepted",
            "do not also call `send_message_to_thread` for that slot",
            "This fallback cannot discover, create, register, rename, or archive other tasks",
            "If the current week's registry entry is valid but the App tool catalog has no `send_message_to_thread` tool at all",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_successful_delivery_cleans_only_stale_dispatchers(self):
        required_phrases = (
            "After a successful delivery, a separate serialized `list_threads` cleanup pass may identify stale dispatcher tasks",
            "Once delivery to the weekly task succeeds (including the first delivery to a newly forked week), make one serialized `list_threads` cleanup pass when that tool is available",
            "title exactly `Apple 邮件周对话分发器`",
            "status exactly `idle`",
            "a literal `Automation ID: apple` marker in the summary",
            "updatedAt` earlier than this dispatcher's actual start time",
            "Do not archive the current dispatcher, active tasks, records with missing/mismatched metadata, index-only IDs, or any manual discussion",
            "if the list or a stale-task archive call has no result or an explicit error, stop only the stale cleanup without retrying",
            "A deferred stale cleanup must not prevent the independent self-archive attempt in step 7",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_failure_boundary_preserves_dispatcher(self):
        self.assertIn("A delivery call with no result still stops the dispatcher and leaves it visible", self.prompt)
        self.assertIn("Never fall back to triaging mail here.", self.prompt)

    def test_cleanup_failure_does_not_block_self_archive(self):
        required_phrases = (
            "After delivery has already been accepted, a cleanup/listing call with no result must not block one independent attempt to archive the current dispatcher itself",
            "Before discovery or creation, perform a read-only exact-title collision check",
            "After a delivery is already accepted, historical same-title index records alone are not a cleanup collision",
            "attempt exactly one independent `set_thread_archived({archived:true})` call with no thread ID",
            "even when stale-dispatcher cleanup was deferred or stopped on a collision",
            "A delivery or managed-week registration failure still keeps the dispatcher visible",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_fixed_template_preserves_weekly_isolation(self):
        for phrase in (
            'Always fork this fixed minimal template',
            'Keep the template archived between runs',
            'Never issue that call while fork is pending',
            'A template-hiding failure must not cause another fork',
            "never fork the dispatcher, last week's task, or the current weekly report",
            'Do not call `create_thread` for weekly creation',
            'synchronization.status=complete',
            'setupState=pending before calling `set_thread_title`',
            'Only after naming succeeds, atomically set setupState=ready',
            'send the complete triage prompt exactly once',
            'must never enter the routine delivery or CLI queue fallback',
            'exclude its ID from every archive/cleanup operation',
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_weekly_target_outputs_directly(self):
        self.assertIn("The target task is already the weekly conversation", self.prompt)
        self.assertIn("never call send_message_to_thread, create_thread, set_thread_archived", self.prompt)

    def test_exact_title_collision_guard_blocks_false_creation(self):
        required_phrases = (
            "read-only exact-title collision check",
            "session index",
            "index is append-only",
            "use only its latest JSON record",
            "If a current exact managed title is present in the index but is absent from the App listings",
            "Do not create, send, rename, archive, or infer ownership of an unknown task",
            "neither the App listings nor the collision check contains the exact title",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)


if __name__ == "__main__":
    unittest.main()
