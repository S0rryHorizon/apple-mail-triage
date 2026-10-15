#!/usr/bin/env python3
"""Small, deterministic state helper for the Codex-managed mail workflow.

JSON request on stdin, JSON result on stdout. Bridge responses pass through memory;
only operational metadata is saved. App operations remain App tools.
"""
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
ZONE = ZoneInfo("Asia/Singapore")
RECEIPT = "本次整理完成，暂无需要关注的新内容。"
EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
CLEANUP_STAGES = {"cleanup.archive", "dispatcher_cleanup", "archive"}
NON_REPAIR_CODES = {
    "request_validation", "permission_required", "permission_denied", "confirmation_required",
    "not_found", "attachment_limitation", "attachment_rejected", "attachment_policy_rejected",
    "attachment_conversion_failed", "source_size_limit", "mail_body_size_limit",
    "body_decode_failed", "body_not_read", "source_body_missing",
}
BRIDGE_ACTIONS = {"message.scan", "message.read", "attachment.text", "attachment.export",
                  "attachment.cleanup", "state.status", "state.pending", "rule.list", "state.record"}


def bridge_result(returncode, output):
    """A process exit and a bridge outcome are separate evidence, not prose."""
    try:
        response = json.loads(output)
    except (ValueError, UnicodeError):
        response = None
    if isinstance(response, dict):
        if response.get("ok") is True and returncode == 0:
            return {"outcome": "succeeded", "bridge": response, "exit_code": returncode}
        code = response.get("errorCode")
        if response.get("ok") is False and isinstance(code, str) and re.fullmatch(r"[a-z0-9_.-]{1,96}", code):
            bridge = {"ok": False, "status": "error", "errorCode": code}
            details = response.get("details")
            diagnostics = {}
            if isinstance(details, dict):
                allowed = {
                    "operation": {"accounts", "metadata", "source", "rendered_body", "message_metadata", "attachment_export", "source_decode"},
                    "reason": {"scan_deadline", "apple_event_timeout", "script_compile", "apple_script_error"},
                }
                for key, values in allowed.items():
                    if isinstance(details.get(key), str) and details[key] in values:
                        diagnostics[key] = details[key]
                for key in ("apple_error_number", "elapsed_ms"):
                    value = details.get(key)
                    if isinstance(value, str) and re.fullmatch(r"-?[0-9]{1,10}", value):
                        diagnostics[key] = value
            if diagnostics:
                bridge["details"] = diagnostics
            if code == "request_validation" and isinstance(response.get("message"), str):
                bridge["message"] = response["message"][:1000]
            return {"outcome": "failed", "error_code": code, "exit_code": returncode,
                    "bridge": bridge, **({"diagnostics": diagnostics} if diagnostics else {})}
    return {"outcome": "failed" if returncode else "unknown", "exit_code": returncode,
            "error_code": "bridge_invalid_response"}


def cleanup_incident(incident):
    return incident.get("stage") in CLEANUP_STAGES or bool(incident.get("target_thread_id"))


def repair_exclusion(incident):
    if cleanup_incident(incident):
        return "cleanup_deferred"
    if incident.get("error_code") in NON_REPAIR_CODES or incident.get("stage", "").startswith("attachment."):
        return "content_validation_or_user_action"
    return None


def known_threads(state, registry):
    ids = {item["threadId"] for item in registry["managedThreads"].values()}
    ids.update(item["dispatcher_id"] for item in state["runs"].values())
    for incident in state["incidents"].values():
        ids.update(incident.get("failed_thread_ids", [incident["failed_thread_id"]]))
        if incident.get("repair_thread_id"):
            ids.add(incident["repair_thread_id"])
        if incident.get("previous_repair_thread_id"):
            ids.add(incident["previous_repair_thread_id"])
        if incident.get("previous_week_thread_id"):
            ids.add(incident["previous_week_thread_id"])
    return ids


def cleanup_outcome(state, target):
    if target in state["archived"]:
        return "archived"
    if target in state.get("missing_threads", {}):
        return "missing"
    return "unverified"


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def timestamp(value=None):
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else dt.datetime.now(ZONE)
    if result.tzinfo is None:
        raise ValueError("时间必须包含时区")
    return result.astimezone(ZONE)


def thread_id(value):
    return str(uuid.UUID(value))


def week_info(when):
    year, week, _ = when.isocalendar()
    monday = when.date() - dt.timedelta(days=when.weekday())
    sunday = monday + dt.timedelta(days=6)
    return f"{year}-W{week:02}", f"邮箱整理｜{year}-W{week:02}｜{monday:%m.%d}–{sunday:%m.%d}"


class Runtime:
    def __init__(self, directory=None, settings=None, root=ROOT):
        self.root = Path(root)
        self.directory = Path(directory or os.environ.get("MAIL_TRIAGE_AUTOMATION_DIR", str(Path.home() / ".codex/automations/apple")))
        self.settings = Path(settings or os.environ.get("MAIL_TRIAGE_SETTINGS_PATH", str(self.root / "automation/settings.json")))
        self.registry_path = self.directory / "weekly_threads.json"
        self.state_path = self.directory / "runtime.json"

    @contextlib.contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with (self.directory / "runtime.lock").open("a") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def config(self):
        value = json.loads(self.settings.read_text())
        for name in ("triage", "dispatcher", "repair"):
            role = value["roles"][name]
            if not isinstance(role["model"], str) or not role["model"].strip() or role["reasoning_effort"] not in EFFORTS:
                raise ValueError(f"无效角色配置：{name}")
        return value

    def active(self):
        text = (self.directory / "automation.toml").read_text()
        return re.search(r'^status\s*=\s*"ACTIVE"\s*$', text, re.M) is not None

    def registry(self):
        value = json.loads(self.registry_path.read_text())
        if value.get("schemaVersion") != 1 or value.get("automationId") != self.directory.name or value.get("hostId") != "local":
            raise ValueError("受管周任务索引身份不匹配")
        thread_id(value["projectId"])
        for week, item in value["managedThreads"].items():
            year, number = map(int, week.split("-W"))
            monday = dt.datetime.combine(dt.date.fromisocalendar(year, number, 1), dt.time(), ZONE)
            if item["title"] != week_info(monday)[1]:
                raise ValueError("受管周任务标题与周次不匹配")
            thread_id(item["threadId"])
        return value

    def state(self):
        return json.loads(self.state_path.read_text()) if self.state_path.exists() else {
            "runs": {}, "incidents": {}, "archived": []}

    def save(self, state):
        atomic_json(self.state_path, state)

    def prompt(self, run_id):
        return (f"使用 $email-triage 完成当前受管周任务中的后台整理。运行 ID：{run_id}。"
                f"先重新读取当前安装的 skill 及 {self.root / 'automation/triage.md'}，"
                "按该文件登记并领取这次运行；如果 should_run=false 就停止重复执行。"
                "以本轮当前 skill 为准，历史任务中的旗标、固定回执和要求另开任务确认候选的规则已退役。")

    def task_args(self, role, prompt, title, registry):
        model = self.config()["roles"][role]
        return {"title": title, "prompt": prompt, "model": model["model"],
                "thinking": model["reasoning_effort"], "fork_args": {
                    "threadId": thread_id(registry["templateThreadId"]),
                    "environment": {"type": "same-directory"}}}

    def bridge_call(self, request):
        """Execute once, classify the actual result, and persist its run outcome."""
        payload = dict(request["request"])
        action = payload.get("action")
        if action not in BRIDGE_ACTIONS:
            raise ValueError("后台 bridge.call 不支持此操作")
        run_id = request["run_id"]
        owner = thread_id(request["thread_id"])
        with self.locked():
            state = self.state()
            run = state["runs"][run_id]
            if owner != run["thread_id"]:
                raise ValueError("只有当前整理任务可以执行本次桥接调用")
            if not self.active():
                return {"outcome": "not_run", "reason": "paused", "run_phase": run["phase"]}
            if run["phase"] not in ("running", "blocked"):
                return {"outcome": "not_run", "reason": run["phase"], "run_phase": run["phase"]}
            scan = run.get("scan")
            if action == "message.scan":
                if scan:
                    if scan["complete"]:
                        raise ValueError("本轮分页已结束；不要重复扫描")
                    expected = {"since": scan["since"], "until": scan["until"],
                                "offset": scan["next_offset"], "limit": scan["limit"]}
                    for key, value in expected.items():
                        if key in payload and payload[key] != value:
                            raise ValueError("分页必须沿用已冻结窗口和 nextOffset")
                        payload[key] = value
                elif payload.get("offset", 0) != 0:
                    raise ValueError("首个扫描页必须从 offset 0 开始")
            if action == "state.record" and not (scan and scan["complete"]):
                raise ValueError("冻结窗口尚未扫描完毕，不能保存整理结果")
            executable = os.environ.get("MAILBRIDGE_PATH") or str(Path.home() / "Applications/MailBridge.app/Contents/MacOS/MailBridge")
            try:
                process = subprocess.run([executable], input=json.dumps(payload),
                    capture_output=True, text=True, timeout=90)
                result = bridge_result(process.returncode, process.stdout)
                # A broken write response cannot prove whether its transaction committed.
                if action == "state.record" and result.get("error_code") == "bridge_invalid_response":
                    result["outcome"] = "unknown"
            except subprocess.TimeoutExpired:
                result = {"outcome": "unknown", "error_code": "bridge_timeout"}
            except OSError:
                result = {"outcome": "failed", "error_code": "bridge_unavailable"}
            except UnicodeError:
                result = {"outcome": "unknown", "error_code": "bridge_invalid_response"}
            if result["outcome"] == "succeeded":
                response = result["bridge"]
                if action == "message.scan":
                    details = response.get("details", {})
                    try:
                        since, until = details["since"], details["until"]
                        timestamp(since), timestamp(until)
                        next_offset = int(details["nextOffset"])
                        complete = details["hasMore"] == "false"
                        if details["hasMore"] not in ("true", "false") or next_offset < payload.get("offset", 0):
                            raise ValueError("Invalid page")
                        if not complete and next_offset <= payload.get("offset", 0):
                            raise ValueError("Page did not advance")
                        if scan and (since, until) != (scan["since"], scan["until"]):
                            raise ValueError("Window changed")
                        run["scan"] = {"since": since, "until": until, "next_offset": next_offset,
                                       "complete": complete, "limit": min(max(payload.get("limit", 200), 1), 1000)}
                    except (KeyError, TypeError, ValueError, AttributeError):
                        result = {"outcome": "unknown", "error_code": "bridge_invalid_response"}
                elif action == "state.record":
                    summary = response.get("state")
                    count = summary.get("deferredBodyCount") if isinstance(summary, dict) else None
                    if type(count) is not int or count < 0 or response.get("status") != "recorded":
                        result = {"outcome": "unknown", "error_code": "bridge_invalid_response"}
                    else:
                        run.update(phase="partial" if count else "recorded", deferred_body_count=count,
                                   ended_at=timestamp().isoformat())
            if result["outcome"] == "succeeded":
                if action != "state.record":
                    run["phase"] = "running"
                    run.pop("ended_at", None)
            else:
                run.update(phase="unknown" if result["outcome"] == "unknown" else
                           "blocked" if repair_exclusion({"stage": action, "error_code": result["error_code"]}) else "failed",
                           ended_at=timestamp().isoformat())
            run["last_bridge"] = {"action": action, "at": timestamp().isoformat(),
                                  **{key: result[key] for key in ("outcome", "error_code", "exit_code", "diagnostics") if key in result}}
            self.save(state)
            result["run_phase"] = run["phase"]
        if result["outcome"] == "failed":
            result["recovery"] = self.handle({"action": "incident.open", "run_id": run_id,
                "thread_id": owner, "stage": action, "error_code": result["error_code"], "outcome": "failed"})
        return result

    def handle(self, request):
        action = request["action"]
        if action == "bridge.call":
            return self.bridge_call(request)
        if action == "cleanup.failed":
            request = {**request, "stage": "cleanup.archive",
                       "error_code": request.get("error_code", "archive_failed")}
            action = "incident.open"
        with self.locked():
            if action == "config.get":
                return self.config()
            if action == "config.set":
                value = self.config()
                role = request["role"]
                if role not in value["roles"]:
                    raise ValueError("未知角色")
                updated = {"model": request["model"], "reasoning_effort": request["reasoning_effort"]}
                if not isinstance(updated["model"], str) or not updated["model"].strip() or updated["reasoning_effort"] not in EFFORTS:
                    raise ValueError("无效模型配置")
                value["roles"][role] = updated
                atomic_json(self.settings, value)
                return {"roles": value["roles"], "sync_required": role == "dispatcher"}
            if action == "config.sync":
                role = self.config()["roles"]["dispatcher"]
                return {"id": self.directory.name, "model": role["model"],
                        "reasoningEffort": role["reasoning_effort"],
                        "prompt": f"你是邮箱周任务分发器。首先读取 {self.root / 'automation/weekly-dispatcher.md'} 并按当前文件执行。"
                                  f"运行辅助程序位于 {self.root / 'automation/runtime.py'}。只分发任务，不在分发器整理邮件。"}
            state = self.state()
            try:
                registry = self.registry()
            except (ValueError, KeyError, OSError):
                if action not in ("incident.open", "repair.prepare", "repair.get", "repair.attach", "repair.finish"):
                    raise
                # A broken weekly index must not disable its own diagnostic path.
                registry = {**state["identity"], "managedThreads": {}}
            state["identity"] = {key: registry[key] for key in
                                 ("schemaVersion", "automationId", "projectId", "hostId", "templateThreadId")
                                 if key in registry}
            if action == "initialize":
                self.config()
                self.save(state)
                return {"initialized": True}
            if action == "dispatch.plan":
                if not self.active():
                    return {"operation": "paused"}
                now = timestamp(request.get("now"))
                if request.get("planned_at"):
                    planned = timestamp(request["planned_at"])
                else:
                    planned = now.replace(hour=20 if now.hour >= 20 else 8, minute=0, second=0, microsecond=0)
                    if now.hour < 8:
                        planned -= dt.timedelta(hours=12)
                week, title = week_info(planned)
                run_id = registry["automationId"] + ":" + planned.isoformat()
                if run_id in state["runs"]:
                    return {"operation": "already_registered", "run_id": run_id, "run": state["runs"][run_id]}
                owner = thread_id(request["thread_id"])
                target = registry["managedThreads"].get(week)
                if target and target.get("setupState", "ready") != "ready":
                    raise ValueError("本周任务创建未完成，需恢复原任务，不能另建副本")
                # A manually restarted dispatcher is active again even if a
                # previous run of that same chat was successfully archived.
                state["archived"] = [value for value in state["archived"] if value != owner]
                state.get("missing_threads", {}).pop(owner, None)
                state["runs"][run_id] = {"week": week, "title": title, "planned_at": planned.isoformat(),
                    "started_at": now.isoformat(), "dispatcher_id": owner,
                    "thread_id": target["threadId"] if target else None, "phase": "prepared", "retries": 0}
                self.save(state)
                role = self.config()["roles"]["triage"]
                result = {"run_id": run_id, "week": week, "title": title,
                          "operation": "deliver" if target else "fork",
                          "model": role["model"], "thinking": role["reasoning_effort"], "prompt": self.prompt(run_id)}
                if target:
                    result["thread_id"] = target["threadId"]
                else:
                    result["task"] = self.task_args("triage", self.prompt(run_id), title, registry)
                return result
            if action == "run.get":
                return state["runs"][request["run_id"]]
            if action in ("week.register", "triage.begin", "dispatch.delivered", "triage.recorded", "triage.partial"):
                run = state["runs"][request["run_id"]]
                if action == "triage.begin" and not self.active():
                    return {"should_run": False, "reason": "paused"}
                if action in ("week.register", "triage.begin"):
                    owner = thread_id(request["thread_id"])
                    if run["thread_id"] not in (None, owner):
                        raise ValueError("本次运行已属于另一个任务")
                    existing = registry["managedThreads"].get(run["week"])
                    if existing and existing["threadId"] != owner:
                        raise ValueError("本周已有另一个任务；替换必须经过修复流程")
                    run["thread_id"] = owner
                    entry = dict(existing or {})
                    entry.update(title=run["title"], threadId=owner,
                                 setupState="pending" if action == "week.register" else "ready")
                    if action == "week.register":
                        entry.update(source="template-fork", templateThreadId=registry["templateThreadId"])
                    registry["managedThreads"][run["week"]] = entry
                    atomic_json(self.registry_path, registry)
                if action == "triage.begin":
                    if run["phase"] not in ("prepared", "delivered", "retry_ready"):
                        return {"should_run": False, "reason": run["phase"]}
                    run["phase"] = "running"
                elif action == "dispatch.delivered":
                    if run["phase"] == "prepared":
                        run["phase"] = "delivered"
                    entry = registry["managedThreads"].get(run["week"])
                    if entry and entry["threadId"] == run["thread_id"]:
                        entry["setupState"] = "ready"
                        atomic_json(self.registry_path, registry)
                elif action in ("triage.recorded", "triage.partial"):
                    if thread_id(request["thread_id"]) != run["thread_id"]:
                        raise ValueError("只有当前整理任务可以记录完成")
                    if run["phase"] != "running" or request.get("state_recorded") is not True:
                        raise ValueError("只有完成整理且成功保存状态后才能记录完成")
                    if action == "triage.partial":
                        count = request.get("deferred_body_count")
                        if type(count) is not int or count < 1:
                            raise ValueError("部分整理需要真实的待处理正文数量")
                        run.update(phase="partial", deferred_body_count=count)
                    else:
                        run["phase"] = "recorded"
                self.save(state)
                return {"should_run": True, "run": run, "receipt": None if run["phase"] == "partial" else RECEIPT}
            if action == "cleanup.plan":
                run = state["runs"][request["run_id"]]
                previous = week_info(timestamp(run["planned_at"]) - dt.timedelta(days=7))[0]
                ids = [item["threadId"] for week, item in registry["managedThreads"].items() if week < previous]
                ids += [item["dispatcher_id"] for item in state["runs"].values()
                        if item["phase"] in ("delivered", "running", "partial", "recorded", "completed")]
                ids += [item["repair_thread_id"] for item in state["incidents"].values()
                        if item["status"] == "resolved" and item.get("repair_archive_pending")
                        and item.get("repair_thread_id")]
                # A later successful run in the same weekly task supersedes a
                # stale running marker for cleanup only; it does not prove the
                # older run completed. Keep newer running work protected.
                successful = {}
                for item in state["runs"].values():
                    if item["phase"] in ("recorded", "completed"):
                        owner = item["thread_id"]
                        when = timestamp(item["started_at"])
                        successful[owner] = max(successful.get(owner, when), when)
                protected = {item["thread_id"] for item in state["runs"].values()
                             if item["phase"] == "running" and (
                                 item["thread_id"] not in successful or
                                 timestamp(item["started_at"]) >= successful[item["thread_id"]])}
                blocked = set()
                for incident in state["incidents"].values():
                    if incident["status"] != "resolved":
                        protected.update(incident.get("failed_thread_ids", [incident["failed_thread_id"]]))
                        if incident.get("target_thread_id"):
                            blocked.add(incident["target_thread_id"])
                        if incident.get("previous_week_thread_id"):
                            protected.add(incident["previous_week_thread_id"])
                remaining = set(ids) - set(state["archived"]) - set(state.get("missing_threads", {}))
                return {"thread_ids": sorted(remaining - protected - blocked - {request["thread_id"]}),
                        "blocked_thread_ids": sorted(remaining & blocked)}
            if action == "cleanup.record":
                owner = thread_id(request.get("target_thread_id") or request["thread_id"])
                if owner not in known_threads(state, registry):
                    raise ValueError("不管理未知任务")
                outcome = request.get("outcome", "archived")
                if outcome == "archived":
                    state["archived"] = sorted(set(state["archived"]) | {owner})
                    state.get("missing_threads", {}).pop(owner, None)
                    for incident in state["incidents"].values():
                        if incident.get("repair_thread_id") == owner:
                            incident.pop("repair_archive_pending", None)
                elif outcome == "missing":
                    incident = state["incidents"][request["incident_id"]]
                    # The caller must verify both local sources. An App lookup
                    # error (including a durable-host error) alone proves neither.
                    verification = request.get("verification", {})
                    if (not cleanup_incident(incident) or incident.get("target_thread_id") != owner
                            or verification.get("host_id") != "local"
                            or verification.get("index_absent") is not True
                            or verification.get("rollout_absent") is not True):
                        raise ValueError("必须核实原归档目标在本地索引和会话文件中均不存在")
                    latest = max(timestamp(item["planned_at"]) for item in state["runs"].values())
                    previous = week_info(latest - dt.timedelta(days=7))[0]
                    retained = {item["threadId"] for week, item in registry["managedThreads"].items()
                                if week >= previous}
                    retained.update(item["thread_id"] for item in state["runs"].values()
                                    if item["phase"] == "running")
                    if owner in retained or owner == registry.get("templateThreadId"):
                        raise ValueError("不能移除保留中或正在运行的任务引用")
                    if owner in state["archived"]:
                        raise ValueError("已确认归档的任务不能改记为不存在")
                    state.setdefault("missing_threads", {})[owner] = {
                        "host_id": "local", "verified_at": timestamp().isoformat(),
                        "verification": "local_index_and_rollout_absent"}
                else:
                    raise ValueError("cleanup.record 仅接受已确认的 archived 或 missing")
                self.save(state)
                return {outcome: owner}
            if action == "incident.open":
                if request.get("outcome") not in ("failed", "unavailable"):
                    return {"repair": False, "reason": "结果未知或业务问题，不自动接管"}
                code = request["error_code"]
                if not re.fullmatch(r"[a-z0-9_.-]{1,96}", code):
                    raise ValueError("error_code 只保存简短错误类型，不保存原始输出或邮件内容")
                stage = request["stage"]
                is_cleanup = cleanup_incident(request)
                exclusion = repair_exclusion(request)
                if exclusion and not is_cleanup:
                    return {"repair": False, "reason": exclusion}
                target = None
                if is_cleanup:
                    if not request.get("target_thread_id"):
                        raise ValueError("归档故障必须记录实际 target_thread_id")
                    target = thread_id(request["target_thread_id"])
                    if request.get("target_host_id", "local") != "local" or target not in known_threads(state, registry):
                        raise ValueError("归档目标必须是已登记的本地受管任务")
                    stage = "cleanup.archive"
                key = "cleanup.archive:local:" + target if is_cleanup else stage + ":" + code
                owner = thread_id(request["thread_id"])
                run_id = request.get("run_id")
                if not run_id:
                    now = timestamp()
                    week, title = week_info(now)
                    run_id = "diagnostic:" + uuid.uuid4().hex
                    state["runs"][run_id] = {"week": week, "title": title,
                        "planned_at": now.isoformat(), "started_at": now.isoformat(),
                        "dispatcher_id": owner, "thread_id": registry["managedThreads"].get(week, {}).get("threadId"),
                        "phase": "failed", "retries": 0}
                run = state["runs"][run_id]
                is_repairer = is_cleanup and any(
                    item.get("repair_thread_id") == owner and item["run_id"] == run_id
                    for item in state["incidents"].values())
                if owner not in (run["thread_id"], run["dispatcher_id"]) and not is_repairer:
                    raise ValueError("故障任务不属于本次运行")
                if not is_cleanup and run["phase"] not in ("recorded", "completed") and (
                    owner == run["thread_id"] or run["phase"] not in ("delivered", "running")
                ):
                    run["phase"] = "failed"
                for incident in state["incidents"].values():
                    if is_cleanup:
                        same_incident = cleanup_incident(incident) and incident.get("target_thread_id") == target
                    else:
                        same_incident = not cleanup_incident(incident) and (
                            incident["key"] == key or incident["run_id"] == run_id)
                    if same_incident and incident["status"] != "resolved":
                        incident["failed_thread_ids"] = sorted(set(incident.get("failed_thread_ids", [incident["failed_thread_id"]])) | {owner})
                        self.save(state)
                        return {"repair": False, "incident": incident}
                incident_id = "R-" + uuid.uuid4().hex[:12]
                incident = {"id": incident_id, "key": key, "run_id": run_id,
                    "failed_thread_id": owner, "failed_thread_ids": [owner], "stage": stage, "error_code": code,
                    "status": "open", "attempts": 0, "created_at": timestamp().isoformat()}
                failure = state["runs"][run_id].get("last_bridge", {})
                if failure.get("action") == stage and failure.get("error_code") == code and failure.get("diagnostics"):
                    incident["diagnostics"] = failure["diagnostics"]
                if is_cleanup:
                    incident.update(target_thread_id=target, target_host_id="local")
                state["incidents"][incident_id] = incident
                self.save(state)
                return {"repair": exclusion is None, "reason": exclusion, "incident": incident}
            if action == "repair.prepare":
                incident = state["incidents"][request["incident_id"]]
                if reason := repair_exclusion(incident):
                    return {"launch": False, "reason": reason, "incident": incident}
                if not self.active() or incident["attempts"] or incident["status"] != "open":
                    return {"launch": False, "incident": incident}
                incident.update(attempts=1, status="launching")
                self.save(state)
                prompt = (f"你是用户已授权的邮箱自动修复器。故障 ID：{incident['id']}。"
                          f"先读取 {self.root / 'automation/repair.md'}，再使用 {self.root / 'automation/runtime.py'} "
                          "的 repair.get 读取故障。只修复邮箱项目和专属配置，完成恢复或明确报告失败。")
                return {"launch": True, "task": self.task_args("repair", prompt,
                    "邮箱修复｜" + incident["id"], registry)}
            if action == "repair.get":
                incident = state["incidents"][request["incident_id"]]
                return {"incident": incident, "run": state["runs"][incident["run_id"]],
                        "active": self.active(), "template_id": registry.get("templateThreadId"),
                        "target_outcome": cleanup_outcome(state, incident.get("target_thread_id"))
                        if cleanup_incident(incident) else None}
            if action == "repair.attach":
                incident = state["incidents"][request["incident_id"]]
                owner = thread_id(request["thread_id"])
                manual = request.get("manual") is True
                if manual and request.get("confirmed") is not True:
                    raise ValueError("在现有对话中接管修复需要用户明确授权")
                run = state["runs"][incident["run_id"]]
                takeover = (manual and incident["status"] == "failed" and self.active()
                            and run["phase"] == "failed" and not run["retries"]
                            and repair_exclusion(incident) is None)
                if takeover:
                    incident["previous_repair_thread_id"] = incident.get("repair_thread_id")
                    incident.update(repair_thread_id=owner, status="running", manual=True)
                    self.save(state)
                    return incident
                if incident.get("repair_thread_id") not in (None, owner) or incident["status"] not in ("launching", "running"):
                    raise ValueError("修复任务已存在或本次修复已结束")
                if request.get("manual") is True:
                    if request.get("confirmed") is not True:
                        raise ValueError("在现有对话中接管修复需要用户明确授权")
                    incident["manual"] = True
                incident.update(repair_thread_id=owner, status="running")
                self.save(state)
                return incident
            if action == "repair.retry":
                incident = state["incidents"][request["incident_id"]]
                run = state["runs"][incident["run_id"]]
                if not self.active() or incident["status"] != "running":
                    return {"retry": False, "reason": "paused_or_inactive"}
                if cleanup_incident(incident):
                    return {"retry": False, "reason": "cleanup_only", "thread_id": run["thread_id"]}
                if run["phase"] in ("recorded", "completed"):
                    return {"retry": False, "reason": "already_recorded", "thread_id": run["thread_id"]}
                if run["phase"] in ("delivered", "running"):
                    return {"retry": False, "reason": "triage_in_progress", "thread_id": run["thread_id"]}
                if run["retries"]:
                    return {"retry": False, "reason": "retry_used"}
                run.update(retries=1, phase="retry_ready")
                run.pop("scan", None)
                run.pop("last_bridge", None)
                run.pop("ended_at", None)
                if request.get("replacement_thread_id"):
                    owner = thread_id(request["replacement_thread_id"])
                    old = registry["managedThreads"].get(run["week"])
                    incident["previous_week_thread_id"] = old["threadId"] if old else None
                    registry["managedThreads"][run["week"]] = {"title": run["title"], "threadId": owner,
                        "source": "recovery", "templateThreadId": registry["templateThreadId"], "setupState": "pending"}
                    run["thread_id"] = owner
                    atomic_json(self.registry_path, registry)
                if not run["thread_id"]:
                    raise ValueError("需要先创建并登记恢复任务")
                self.save(state)
                role = self.config()["roles"]["triage"]
                return {"retry": True, "thread_id": run["thread_id"], "prompt": self.prompt(incident["run_id"]),
                        "model": role["model"], "thinking": role["reasoning_effort"]}
            if action == "repair.finish":
                incident = state["incidents"][request["incident_id"]]
                run = state["runs"][incident["run_id"]]
                success = request.get("success") is True
                if success and (run["phase"] not in ("recorded", "completed") or request.get("report_delivered") is not True):
                    raise ValueError("尚未确认状态保存和报告输出成功")
                if success and cleanup_incident(incident):
                    outcome = cleanup_outcome(state, incident.get("target_thread_id"))
                    if outcome == "unverified":
                        raise ValueError("原归档目标尚未确认已归档或本地引用已不存在")
                    incident["resolution"] = "target_" + outcome
                incident["status"] = "resolved" if success else "failed"
                if success and not cleanup_incident(incident):
                    run["phase"] = "completed"
                if success:
                    incident["resolved_at"] = timestamp().isoformat()
                    if not incident.get("manual") and incident.get("repair_thread_id") and incident["repair_thread_id"] not in state["archived"]:
                        incident["repair_archive_pending"] = True
                self.save(state)
                # Never archive the live weekly task when it was recovered in place.
                ids = incident.get("failed_thread_ids", [incident["failed_thread_id"]])[:] if success else []
                if incident.get("previous_week_thread_id"):
                    ids.append(incident["previous_week_thread_id"])
                return {"status": incident["status"], "archive_ids": sorted(set(ids) - {run["thread_id"]}) if success else []}
            raise ValueError("未知 runtime action：" + action)

    def launch_cli(self, incident_id, reason, executable=None):
        if reason not in ("tool_unavailable", "creation_definitely_failed"):
            raise ValueError("未知创建结果不能使用备用启动")
        with self.locked():
            state = self.state()
            incident = state["incidents"][incident_id]
            if reason := repair_exclusion(incident):
                return {"started": False, "reason": reason, "incident": incident}
            if not self.active() or incident["status"] != "launching" or incident.get("repair_thread_id") or incident.get("cli_pid"):
                return {"started": False, "incident": incident}
            worker = [sys.executable, str(Path(__file__).resolve()), "--repair-worker", incident_id]
            if executable:
                worker += ["--codex", executable]
            environment = dict(os.environ, MAIL_TRIAGE_AUTOMATION_DIR=str(self.directory),
                               MAIL_TRIAGE_SETTINGS_PATH=str(self.settings))
            process = subprocess.Popen(worker, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True, env=environment)
            incident["cli_pid"] = process.pid
            self.save(state)
            return {"started": True, "pid": process.pid, "incident_id": incident_id}

    def cli_worker(self, incident_id, executable=None):
        with self.locked():
            incident = self.state()["incidents"][incident_id]
            if repair_exclusion(incident):
                return
        role = self.config()["roles"]["repair"]
        executable = executable or os.environ.get("CODEX_CLI_PATH", "codex")
        prompt = (f"用户已授权邮箱自动修复。故障 ID：{incident_id}。"
                  f"读取 {self.root / 'automation/repair.md'} 并执行；不要创建另一个修复器。")
        arguments = [executable, "exec", "--json", "-C", str(self.root), "--model", role["model"],
                     "-c", "model_reasoning_effort=" + json.dumps(role["reasoning_effort"]),
                     "--sandbox", "danger-full-access", "-c", 'approval_policy="never"', "-"]
        try:
            if not self.active():
                raise RuntimeError("automation_paused")
            with subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True) as process:
                process.stdin.write(prompt)
                process.stdin.close()
                for line in process.stdout:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") == "thread.started":
                        self.handle({"action": "repair.attach", "incident_id": incident_id, "thread_id": event["thread_id"]})
                process.wait()
            with self.locked():
                state = self.state()
                incident = state["incidents"][incident_id]
                if incident["status"] not in ("resolved", "failed"):
                    incident.update(status="failed", launch_error="repair_ended_without_recovery")
                    self.save(state)
        except Exception:
            with self.locked():
                state = self.state()
                state["incidents"][incident_id].update(status="failed", launch_error="repair_cli_failed")
                self.save(state)


def main():
    runtime = Runtime()
    if len(sys.argv) > 2 and sys.argv[1] == "--repair-worker":
        runtime.cli_worker(sys.argv[2], sys.argv[4] if len(sys.argv) == 5 else None)
        return
    try:
        request = json.load(sys.stdin)
        if os.environ.get("CODEX_THREAD_ID"):
            request.setdefault("thread_id", os.environ["CODEX_THREAD_ID"])
        if request["action"] == "repair.cli":
            result = runtime.launch_cli(request["incident_id"], request["reason"])
        else:
            result = runtime.handle(request)
        print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
