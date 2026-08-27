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
            "Call at most one of `read_thread`, `list_threads`, `list_archived_threads`, `list_projects`, `send_message_to_thread`, `create_thread`, or `set_thread_archived` at a time",
            "Never put these calls in `Promise.all`, parallel JavaScript, multi-agent work, or any other parallel wrapper",
            "If the host exposes them through `functions.exec`, invoke exactly one App tool inside the wrapper",
            "Do not issue another App call or start a retry while the previous call is pending",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_app_tool_order_is_documented(self):
        self.assertIn(
            "For a registry-owned target use local registry validation → one `send_message_to_thread` call. Use `read_thread` only in the recovery/discovery path after a direct delivery explicitly reports a missing or stale ID. For discovery use `list_threads` → `list_archived_threads` →, only when creating, `list_projects` → `create_thread` with the complete triage prompt → registry update → cleanup calls → `set_thread_archived`",
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

    def test_failure_boundary_preserves_dispatcher(self):
        self.assertIn("stop the dispatcher, leave it visible, and report the failed stage", self.prompt)
        self.assertIn("Never fall back to triaging mail here.", self.prompt)

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
