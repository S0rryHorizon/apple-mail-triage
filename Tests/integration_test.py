"""Run service/storage integration tests with injected accounts, without Apple Mail access.

The production executable deliberately has no environment override for account validation.
"""
import subprocess
import unittest
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]

class StateIntegrationTests(unittest.TestCase):
    def test_swift_service_and_storage(self):
        result = subprocess.run(["swift", "run", "MailBridgeSyntheticTests"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
