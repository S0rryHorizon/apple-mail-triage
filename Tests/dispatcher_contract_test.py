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

    def test_template_fork_and_single_delivery(self):
        plan = self.start()
        self.assertEqual(plan["operation"], "fork")
        self.assertEqual(plan["task"]["fork_args"], {"threadId": self.registry["templateThreadId"], "environment": {"type": "same-directory"}})
        self.assertEqual((plan["model"], plan["thinking"]), ("gpt-6-luna", "max"))
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
        self.incident(owner=self.dispatcher, stage="archive")
        self.call("repair.prepare", incident_id=self.incident_id)
        self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer)
        self.assertFalse(self.call("repair.retry", incident_id=self.incident_id)["retry"])
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [self.dispatcher])

    def test_dispatcher_cleanup_failure_preserves_active_triage(self):
        self.start()
        self.incident(owner=self.dispatcher, stage="archive")
        self.assertEqual(self.call("run.get", run_id=self.run_id)["phase"], "running")
        self.call("repair.prepare", incident_id=self.incident_id)
        self.call("repair.attach", incident_id=self.incident_id, thread_id=self.repairer)
        result = self.call("repair.retry", incident_id=self.incident_id)
        self.assertFalse(result["retry"])
        self.assertEqual(result["reason"], "triage_in_progress")
        self.call("triage.recorded", run_id=self.run_id, thread_id=self.worker, state_recorded=True)
        result = self.call("repair.finish", incident_id=self.incident_id, success=True, report_delivered=True)
        self.assertEqual(result["archive_ids"], [self.dispatcher])

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
