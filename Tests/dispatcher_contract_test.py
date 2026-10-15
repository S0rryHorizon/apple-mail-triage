"""Synthetic dispatch/recovery behavior tests; no Mail or live Codex access."""
import concurrent.futures, importlib.util, json, os, subprocess, tempfile, unittest, uuid
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime", ROOT / "automation/runtime.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def uid():
    return str(uuid.uuid4())

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.directory = self.base / "apple"
        self.directory.mkdir()
        self.settings = self.base / "settings.json"
        self.settings.write_text((ROOT / "automation/settings.json").read_text())
        (self.directory / "automation.toml").write_text('status = "ACTIVE"\n')
        self.project, self.dispatcher, self.worker, self.repairer = [uid() for _ in range(4)]
        self.registry = {"schemaVersion": 1, "automationId": "apple", "projectId": self.project,
                         "hostId": "local", "templateThreadId": uid(), "managedThreads": {}}
        self.runtime = module.Runtime(self.directory, self.settings)
        module.atomic_json(self.runtime.registry_path, self.registry)
        self.call("initialize")

    def call(self, action, **args):
        return self.runtime.handle({"action": action, "thread_id": self.dispatcher, **args})

    def plan(self):
        return self.call("dispatch.plan", now="2026-09-25T10:00:00+08:00")

    def start(self):
        plan = self.plan()
        self.run_id = plan["run_id"]
        self.call("triage.begin", run_id=self.run_id, thread_id=self.worker)
        return plan

    def incident(self, owner=None, stage="scan"):
        result = self.call("incident.open", run_id=self.run_id, thread_id=owner or self.worker,
                           stage=stage, error_code="synthetic_failure", outcome="failed")
        self.incident_id = result["incident"]["id"]
        return result

    def prepare(self):
        self.incident()
        result = self.call("repair.prepare", incident_id=self.incident_id)
        self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer)
        return result

    def bridge(self, payload, response=None, code=0, error=None):
        completed = subprocess.CompletedProcess(["synthetic-bridge"], code,
            json.dumps(response) if isinstance(response, dict) else response or "", "")
        with patch.object(module.subprocess, "run", return_value=completed, side_effect=error) as execute:
            result = self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request=payload)
        return result, execute

    def bridge_page(self, more=False, **payload):
        return self.bridge({"action": "message.scan", **payload}, {
            "ok": True, "status": "ok", "messages": [], "details": {
                "since": "2026-09-24T00:00:00Z", "until": "2026-09-25T00:00:00Z",
                "hasMore": "true" if more else "false", "nextOffset": "2" if more else "3"}})

    def test_bridge_error_json_closes_run_and_opens_one_incident(self):
        self.start()
        result, execute = self.bridge({"action": "message.scan"}, {
            "ok": False, "errorCode": "mail_automation_failure", "message": "private body: result unknown"}, code=1)
        self.assertEqual((result["outcome"], result["run_phase"]), ("failed", "failed"))
        self.assertEqual(result["error_code"], "mail_automation_failure")
        self.assertTrue(result["recovery"]["repair"])
        self.assertEqual(execute.call_count, 1)
        self.assertNotIn("private body", self.runtime.state_path.read_text())
        retry, execute = self.bridge({"action": "message.scan"})
        self.assertEqual(retry["outcome"], "not_run")
        execute.assert_not_called()

    def test_bridge_timeout_is_terminal_unknown_without_replay(self):
        self.start()
        result, execute = self.bridge({"action": "message.scan"}, error=subprocess.TimeoutExpired("bridge", 90, output="private"))
        self.assertEqual((result["outcome"], result["run_phase"]), ("unknown", "unknown"))
        self.assertEqual(self.runtime.state()["incidents"], {})
        self.assertEqual(execute.call_count, 1)
        self.assertNotIn("private", self.runtime.state_path.read_text())

    def test_failure_diagnostics_are_retained_without_private_error_text(self):
        self.start()
        result, _ = self.bridge({"action": "message.scan"}, {
            "ok": False, "errorCode": "mail_automation_failure", "message": "private mail",
            "details": {"operation": "metadata", "reason": "apple_script_error",
                        "apple_error_number": "-1728", "elapsed_ms": "1200",
                        "subject": "private mail"}}, code=1)
        saved = self.runtime.state()["runs"][self.run_id]["last_bridge"]["diagnostics"]
        self.assertEqual(saved, result["diagnostics"])
        self.assertEqual(saved["apple_error_number"], "-1728")
        incident_id = result["recovery"]["incident"]["id"]
        self.call("repair.prepare", incident_id=incident_id)
        self.call("repair.attach", incident_id=incident_id, thread_id=self.repairer)
        self.call("repair.retry", incident_id=incident_id)
        self.assertEqual(self.call("repair.get", incident_id=incident_id)["incident"]["diagnostics"], saved)
        self.assertNotIn("private", self.runtime.state_path.read_text())
        malformed = module.bridge_result(1, json.dumps({"ok": False,
            "errorCode": "mail_automation_failure", "details": {
                "operation": "private mail", "reason": ["private"],
                "elapsed_ms": "private", "apple_error_number": {"private": 1}}}))
        self.assertNotIn("diagnostics", malformed)

    def timeout_response(self, reason="apple_event_timeout"):
        return subprocess.CompletedProcess(["synthetic-bridge"], 1, json.dumps({
            "ok": False, "errorCode": "mail_automation_failure", "message": "private mail",
            "details": {"operation": "metadata", "reason": reason, "apple_error_number": "-1712"}}), "")

    def test_mail_timeout_on_read_retries_once_in_place(self):
        self.start()
        page = subprocess.CompletedProcess(["synthetic-bridge"], 0, json.dumps({
            "ok": True, "status": "ok", "messages": [], "details": {
                "since": "2026-09-24T00:00:00Z", "until": "2026-09-25T00:00:00Z",
                "hasMore": "false", "nextOffset": "0"}}), "")
        with patch.object(module.subprocess, "run", side_effect=[self.timeout_response(), page]) as execute, \
                patch.object(module.time, "sleep") as pause:
            result = self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request={"action": "message.scan"})
        self.assertEqual((result["outcome"], result["run_phase"]), ("succeeded", "running"))
        self.assertEqual(execute.call_count, 2)
        pause.assert_called_once()
        self.assertTrue(self.runtime.state()["runs"][self.run_id]["scan"]["complete"])
        self.assertEqual(self.runtime.state()["incidents"], {})

    def test_repeated_mail_timeout_waits_for_next_slot_without_repair(self):
        self.start()
        with patch.object(module.subprocess, "run", side_effect=[self.timeout_response(), self.timeout_response("scan_deadline")]) as execute, \
                patch.object(module.time, "sleep"):
            result = self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request={"action": "message.scan"})
        self.assertEqual(execute.call_count, 2)
        self.assertEqual((result["outcome"], result["error_code"], result["run_phase"]), ("failed", "mail_timeout", "blocked"))
        self.assertEqual(result["recovery"], {"repair": False, "reason": "transient_mail_timeout"})
        saved = self.runtime.state()["runs"][self.run_id]["last_bridge"]
        self.assertEqual((saved["error_code"], saved["timeout_retried"], saved["diagnostics"]["reason"]),
                         ("mail_timeout", True, "scan_deadline"))
        self.assertEqual(self.runtime.state()["incidents"], {})
        self.assertNotIn("private", self.runtime.state_path.read_text())

    def test_non_timeout_and_write_failures_are_not_retried(self):
        for payload in ({"action": "message.scan"}, {"action": "attachment.export"}):
            with self.subTest(action=payload["action"]):
                self.setUp()
                self.start()
                response = self.timeout_response() if payload["action"] != "message.scan" else \
                    self.timeout_response("apple_script_error")
                with patch.object(module.subprocess, "run", return_value=response) as execute, \
                        patch.object(module.time, "sleep") as pause:
                    result = self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request=payload)
                self.assertEqual(execute.call_count, 1)
                pause.assert_not_called()
                self.assertEqual(result["error_code"], "mail_automation_failure")

    def test_state_record_closes_frozen_window(self):
        self.start()
        self.bridge_page()
        _, execute = self.bridge({"action": "state.record", "state": {"processed": [], "windowUntil": "2030-01-01T00:00:00Z"}},
            {"ok": True, "status": "recorded", "state": {"deferredBodyCount": 0}})
        sent = json.loads(execute.call_args.kwargs["input"])
        self.assertEqual(sent["state"]["windowUntil"], "2026-09-25T00:00:00Z")

    def test_bridge_malformed_output_never_counts_as_success(self):
        for code in (0, 1):
            self.start()
            result, _ = self.bridge({"action": "message.scan"}, "not JSON", code=code)
            self.assertEqual(result["outcome"], "unknown" if code == 0 else "failed")
            # A separate run fixture for the next process outcome.
            self.setUp()

    def test_bridge_record_automatically_finishes_full_and_partial_runs(self):
        for count in (0, 2):
            self.start()
            self.bridge_page()
            result, _ = self.bridge({"action": "state.record", "state": {}}, {
                "ok": True, "status": "recorded", "state": {"deferredBodyCount": count}})
            self.assertEqual(result["run_phase"], "partial" if count else "recorded")
            self.assertIn("ended_at", self.runtime.state()["runs"][self.run_id])
            again, execute = self.bridge({"action": "state.record", "state": {}})
            self.assertEqual(again["outcome"], "not_run")
            execute.assert_not_called()
            self.setUp()

    def test_bridge_unknown_write_result_cannot_be_retried(self):
        self.start()
        self.bridge_page()
        result, _ = self.bridge({"action": "state.record", "state": {}}, "truncated JSON", code=1)
        self.assertEqual(result["run_phase"], "unknown")
        self.assertEqual(self.runtime.state()["incidents"], {})

    def test_bridge_validation_can_be_corrected_without_rescanning(self):
        self.start()
        self.bridge_page()
        result, _ = self.bridge({"action": "state.record", "state": {}}, {
            "ok": False, "errorCode": "request_validation"}, code=1)
        self.assertEqual(result["run_phase"], "blocked")
        self.assertFalse(result["recovery"]["repair"])
        result, _ = self.bridge({"action": "state.record", "state": {}}, {
            "ok": True, "status": "recorded", "state": {"deferredBodyCount": 0}})
        self.assertEqual(result["run_phase"], "recorded")

    def test_bridge_requires_complete_frozen_pagination(self):
        self.start()
        self.bridge_page(more=True, limit=2)
        with patch.object(module.subprocess, "run") as execute:
            with self.assertRaises(ValueError):
                self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request={"action": "state.record", "state": {}})
            with self.assertRaises(ValueError):
                self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request={"action": "message.scan", "offset": 0})
            execute.assert_not_called()
        result, execute = self.bridge_page()
        sent = json.loads(execute.call_args.kwargs["input"])
        self.assertEqual((sent["offset"], sent["limit"]), (2, 2))
        self.assertEqual(sent["since"], "2026-09-24T00:00:00Z")
        self.assertTrue(self.runtime.state()["runs"][self.run_id]["scan"]["complete"])

    def test_bridge_invalid_page_and_save_receipts_close_unknown(self):
        self.start()
        result, _ = self.bridge({"action": "message.scan"}, {"ok": True, "details": None})
        self.assertEqual(result["run_phase"], "unknown")
        self.setUp()
        self.start()
        self.bridge_page()
        result, _ = self.bridge({"action": "state.record", "state": {}}, {"ok": True, "status": "recorded", "state": None})
        self.assertEqual(result["run_phase"], "unknown")

    def test_bridge_cli_exposes_handled_failure_as_complete_json(self):
        self.start()
        executable = self.base / "fake-bridge"
        executable.write_text('#!/usr/bin/env python3\nimport json,sys\njson.load(sys.stdin)\nprint(json.dumps({"ok":False,"errorCode":"mail_automation_failure"}))\nsys.exit(1)\n')
        executable.chmod(0o700)
        env = dict(os.environ, MAILBRIDGE_PATH=str(executable), MAIL_TRIAGE_AUTOMATION_DIR=str(self.directory),
                   MAIL_TRIAGE_SETTINGS_PATH=str(self.settings), CODEX_THREAD_ID=self.worker)
        result = subprocess.run(["python3", str(ROOT / "automation/runtime.py")], env=env,
            input=json.dumps({"action": "bridge.call", "run_id": self.run_id, "request": {"action": "message.scan"}}),
            text=True, capture_output=True, check=True)
        response = json.loads(result.stdout)
        self.assertTrue(response["ok"])
        self.assertEqual((response["outcome"], response["run_phase"]), ("failed", "failed"))

    def test_bridge_paused_or_wrong_owner_does_not_execute(self):
        self.start()
        with patch.object(module.subprocess, "run") as execute:
            with self.assertRaises(ValueError):
                self.call("bridge.call", run_id=self.run_id, request={"action": "message.scan"})
            (self.directory / "automation.toml").write_text('status = "PAUSED"\n')
            result = self.call("bridge.call", run_id=self.run_id, thread_id=self.worker, request={"action": "message.scan"})
            self.assertEqual(result["reason"], "paused")
            execute.assert_not_called()

    def test_explicit_manual_repair_keeps_existing_chats_and_clears_old_page(self):
        self.start()
        self.bridge_page()
        self.incident()
        self.call("repair.prepare", incident_id=self.incident_id)
        with self.assertRaises(ValueError):
            self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer, manual=True)
        self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer, manual=True, confirmed=True)
        result = self.call("repair.retry", incident_id=self.incident_id)
        self.assertTrue(result["retry"])
        self.assertEqual(result["thread_id"], self.worker)
        self.assertNotIn("scan", self.runtime.state()["runs"][self.run_id])
        self.call("triage.begin", run_id=self.run_id, thread_id=self.worker)
        self.bridge_page()
        self.bridge({"action": "state.record", "state": {}}, {
            "ok": True, "status": "recorded", "state": {"deferredBodyCount": 0}})
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [])
        self.assertNotIn("repair_archive_pending", self.runtime.state()["incidents"][self.incident_id])

    def test_manual_takeover_of_failed_repair_preserves_one_retry(self):
        self.start()
        self.prepare()
        self.call("repair.finish", incident_id=self.incident_id, success=False)
        new_owner = uid()
        with self.assertRaises(ValueError):
            self.call("repair.attach", incident_id=self.incident_id, thread_id=new_owner, manual=True)
        result = self.call("repair.attach", incident_id=self.incident_id,
                           thread_id=new_owner, manual=True, confirmed=True)
        self.assertEqual(result["previous_repair_thread_id"], self.repairer)
        self.assertEqual(result["repair_thread_id"], new_owner)
        self.assertEqual(result["attempts"], 1)
        self.assertIn(self.repairer, module.known_threads(self.runtime.state(), self.runtime.registry()))
        self.assertTrue(self.call("repair.retry", incident_id=self.incident_id)["retry"])
        self.call("repair.finish", incident_id=self.incident_id, success=False)
        with self.assertRaises(ValueError):
            self.call("repair.attach", incident_id=self.incident_id,
                      thread_id=uid(), manual=True, confirmed=True)

    def test_manual_takeover_rejects_paused_unknown_and_resolved(self):
        for boundary in ("paused", "unknown", "resolved"):
            with self.subTest(boundary=boundary):
                self.setUp()
                self.start()
                self.prepare()
                self.call("repair.finish", incident_id=self.incident_id, success=False)
                state = self.runtime.state()
                if boundary == "paused":
                    (self.directory / "automation.toml").write_text('status = "PAUSED"\n')
                elif boundary == "unknown":
                    state["runs"][self.run_id]["phase"] = "unknown"
                else:
                    state["incidents"][self.incident_id]["status"] = "resolved"
                self.runtime.save(state)
                with self.assertRaises(ValueError):
                    self.call("repair.attach", incident_id=self.incident_id,
                              thread_id=uid(), manual=True, confirmed=True)

    def cleanup_failure(self):
        self.cleanup_target = uid()
        state = self.runtime.state()
        state["runs"]["apple:2026-09-24T20:00:00+08:00"] = {
            **state["runs"][self.run_id], "dispatcher_id": self.cleanup_target,
            "planned_at": "2026-09-24T20:00:00+08:00",
            "started_at": "2026-09-24T20:01:00+08:00", "phase": "recorded"}
        self.runtime.save(state)
        result = self.call("cleanup.failed", run_id=self.run_id,
                           target_thread_id=self.cleanup_target, outcome="unavailable")
        self.incident_id = result["incident"]["id"]
        return result

    def attach_legacy_cleanup_repair(self):
        # Preserve completion/target validation coverage for repair tasks already
        # launched before cleanup was removed from automatic repair eligibility.
        state = self.runtime.state()
        state["incidents"][self.incident_id].update(status="launching", attempts=1)
        self.runtime.save(state)
        self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer)

    def test_template_fork_and_single_delivery(self):
        plan = self.start()
        self.assertEqual(plan["operation"], "fork")
        self.assertEqual(plan["task"]["fork_args"], {"threadId": self.registry["templateThreadId"], "environment": {"type": "same-directory"}})
        self.assertEqual((plan["model"], plan["thinking"]), ("gpt-5.6-luna", "max"))
        self.call("dispatch.delivered", run_id=self.run_id)
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")
        self.assertFalse(self.call("triage.begin", run_id=self.run_id, thread_id=self.worker)["should_run"])
        self.assertEqual(self.plan()["operation"], "already_registered")
        later = self.call("dispatch.plan", now="2026-09-25T21:00:00+08:00")
        self.assertEqual((later["operation"], later["thread_id"]), ("deliver", self.worker))

    def test_planned_slot_across_year(self):
        plan = self.call("dispatch.plan", now="2027-01-04T02:00:00+08:00")
        self.assertEqual(plan["week"], "2026-W53")
        self.assertIn("2027-01-03T20:00:00+08:00", plan["run_id"])
        delayed = self.call("dispatch.plan", now="2027-01-05T09:00:00+08:00",
                            planned_at="2026-12-27T20:00:00+08:00")
        self.assertEqual(delayed["week"], "2026-W52")

    def test_restarted_dispatcher_is_eligible_for_cleanup_after_new_run(self):
        self.start()
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.call("cleanup.record", target_thread_id=self.dispatcher)
        later = self.call("dispatch.plan", planned_at="2026-09-25T11:15:00+08:00")
        self.assertNotIn(self.dispatcher, self.runtime.state()["archived"])
        self.call("dispatch.delivered", run_id=later["run_id"])
        self.assertIn(self.dispatcher, self.call("cleanup.plan", run_id=later["run_id"],
                                               thread_id=uid())["thread_ids"])

    def test_concurrent_dispatchers_reserve_once(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.plan(), range(4)))
        self.assertEqual(sum(x["operation"] == "fork" for x in results), 1)

    def test_record_requires_saved_state_and_owner(self):
        self.start()
        for args in ({"state_recorded": False, "thread_id": self.worker},
                     {"state_recorded": True, "thread_id": self.dispatcher}):
            with self.assertRaises(ValueError):
                self.call("triage.recorded", run_id=self.run_id, **args)
        result = self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.assertEqual(result["receipt"], module.RECEIPT)

    def test_partial_run_has_no_success_receipt_or_repair_and_dispatches_next_slot(self):
        self.start()
        for count in (0, -1, True):
            with self.assertRaises(ValueError):
                self.call("triage.partial", run_id=self.run_id, thread_id=self.worker,
                          state_recorded=True, deferred_body_count=count)
        result = self.call("triage.partial", run_id=self.run_id, thread_id=self.worker,
                           state_recorded=True, deferred_body_count=1)
        self.assertEqual(result["run"]["phase"], "partial")
        self.assertIsNone(result["receipt"])
        self.assertEqual(self.runtime.state()["incidents"], {})
        self.assertFalse(self.call("triage.begin", run_id=self.run_id, thread_id=self.worker)["should_run"])
        with self.assertRaises(ValueError):
            self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        later = self.call("dispatch.plan", now="2026-09-25T21:00:00+08:00")
        self.assertEqual((later["operation"], later["thread_id"]), ("deliver", self.worker))

    def test_model_configuration_drives_all_roles(self):
        for role in ("triage", "repair", "dispatcher"):
            self.call("config.set", role=role, model="synthetic-" + role, reasoning_effort="high")
        self.assertEqual(self.start()["task"]["model"], "synthetic-triage")
        repair = self.prepare()["task"]
        self.assertEqual(repair["model"], "synthetic-repair")
        self.assertEqual(repair["fork_args"]["threadId"], self.registry["templateThreadId"])
        self.assertEqual(self.call("config.sync")["model"], "synthetic-dispatcher")

    def test_registered_fork_stays_pending_until_delivery(self):
        plan = self.plan()
        self.call("week.register", run_id=plan["run_id"], thread_id=self.worker)
        entry = self.runtime.registry()["managedThreads"][plan["week"]]
        self.assertEqual(entry["setupState"], "pending")
        with self.assertRaises(ValueError):
            self.call("dispatch.plan", now="2026-09-25T21:00:00+08:00")
        self.call("dispatch.delivered", run_id=plan["run_id"])
        self.call("triage.begin", run_id=plan["run_id"], thread_id=self.worker)
        entry = self.runtime.registry()["managedThreads"][plan["week"]]
        self.assertEqual(entry["setupState"], "ready")
        self.assertEqual(entry["templateThreadId"], self.registry["templateThreadId"])
        self.assertEqual(entry["source"], "template-fork")

    def test_paused_automation_never_restarts(self):
        self.start()
        self.incident()
        (self.directory / "automation.toml").write_text('status = "PAUSED"\n')
        self.assertEqual(self.plan()["operation"], "paused")
        self.assertFalse(self.call("triage.begin", run_id=self.run_id, thread_id=self.worker)["should_run"])
        self.assertFalse(self.call("repair.prepare", incident_id=self.incident_id)["launch"])

    def test_unknown_result_does_not_launch(self):
        self.start()
        result = self.call("incident.open", run_id=self.run_id, stage="create", error_code="no_result", outcome="unknown")
        self.assertFalse(result["repair"])
        self.assertEqual(self.runtime.state()["incidents"], {})

    def test_one_repair_one_rerun_failure_stays_visible(self):
        self.start()
        self.prepare()
        self.assertFalse(self.call("repair.prepare", incident_id=self.incident_id)["launch"])
        self.assertFalse(self.incident(owner=self.dispatcher)["repair"])
        replacement = uid()
        self.assertTrue(self.call("repair.retry", incident_id=self.incident_id, replacement_thread_id=replacement)["retry"])
        self.assertFalse(self.call("repair.retry", incident_id=self.incident_id)["retry"])
        self.call("triage.begin", run_id=self.run_id, thread_id=replacement)
        self.assertFalse(self.incident(owner=replacement)["repair"])
        changed_error = self.call("incident.open", run_id=self.run_id, thread_id=replacement,
                                  stage="state.record", error_code="another_failure", outcome="failed")
        self.assertFalse(changed_error["repair"])
        result = self.call("repair.finish", incident_id=self.incident_id, success=False)
        self.assertEqual(result["archive_ids"], [])
        cleanup = self.call("cleanup.plan", run_id=self.run_id, thread_id=uid())
        self.assertFalse(set(cleanup["thread_ids"]) & {self.worker, self.dispatcher, replacement})
        self.assertFalse(self.incident(owner=replacement)["repair"])

    def test_archive_requires_saved_state_and_report(self):
        self.start()
        self.prepare()
        replacement = uid()
        self.call("repair.retry", incident_id=self.incident_id, replacement_thread_id=replacement)
        with self.assertRaises(ValueError):
            self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.call("triage.begin", run_id=self.run_id, thread_id=replacement)
        self.call("triage.recorded", run_id=self.run_id, thread_id=replacement, state_recorded=True)
        with self.assertRaises(ValueError):
            self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=False)
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [self.worker])
        self.call("cleanup.record", thread_id=self.worker)
        self.assertNotIn(replacement, self.runtime.state()["archived"])

    def test_cleanup_failure_does_not_rescan_recorded_run(self):
        self.start()
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.cleanup_failure()
        self.attach_legacy_cleanup_repair()
        self.assertFalse(self.call("repair.retry", incident_id=self.incident_id)["retry"])
        with self.assertRaisesRegex(ValueError, "原归档目标"):
            self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        # Archiving the reporting dispatcher is not proof that the failed target was fixed.
        self.call("cleanup.record", thread_id=self.dispatcher)
        with self.assertRaisesRegex(ValueError, "原归档目标"):
            self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.call("cleanup.record", target_thread_id=self.cleanup_target)
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [self.dispatcher])
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "recorded")
        self.assertEqual(self.runtime.state()["incidents"][self.incident_id]["resolution"], "target_archived")

    def test_dispatcher_cleanup_failure_preserves_active_triage(self):
        self.start()
        self.cleanup_failure()
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")
        self.attach_legacy_cleanup_repair()
        result = self.call("repair.retry", incident_id=self.incident_id)
        self.assertFalse(result["retry"])
        self.assertEqual(result["reason"], "cleanup_only")
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.call("cleanup.record", target_thread_id=self.cleanup_target)
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [self.dispatcher])

    def test_cleanup_requires_actual_managed_local_target(self):
        self.start()
        for args in ({}, {"target_thread_id": uid()},
                     {"target_thread_id": self.dispatcher, "target_host_id": "durable"}):
            with self.assertRaises(ValueError):
                self.call("cleanup.failed", run_id=self.run_id, outcome="failed", **args)
        self.assertEqual(self.runtime.state()["incidents"], {})
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")

    def test_cleanup_same_target_deduplicates_across_runs_and_error_labels(self):
        self.start()
        first = self.cleanup_failure()["incident"]
        self.call("repair.prepare", incident_id=self.incident_id)
        self.call("repair.finish", incident_id=self.incident_id, success=False)
        other = uid()
        later = self.call("dispatch.plan", thread_id=other, now="2026-09-25T21:00:00+08:00")
        for stage, code in (("cleanup.archive", "tool_unavailable"),
                            ("dispatcher_cleanup", "archive_tool_unavailable"),
                            ("archive", "archive_unavailable")):
            result = self.call("incident.open", run_id=later["run_id"], thread_id=other,
                               stage=stage, error_code=code, outcome="unavailable",
                               target_thread_id=self.cleanup_target)
            self.assertFalse(result["repair"])
            self.assertEqual(result["incident"]["id"], first["id"])
        self.assertEqual(len(self.runtime.state()["incidents"]), 1)
        self.assertEqual(set(result["incident"]["failed_thread_ids"]), {self.dispatcher, other})

    def test_unresolved_cleanup_target_is_not_automatically_retried(self):
        self.start()
        self.cleanup_failure()
        result = self.call("cleanup.plan", run_id=self.run_id)
        self.assertNotIn(self.cleanup_target, result["thread_ids"])
        self.assertEqual(result["blocked_thread_ids"], [self.cleanup_target])
        self.call("repair.finish", incident_id=self.incident_id, success=False)
        result = self.call("cleanup.plan", run_id=self.run_id)
        self.assertNotIn(self.cleanup_target, result["thread_ids"])
        self.assertEqual(result["blocked_thread_ids"], [self.cleanup_target])

    def test_cleanup_does_not_absorb_mail_failure_in_same_run(self):
        self.start()
        cleanup = self.cleanup_failure()["incident"]["id"]
        mail = self.incident()
        self.assertTrue(mail["repair"])
        self.assertNotEqual(mail["incident"]["id"], cleanup)
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "failed")
        other_target = self.dispatcher
        other = self.call("cleanup.failed", run_id=self.run_id,
                          target_thread_id=other_target, outcome="failed")
        self.assertFalse(other["repair"])
        self.assertEqual(len(self.runtime.state()["incidents"]), 3)

    def test_missing_target_needs_both_local_checks_and_original_target(self):
        self.start()
        self.cleanup_failure()
        for verification in ({}, {"host_id": "local", "index_absent": True},
                             {"host_id": "local", "rollout_absent": True},
                             {"host_id": "durable", "index_absent": True, "rollout_absent": True}):
            with self.assertRaises(ValueError):
                self.call("cleanup.record", target_thread_id=self.cleanup_target, outcome="missing",
                          incident_id=self.incident_id, verification=verification)
        with self.assertRaises(ValueError):
            self.call("cleanup.record", target_thread_id=self.dispatcher, outcome="missing",
                      incident_id=self.incident_id,
                      verification={"host_id": "local", "index_absent": True, "rollout_absent": True})
        self.assertNotIn("missing_threads", self.runtime.state())

    def test_confirmed_missing_target_resolves_without_claiming_archive(self):
        self.start()
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.cleanup_failure()
        self.call("cleanup.record", target_thread_id=self.cleanup_target, outcome="missing",
                  incident_id=self.incident_id,
                  verification={"host_id": "local", "index_absent": True, "rollout_absent": True})
        self.assertEqual(self.call("repair.get", incident_id=self.incident_id)["target_outcome"], "missing")
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["status"], "resolved")
        self.assertNotIn(self.cleanup_target, self.runtime.state()["archived"])
        self.assertEqual(self.runtime.state()["incidents"][self.incident_id]["resolution"], "target_missing")
        plan = self.call("cleanup.plan", run_id=self.run_id)
        self.assertNotIn(self.cleanup_target, plan["thread_ids"] + plan["blocked_thread_ids"])

    def test_missing_evidence_cannot_remove_current_week(self):
        self.start()
        result = self.call("cleanup.failed", run_id=self.run_id, target_thread_id=self.worker, outcome="failed")
        with self.assertRaisesRegex(ValueError, "保留中"):
            self.call("cleanup.record", target_thread_id=self.worker, outcome="missing",
                      incident_id=result["incident"]["id"],
                      verification={"host_id": "local", "index_absent": True, "rollout_absent": True})

    def test_legacy_cleanup_without_target_cannot_claim_repair_success(self):
        self.start()
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.cleanup_failure()
        state = self.runtime.state()
        state["incidents"][self.incident_id].pop("target_thread_id")
        state["incidents"][self.incident_id]["stage"] = "dispatcher_cleanup"
        self.runtime.save(state)
        with self.assertRaisesRegex(ValueError, "原归档目标"):
            self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)

    def test_repairer_can_record_final_archive_failure_without_recursive_repair(self):
        self.start()
        self.cleanup_failure()
        self.attach_legacy_cleanup_repair()
        result = self.call("cleanup.failed", run_id=self.run_id, thread_id=self.repairer,
                          target_thread_id=self.dispatcher, outcome="failed")
        incident_id = result["incident"]["id"]
        self.call("repair.finish", incident_id=incident_id, success=False)
        self.assertFalse(self.call("repair.prepare", incident_id=incident_id)["launch"])
        plan = self.call("cleanup.plan", run_id=self.run_id, thread_id=uid())
        self.assertNotIn(self.dispatcher, plan["thread_ids"])

    def test_unrelated_task_cannot_report_cleanup_for_another_run(self):
        self.start()
        with self.assertRaisesRegex(ValueError, "不属于"):
            self.call("cleanup.failed", run_id=self.run_id, thread_id=uid(),
                      target_thread_id=self.dispatcher, outcome="failed")
        self.assertEqual(self.runtime.state()["incidents"], {})

    def test_successful_repair_task_is_cleaned_and_acknowledged(self):
        self.start()
        self.cleanup_failure()
        self.attach_legacy_cleanup_repair()
        self.assertNotIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id)["thread_ids"])
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        self.call("cleanup.record", target_thread_id=self.cleanup_target)
        self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id)["thread_ids"])
        self.assertNotIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id,
                                               thread_id=self.repairer)["thread_ids"])
        self.call("cleanup.record", target_thread_id=self.repairer)
        self.assertNotIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id)["thread_ids"])
        self.assertNotIn("repair_archive_pending", self.runtime.state()["incidents"][self.incident_id])

    def test_failed_and_legacy_repair_tasks_are_not_auto_archived(self):
        self.start()
        self.cleanup_failure()
        self.attach_legacy_cleanup_repair()
        self.call("repair.finish", incident_id=self.incident_id, success=False)
        self.assertNotIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id)["thread_ids"])
        state = self.runtime.state()
        state["incidents"][self.incident_id]["status"] = "resolved"
        self.runtime.save(state)
        self.assertNotIn(self.repairer, self.call("cleanup.plan", run_id=self.run_id)["thread_ids"])

    def test_cleanup_keeps_last_week_and_unknown_tasks(self):
        for week, date in (("2026-W37", "2026-09-07"), ("2026-W38", "2026-09-14")):
            self.registry["managedThreads"][week] = {"title": module.week_info(module.timestamp(date+"T08:00:00+08:00"))[1],
                                                     "threadId": uid()}
        module.atomic_json(self.runtime.registry_path, self.registry)
        self.start()
        self.assertEqual(self.call("cleanup.plan", run_id=self.run_id)["thread_ids"],
                         [self.registry["managedThreads"]["2026-W37"]["threadId"]])
        with self.assertRaises(ValueError):
            self.call("cleanup.record", thread_id=uid())

    def test_cleanup_stale_running_marker_after_later_success(self):
        old = self.start()
        old_id = old["run_id"]
        state = self.runtime.state()
        state["runs"][old_id]["started_at"] = "2026-09-25T08:01:00+08:00"
        self.runtime.save(state)
        later = self.call("dispatch.plan", now="2026-09-25T21:00:00+08:00")
        self.call("triage.begin", run_id=later["run_id"], thread_id=self.worker)
        self.call("triage.recorded", run_id=later["run_id"], thread_id=self.worker, state_recorded=True)
        current = self.call("dispatch.plan", now="2026-10-06T08:00:00+08:00")
        self.assertIn(self.worker, self.call("cleanup.plan", run_id=current["run_id"])["thread_ids"])
        self.assertEqual(self.call("run.get", run_id=old_id)["phase"], "running")
        # An unresolved incident still protects the old task.
        self.incident(owner=self.worker)
        self.assertNotIn(self.worker, self.call("cleanup.plan", run_id=current["run_id"])["thread_ids"])

    def test_cleanup_keeps_running_work_newer_than_success(self):
        self.start()
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        later = self.call("dispatch.plan", now="2026-09-25T21:00:00+08:00")
        self.call("triage.begin", run_id=later["run_id"], thread_id=self.worker)
        current = self.call("dispatch.plan", now="2026-10-06T08:00:00+08:00")
        self.assertNotIn(self.worker, self.call("cleanup.plan", run_id=current["run_id"])["thread_ids"])

    def test_broken_registry_can_launch_diagnostic_repair(self):
        self.runtime.registry_path.write_text("not json")
        opened = self.call("incident.open", stage="dispatch", error_code="registry_invalid", outcome="failed")
        result = self.call("repair.prepare", incident_id=opened["incident"]["id"])
        self.assertEqual(result["task"]["fork_args"]["threadId"], self.registry["templateThreadId"])

    def test_cli_fallback_uses_model_and_records_actual_task(self):
        self.start()
        self.incident()
        self.call("repair.prepare", incident_id=self.incident_id)
        args_file = self.base / "args.json"
        fake = self.base / "codex"
        fake.write_text("#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\n"
            + "Path(" + repr(str(args_file)) + ").write_text(json.dumps(sys.argv[1:]))\n"
            + "sys.stdin.read()\nprint(json.dumps(" + repr({"type": "thread.started", "thread_id": self.repairer}) + "))\n")
        fake.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.base) + os.pathsep + os.environ["PATH"]}):
            os.environ.pop("CODEX_CLI_PATH", None)
            self.runtime.cli_worker(self.incident_id)
        args = json.loads(args_file.read_text())
        self.assertEqual(args[args.index("--model")+1], "gpt-6-astra")
        self.assertIn('model_reasoning_effort="medium"', args)
        incident = self.call("repair.get", incident_id=self.incident_id)["incident"]
        self.assertEqual(incident["repair_thread_id"], self.repairer)
        self.assertEqual(incident["status"], "failed")

    def test_cli_fallback_refuses_unknown_creation(self):
        self.start()
        self.incident()
        self.call("repair.prepare", incident_id=self.incident_id)
        with self.assertRaises(ValueError):
            self.runtime.launch_cli(self.incident_id, "timeout")

    def test_cleanup_cannot_launch_repair_through_any_entrypoint(self):
        self.start()
        result = self.cleanup_failure()
        self.assertFalse(result["repair"])
        self.assertEqual(result["reason"], "cleanup_deferred")
        self.assertFalse(self.call("repair.prepare", incident_id=self.incident_id)["launch"])
        with patch.object(module.subprocess, "Popen") as launch:
            self.assertFalse(self.runtime.launch_cli(self.incident_id, "tool_unavailable")["started"])
            self.runtime.cli_worker(self.incident_id)
            launch.assert_not_called()
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")

    def test_nonoperational_errors_do_not_interrupt_or_start_repairs(self):
        self.start()
        for code in module.NON_REPAIR_CODES:
            result = self.call("incident.open", run_id=self.run_id, thread_id=self.worker,
                               stage="mail_scan", error_code=code, outcome="failed")
            self.assertFalse(result["repair"], code)
        result = self.call("incident.open", run_id=self.run_id, thread_id=self.worker,
                           stage="attachment.text", error_code="unexpected_converter_error", outcome="failed")
        self.assertFalse(result["repair"])
        self.assertEqual(self.runtime.state()["incidents"], {})
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")

    def test_legacy_content_incident_cannot_bypass_repair_gate(self):
        self.start()
        self.incident()
        state = self.runtime.state()
        state["incidents"][self.incident_id]["error_code"] = "mail_body_size_limit"
        self.runtime.save(state)
        self.assertFalse(self.call("repair.prepare", incident_id=self.incident_id)["launch"])
        with patch.object(module.subprocess, "Popen") as launch:
            self.assertFalse(self.runtime.launch_cli(self.incident_id, "tool_unavailable")["started"])
            self.runtime.cli_worker(self.incident_id)
            launch.assert_not_called()

    def test_real_operational_failure_still_has_one_repair(self):
        self.start()
        for code in ("mail_automation_failure", "state_storage_failure", "unexpected_bridge_error"):
            result = self.call("incident.open", run_id=self.run_id, thread_id=self.worker,
                               stage="mail_scan", error_code=code, outcome="failed")
            if code == "mail_automation_failure":
                self.assertTrue(result["repair"])
                incident_id = result["incident"]["id"]
                self.assertTrue(self.call("repair.prepare", incident_id=incident_id)["launch"])
            else:
                self.assertFalse(result["repair"])
                self.assertEqual(result["incident"]["id"], incident_id)
        self.assertEqual(len(self.runtime.state()["incidents"]), 1)

    def test_json_cli_uses_calling_thread(self):
        env = dict(os.environ, MAIL_TRIAGE_AUTOMATION_DIR=str(self.directory),
                   MAIL_TRIAGE_SETTINGS_PATH=str(self.settings), CODEX_THREAD_ID=self.dispatcher)
        result = subprocess.run(["python3", str(ROOT / "automation/runtime.py")],
            input=json.dumps({"action": "dispatch.plan", "now": "2026-09-25T10:00:00+08:00"}),
            text=True, capture_output=True, env=env, check=True)
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.assertEqual(next(iter(self.runtime.state()["runs"].values()))["dispatcher_id"], self.dispatcher)

if __name__ == "__main__":
    unittest.main()
