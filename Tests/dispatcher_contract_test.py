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
            "Call at most one of `list_threads`, `list_archived_threads`, `list_projects`, `send_message_to_thread`, `create_thread`, or `set_thread_archived` at a time",
            "Never put these calls in `Promise.all`, parallel JavaScript, multi-agent work, or any other parallel wrapper",
            "If the host exposes them through `functions.exec`, invoke exactly one App tool inside the wrapper",
            "Do not issue another App call or start a retry while the previous call is pending",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, self.prompt)

    def test_app_tool_order_is_documented(self):
        self.assertIn(
            "`list_threads` → `list_archived_threads` →, only when creating, `list_projects` → one delivery call → fresh sequential cleanup listings → cleanup calls → `set_thread_archived`",
            self.prompt,
        )

    def test_failure_boundary_preserves_dispatcher(self):
        self.assertIn("stop the dispatcher, leave it visible, and report the failed stage", self.prompt)
        self.assertIn("Never fall back to triaging mail here.", self.prompt)


if __name__ == "__main__":
    unittest.main()
