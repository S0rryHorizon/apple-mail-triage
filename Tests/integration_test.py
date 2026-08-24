import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build" / "debug" / "MailBridge"


def request(payload, state_dir):
    env = os.environ.copy()
    env["MAIL_TRIAGE_STATE_DIR"] = state_dir
    result = subprocess.run(
        [str(BINARY)],
        input=json.dumps(payload, ensure_ascii=False),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    return result.returncode, json.loads(result.stdout)


class StateIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp.cleanup()

    def test_state_candidate_rule_and_flag_gate(self):
        code, initial = request({"action": "state.status"}, self.temp.name)
        self.assertEqual(code, 0)
        self.assertFalse(initial["state"]["flaggingEnabled"])

        update = {
            "action": "state.record",
            "state": {
                "processed": [{
                    "ref": {"accountId": "account-a", "libraryId": 7},
                    "fingerprint": "f" * 64,
                    "receivedAt": "2026-08-19T08:00:00.000Z",
                    "category": "action",
                    "candidateId": "T-20260819-FFFFFFFF",
                }],
                "candidates": [{
                    "id": "T-20260819-FFFFFFFF",
                    "kind": "reminder",
                    "title": "提交报告",
                    "accountId": "account-a",
                    "libraryId": 7,
                    "sourceSubject": "Please submit",
                }],
                "cursors": [{
                    "accountId": "account-a",
                    "receivedAt": "2026-08-19T08:00:00.000Z",
                }],
                "shadowRunsCompleted": 1,
            },
        }
        code, recorded = request(update, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(recorded["state"]["processedCount"], 1)
        self.assertEqual(recorded["state"]["pendingCandidateCount"], 1)

        code, pending = request({"action": "state.pending"}, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(pending["candidates"][0]["id"], "T-20260819-FFFFFFFF")

        code, rejected = request(
            {"action": "state.record", "state": {"flaggingEnabled": True}}, self.temp.name)
        self.assertNotEqual(code, 0)
        self.assertIn("confirmed", rejected["message"])

        code, enabled = request(
            {"action": "state.record", "confirmed": True, "state": {"flaggingEnabled": True}},
            self.temp.name,
        )
        self.assertEqual(code, 0)
        self.assertTrue(enabled["state"]["flaggingEnabled"])

        code, rule = request({
            "action": "rule.upsert",
            "confirmed": True,
            "rule": {"field": "domain", "pattern": "example.edu", "category": "information"},
        }, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(rule["rules"][0]["pattern"], "example.edu")

    def test_cursor_never_moves_backwards(self):
        code, _ = request({
            "action": "state.record",
            "state": {"cursors": [{
                "accountId": "account-a",
                "receivedAt": "2026-08-20T08:00:00.000Z",
            }]},
        }, self.temp.name)
        self.assertEqual(code, 0)

        code, state = request({
            "action": "state.record",
            "state": {"cursors": [{
                "accountId": "account-a",
                "receivedAt": "2026-08-19T08:00:00.000Z",
            }]},
        }, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(
            state["state"]["cursors"][0]["receivedAt"],
            "2026-08-20T08:00:00.000Z",
        )

    def test_missing_due_date_remains_missing_and_resolution_requires_confirmation(self):
        candidate = {
            "id": "T-20260819-AAAAAAAA",
            "kind": "reminder",
            "title": "补充日期后处理",
            "accountId": "account-a",
            "libraryId": 8,
            "sourceSubject": "Action without a date",
        }
        code, _ = request({
            "action": "state.record",
            "state": {"candidates": [candidate]},
        }, self.temp.name)
        self.assertEqual(code, 0)

        code, pending = request({"action": "state.pending"}, self.temp.name)
        self.assertEqual(code, 0)
        self.assertNotIn("due", pending["candidates"][0])

        code, rejected = request({
            "action": "candidate.resolve",
            "candidateIds": [candidate["id"]],
            "candidateStatus": "dismissed",
        }, self.temp.name)
        self.assertNotEqual(code, 0)
        self.assertIn("confirmed", rejected["message"])

        code, resolved = request({
            "action": "candidate.resolve",
            "confirmed": True,
            "candidateIds": [candidate["id"]],
            "candidateStatus": "dismissed",
        }, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(resolved["candidates"], [])

    def test_duplicate_fingerprint_is_rejected_without_partial_state(self):
        def processed(account, library_id):
            return {
                "ref": {"accountId": account, "libraryId": library_id},
                "fingerprint": "d" * 64,
                "receivedAt": "2026-08-19T08:00:00.000Z",
                "category": "information",
            }

        code, _ = request({
            "action": "state.record",
            "state": {"processed": [processed("account-a", 1)]},
        }, self.temp.name)
        self.assertEqual(code, 0)

        code, duplicate = request({
            "action": "state.record",
            "state": {
                "processed": [processed("account-b", 2)],
                "cursors": [{
                    "accountId": "account-b",
                    "receivedAt": "2026-08-20T08:00:00.000Z",
                }],
            },
        }, self.temp.name)
        self.assertNotEqual(code, 0)
        self.assertFalse(duplicate["ok"])

        code, state = request({"action": "state.status"}, self.temp.name)
        self.assertEqual(code, 0)
        self.assertEqual(state["state"]["processedCount"], 1)
        self.assertEqual(state["state"]["cursors"], [])

    def test_long_term_rule_requires_confirmation(self):
        payload = {
            "action": "rule.upsert",
            "rule": {
                "field": "domain",
                "pattern": "example.test",
                "category": "noise",
            },
        }
        code, rejected = request(payload, self.temp.name)
        self.assertNotEqual(code, 0)
        self.assertIn("confirmed", rejected["message"])


if __name__ == "__main__":
    unittest.main()
