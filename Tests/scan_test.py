"""Synthetic scan/AppleScript contract tests; never access the user's mailbox."""
import pathlib
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def setUpModule():
    subprocess.run(["swift", "build"], cwd=ROOT, check=True, capture_output=True)


class ScanTests(unittest.TestCase):
    def test_scan_regressions(self):
        with tempfile.TemporaryDirectory() as temp:
            main = pathlib.Path(temp) / "main.swift"
            shutil.copyfile(ROOT / "Tests/ScanRegression.swift", main)
            binary = pathlib.Path(temp) / "ScanTests"
            sources = [ROOT / "Sources/MailBridgeRuntime" / name for name in
                       ["StateStore.swift", "MailAutomation.swift", "MailBridgeService.swift"]]
            core = pathlib.Path(temp) / "MailBridgeCore.o"
            core_command = ["swiftc", "-parse-as-library", "-emit-module", "-emit-object",
                            "-whole-module-optimization", "-module-name", "MailBridgeCore",
                            "-emit-module-path", str(pathlib.Path(temp) / "MailBridgeCore.swiftmodule"),
                            *map(str, (ROOT / "Sources/MailBridgeCore").glob("*.swift")), "-o", str(core)]
            compiled = subprocess.run(core_command, cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            command = ["swiftc", "-package-name", "MailBridge", "-I", temp, *map(str, sources), str(main), str(core), "-lsqlite3", "-o", str(binary)]
            compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


class LockTests(unittest.TestCase):
    mutation = {"action": "rule.upsert", "confirmed": True,
                "rule": {"field": "subject", "pattern": "synthetic-lock", "category": "information"}}
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, MAIL_TRIAGE_STATE_DIR=self.temp.name)
        self.binary = ROOT / ".build/debug/MailBridge"
        self.call({"action": "state.status"})
        self.db = sqlite3.connect(pathlib.Path(self.temp.name) / "state.sqlite")

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def call(self, payload):
        result = subprocess.run([str(self.binary)], input=json.dumps(payload), text=True,
                                capture_output=True, env=self.env, timeout=12)
        return result.returncode, json.loads(result.stdout)

    def test_brief_writer_lock_waits_and_commits_once(self):
        self.db.execute("BEGIN IMMEDIATE")
        with subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=self.env) as process:
            process.stdin.write(json.dumps(self.mutation))
            process.stdin.close()
            process.stdin = None
            time.sleep(0.25)
            self.assertIsNone(process.poll(), "Bridge failed immediately on a transient lock")
            self.db.commit()
            output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, error + output)
        self.assertEqual(len(json.loads(output)["rules"]), 1)

    def test_persistent_writer_lock_fails_with_unchanged_state(self):
        self.db.execute("BEGIN IMMEDIATE")
        started = time.monotonic()
        code, response = self.call(self.mutation)
        elapsed = time.monotonic() - started
        self.assertNotEqual(code, 0)
        self.assertFalse(response["ok"])
        self.assertIn("locked", response["message"])
        self.assertGreaterEqual(elapsed, 4)
        self.assertLess(elapsed, 9)
        self.db.rollback()
        self.assertEqual(self.call({"action": "state.status"})[1]["state"]["shadowRunsCompleted"], 0)
        self.assertEqual(self.call({"action": "rule.list"})[1]["rules"], [])

    def test_status_does_not_request_a_writer_lock_for_existing_defaults(self):
        self.db.execute("BEGIN IMMEDIATE")
        started = time.monotonic()
        code, response = self.call({"action": "state.status"})
        self.assertEqual(code, 0)
        self.assertTrue(response["ok"])
        self.assertLess(time.monotonic() - started, 2)
        self.db.rollback()


if __name__ == "__main__":
    unittest.main()
