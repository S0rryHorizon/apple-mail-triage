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
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def setUpModule():
    subprocess.run(["swift", "build"], cwd=ROOT, check=True, capture_output=True)


class ScanTests(unittest.TestCase):
    def test_scan_regressions(self):
        with tempfile.TemporaryDirectory() as temp:
            fixtures = pathlib.Path(temp) / "attachments"
            fixtures.mkdir()
            self.make_attachments(fixtures)
            main = pathlib.Path(temp) / "main.swift"
            shutil.copyfile(ROOT / "Tests/ScanRegression.swift", main)
            binary = pathlib.Path(temp) / "ScanTests"
            sources = sorted((ROOT / "Sources/MailBridgeRuntime").glob("*.swift"))
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
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120,
                                    env=dict(os.environ, MAIL_TRIAGE_TEST_FIXTURES=str(fixtures)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())

    @staticmethod
    def make_attachments(directory):
        # Minimal real document formats; synthetic content only, no live mailbox fixtures.
        def package(name, files):
            with zipfile.ZipFile(directory / name, "w", zipfile.ZIP_DEFLATED) as archive:
                for path, value in files.items():
                    archive.writestr(path, value)
        relationships = 'http://schemas.openxmlformats.org/package/2006/relationships'
        office = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
        def rel(kind, target):
            return f'<Relationships xmlns="{relationships}"><Relationship Id="rId1" Type="{office}/{kind}" Target="{target}"/></Relationships>'
        def content_type(part, value):
            return ('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                    '<Default Extension="xml" ContentType="application/xml"/>'
                    f'<Override PartName="/{part}" ContentType="{value}"/></Types>')
        package("synthetic.docx", {
            "[Content_Types].xml": content_type("word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
            "_rels/.rels": rel("officeDocument", "word/document.xml"),
            "word/document.xml": '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Synthetic Word content</w:t></w:r></w:p></w:body></w:document>'})
        sheet_ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
        package("synthetic.xlsx", {
            "[Content_Types].xml": content_type("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
            "_rels/.rels": rel("officeDocument", "xl/workbook.xml"),
            "xl/_rels/workbook.xml.rels": rel("worksheet", "worksheets/sheet1.xml"),
            "xl/workbook.xml": f'<workbook xmlns="{sheet_ns}" xmlns:r="{office}"><sheets><sheet name="Synthetic" sheetId="1" r:id="rId1"/></sheets></workbook>',
            "xl/worksheets/sheet1.xml": f'<worksheet xmlns="{sheet_ns}"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Synthetic Excel content</t></is></c></row><row r="2"><c r="A2"><v>42</v></c></row></sheetData></worksheet>'})
        stream = b'BT /F1 12 Tf 72 720 Td (Synthetic PDF content) Tj ET'
        objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                   b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
                   b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
                   b'<< /Length %d >>\nstream\n' % len(stream) + stream + b'\nendstream']
        pdf, offsets = b'%PDF-1.4\n', [0]
        for number, obj in enumerate(objects, 1):
            offsets.append(len(pdf))
            pdf += str(number).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
        xref = len(pdf)
        pdf += b'xref\n0 6\n0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % offset for offset in offsets[1:])
        pdf += b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % xref
        (directory / "synthetic.pdf").write_bytes(pdf)


class LockTests(unittest.TestCase):
    mutation = {"action": "rule.upsert", "confirmed": True,
                "rule": {"field": "subject", "pattern": "synthetic-lock", "category": "information"}}
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, MAIL_TRIAGE_STATE_DIR=self.temp.name)
        build = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True,
                               capture_output=True, text=True).stdout.strip()
        self.binary = pathlib.Path(build) / "MailBridge"
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
        self.assertEqual(self.call({"action": "state.status"})[1]["state"]["processedCount"], 0)
        self.assertEqual(self.call({"action": "rule.list"})[1]["rules"], [])

    def test_status_does_not_request_a_writer_lock_for_existing_defaults(self):
        self.db.execute("BEGIN IMMEDIATE")
        started = time.monotonic()
        code, response = self.call({"action": "state.status"})
        self.assertEqual(code, 0)
        self.assertTrue(response["ok"])
        self.assertLess(time.monotonic() - started, 2)
        self.db.rollback()

    def test_error_codes_distinguish_validation_from_operational_failure(self):
        code, response = self.call({"action": "attachment.export"})
        self.assertNotEqual(code, 0)
        self.assertEqual(response["errorCode"], "request_validation")
        code, response = self.call({"action": "candidate.resolve"})
        self.assertNotEqual(code, 0)
        self.assertEqual(response["errorCode"], "confirmation_required")

    def test_retired_flag_state_is_unused_and_preserved(self):
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertFalse(tables & {"settings", "flag_batches", "flag_operations"})
        # Legacy data can remain in an upgraded database without enabling flags.
        self.db.executescript("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT);"
                             "INSERT INTO settings VALUES('flagging_enabled','true');"
                             "CREATE TABLE flag_batches(id TEXT PRIMARY KEY);"
                             "INSERT INTO flag_batches VALUES('legacy');")
        response = self.call({"action": "state.status"})[1]
        self.assertNotIn("flaggingEnabled", response["state"])
        self.assertNotIn("shadowRunsCompleted", response["state"])
        for action in ("flag.preview", "flag.commit", "flag.rollback"):
            self.assertFalse(self.call({"action": action, "confirmed": True})[1]["ok"])
        self.assertEqual(self.db.execute("SELECT * FROM settings").fetchall(), [("flagging_enabled", "true")])
        self.assertEqual(self.db.execute("SELECT * FROM flag_batches").fetchall(), [("legacy",)])


if __name__ == "__main__":
    unittest.main()
