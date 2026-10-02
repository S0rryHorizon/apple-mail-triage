"""Run service/storage integration tests with injected accounts, without Apple Mail access.

The production executable deliberately has no environment override for account validation.
"""
import pathlib
import subprocess
import unittest
import tempfile
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]

class StateIntegrationTests(unittest.TestCase):
    def test_swift_service_and_storage(self):
        with tempfile.TemporaryDirectory() as temp:
            main = pathlib.Path(temp) / "main.swift"
            shutil.copyfile(ROOT / "Tests/Swift/MailBridgeTests.swift", main)
            binary = pathlib.Path(temp) / "StateTests"
            sources = [ROOT / "Sources/MailBridge" / name for name in
                       ["StateStore.swift", "MailAutomation.swift", "MailBridgeService.swift"]]
            core = pathlib.Path(temp) / "MailBridgeCore.o"
            core_command = ["swiftc", "-parse-as-library", "-emit-module", "-emit-object",
                            "-whole-module-optimization", "-module-name", "MailBridgeCore",
                            "-emit-module-path", str(pathlib.Path(temp) / "MailBridgeCore.swiftmodule"),
                            *map(str, (ROOT / "Sources/MailBridgeCore").glob("*.swift")), "-o", str(core)]
            compiled = subprocess.run(core_command, cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            command = ["swiftc", "-I", temp, *map(str, sources), str(main), str(core), "-lsqlite3", "-o", str(binary)]
            compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
