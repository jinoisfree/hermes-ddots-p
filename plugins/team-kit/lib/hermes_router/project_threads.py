"""Durable, opt-in project state keyed by a transport conversation, never by a model.

This module does not execute tools or authorize writes. Receipts and approval scope
are recorded explicitly; natural-language answers cannot mark a task successful.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from pathlib import Path
import sqlite3
import time
from contextlib import contextmanager


logger = logging.getLogger(__name__)


def hub_settings(contract, platform, chat_id):
    hub = contract.get("project_hub") or {}
    if hub.get("enabled") is True and platform == "slack" and chat_id == hub.get("channel_id"):
        return hub
    return {}


def routing_contract(contract, platform, chat_id):
    hub = hub_settings(contract, platform, chat_id)
    if not hub:
        return contract
    return {**contract, "hub_request_routing": True,
            "patterns": {**contract.get("patterns", {}), **hub.get("patterns", {})}}


def identity(scope_id, chat_id, thread_id, owner_id):
    fields = [str(v or "").strip() for v in (scope_id, chat_id, thread_id, owner_id)]
    if not all(fields):
        raise ValueError("Project requires workspace, channel, root message and owner.")
    return hashlib.sha256(json.dumps(fields).encode()).hexdigest()


def call_digest(tool, args):
    clean = {k: v for k, v in args.items() if k not in {"approved", "confirm", "confirmation", "cancel"}}
    return hashlib.sha256(json.dumps([tool, clean], sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def dependency_ready(task):
    """An accepted read report can unlock work without claiming a write completed."""
    report = task.get("consult", {})
    accepted = task.get("accepted_report", {})
    return task["status"] == "completed" or (
        task["status"] == "recorded" and report.get("status") == "reported"
        and bool(report.get("report"))
        and accepted.get("digest") == hashlib.sha256(report["report"].encode()).hexdigest()
    )


def handoff_route(contract, source, text, decision):
    from hermes_router.common_router import RouteDecision, approval_response_choice
    if decision.reason not in {"fallback", "thread_continuation"} or approval_response_choice(text):
        return decision
    platform = str(getattr(getattr(source, "platform", None), "value", ""))
    hub = hub_settings(contract, platform, str(source.chat_id))
    if not hub or not Path(hub.get("store_path", "")).is_file():
        return decision
    try:
        key = identity(source.scope_id, source.chat_id, source.thread_id, source.user_id)
    except (ValueError, AttributeError):
        return decision
    try:
        project = ProjectStore(hub["store_path"]).get(key) or {}
    except (OSError, sqlite3.Error, ValueError, TypeError) as exc:
        logger.warning("Project handoff lookup failed: %s", type(exc).__name__)
        return decision
    handoff = project.get("handoff") or {}
    message_id = str(getattr(source, "message_id", "") or "")
    if (not message_id or message_id == handoff.get("requested_message_id")
            or handoff.get("expires_at", 0) < time.time()
            or handoff.get("responded_message_id") not in {None, message_id}):
        return decision
    task = next((t for t in project.get("tasks", []) if t["id"] == handoff.get("task_id")), None)
    if (task and task["status"] == "pending" and task["profile"] == handoff.get("profile")
            and set(task["depends_on"]) <= {t["id"] for t in project["tasks"] if dependency_ready(t)}
            and not any(a.get("task_id") == task["id"] for a in project.get("approvals", []))):
        return RouteDecision(task["profile"], "project_handoff")
    return decision


def approval_selection(text):
    match = re.fullmatch(r"\s*프로젝트\s+(승인|거부)\s+([a-f0-9]{16})\s*", text)
    return (match[1], match[2]) if match else None


def approval_route(contract, source, text):
    """Read-only routing. The authenticated owner turn consumes the selection later."""
    from hermes_router.common_router import RouteDecision, approval_response_choice
    platform = str(getattr(getattr(source, "platform", None), "value", ""))
    hub = hub_settings(contract, platform, str(source.chat_id))
    if not hub or not Path(hub.get("store_path", "")).is_file():
        return None
    choice = approval_selection(text)
    resolution = re.fullmatch(r"\s*결과 확인 후 종결 ([a-f0-9]{16})\s*", text)
    if not choice and not resolution and approval_response_choice(text) is None:
        return None
    try:
        key = identity(source.scope_id, source.chat_id, source.thread_id, source.user_id)
    except ValueError:
        return None
    try:
        project = ProjectStore(hub["store_path"]).get(key)
    except (OSError, sqlite3.Error, ValueError, TypeError) as exc:
        logger.warning("Project approval lookup failed: %s", type(exc).__name__)
        return None
    if not project:
        return None
    if resolution:
        selected = [a for a in project.get("approvals", []) if a["id"] == resolution[1] and a["status"] == "unknown"]
        return RouteDecision(selected[0]["profile"] if len(selected) == 1 else contract["profiles"]["fallback"], "project_reconcile", persist_thread=False)
    pending = [a for a in project.get("approvals", []) if a["status"] == "pending" and a["expires_at"] >= time.time()]
    selected = [a for a in pending if a["id"] == choice[1]] if choice else pending
    if len(selected) == 1:
        return RouteDecision(selected[0]["profile"], "project_approval", persist_thread=False)
    if choice or pending:
        return RouteDecision(contract["profiles"]["fallback"], "project_approval_ambiguous", persist_thread=False)
    return None


def project_routing_input(event, contract):
    """Route the current Slack caption, never an inlined document or old media."""
    source = event.source
    platform = str(getattr(getattr(source, "platform", None), "value", ""))
    text = str(getattr(event, "text", "") or "")
    if not hub_settings(contract, platform, str(source.chat_id)):
        return text, False
    raw = getattr(event, "raw_message", None)
    if isinstance(raw, dict):
        # Slack file-only events may omit text; enriched text is not a caption.
        return str(raw.get("text") or ""), bool(raw.get("files"))
    return text, bool(getattr(event, "media_urls", None))


def select_project_profile(source, text, contract, *, has_attachments=False, **kwargs):
    from hermes_router.common_router import _direct_text, _matches, select_profile
    from hermes_router.project_requests import addressed_profiles
    platform = str(getattr(getattr(source, "platform", None), "value", ""))
    hub = hub_settings(contract, platform, str(source.chat_id))
    addressed = addressed_profiles(text, hub) if hub else []
    if addressed:
        kwargs['explicit_profile'] = addressed[0] if len(addressed) == 1 else contract['cross_owner']['profile']
    # Explicitly addressed rooms/bots keep their existing precedence.
    if kwargs.get("explicit_profile"):
        return select_profile(text, contract, **kwargs)
    decision = approval_route(contract, source, text) or select_profile(text, contract, **kwargs)
    if (has_attachments and hub_settings(contract, platform, str(source.chat_id))
            and decision.reason in {"fallback", "thread_continuation"}
            and _matches(contract.get("patterns", {}), "attachment_request", _direct_text(text))):
        return select_profile("첨부 파일 " + text, contract, **kwargs)
    return handoff_route(contract, source, text, decision)


def run_identity():
    import psutil
    process = psutil.Process()
    return {"pid": process.pid, "started": process.create_time()}


def run_alive(run):
    import psutil
    try:
        return psutil.Process(run["pid"]).create_time() == run["started"]
    except (psutil.Error, KeyError, TypeError):
        return False


class ProjectStore:
    """One atomic JSON document per project; no transcript or credential collection."""

    def __init__(self, path):
        self.path = Path(path)
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ValueError("Project storage cannot follow symlinks.")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            with db:
                yield db
        finally:
            db.close()

    def get(self, key):
        with self.connect() as db:
            row = db.execute("SELECT data FROM projects WHERE id=?", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def change(self, key, fn):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT data FROM projects WHERE id=?", (key,)).fetchone()
            data = json.loads(row[0]) if row else None
            data = fn(data)
            data["updated_at"] = time.time()
            raw = json.dumps(data, ensure_ascii=False)
            if len(raw.encode()) > 2_000_000:
                raise ValueError("Project state is full; preserve it and start a linked project.")
            db.execute("INSERT INTO projects VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", (key, raw))
        return data

    def ensure(self, scope_id, chat_id, thread_id, owner_id, text):
        key = identity(scope_id, chat_id, thread_id, owner_id)
        def create(data):
            return data or {"id": key, "scope_id": scope_id, "chat_id": chat_id,
                            "thread_id": thread_id, "owner_id": owner_id,
                            "title": " ".join(text.split())[:60] or "새 프로젝트",
                            "goal": text[:2000], "status": "open", "tasks": [],
                            "decisions": [], "facts": [], "approvals": [], "created_at": time.time()}
        return self.change(key, create)

    def visited(self, key, profile, message_id):
        def update(data):
            handoff = data.get("handoff")
            if handoff and message_id != handoff["requested_message_id"]:
                handoff.setdefault("responded_message_id", message_id)
            data.update(current_profile=profile, last_message_id=message_id)
            return data
        return self.change(key, update)

    def task(self, key, profile, title, request_id, *, depends_on=()):
        task_id = hashlib.sha256(f"{key}:{request_id}:{profile}:{title}".encode()).hexdigest()[:16]
        def add(data):
            if data is None:
                raise ValueError("Unknown project.")
            if any(t["id"] == task_id for t in data["tasks"]):
                return data
            known = {t["id"] for t in data["tasks"]}
            if not set(depends_on) <= known:
                raise ValueError("Dependencies must belong to this project.")
            data["status"] = "open"
            data["tasks"].append({"id": task_id, "profile": profile, "title": title[:200],
                                  "request_id": request_id, "status": "pending", "summary": "",
                                  "next_step": "", "references": [],
                                  "depends_on": list(depends_on), "receipts": [], "revision": 1})
            return data
        return self.change(key, add), task_id

    def update_task(self, key, task_id, profile, status, summary, *, receipt=None, next_step="", references=()):
        if status not in {"pending", "running", "blocked", "completed", "cancelled", "unknown", "recorded"}:
            raise ValueError("Invalid task status.")
        def update(data):
            task = next(t for t in data["tasks"] if t["id"] == task_id)
            if task["profile"] != profile:
                raise ValueError("Only the assigned profile may update its task.")
            if status == "running":
                done = {t["id"] for t in data["tasks"] if dependency_ready(t)}
                if not set(task["depends_on"]) <= done:
                    raise ValueError("Prerequisites are not complete.")
            for item in (receipt if isinstance(receipt, list) else [receipt] if receipt else []):
                if item not in task["receipts"]:
                    task["receipts"].append(item)
            if status == "completed" and not task["receipts"]:
                raise ValueError("Completion requires an observed tool receipt.")
            if status == "running":
                task["run"] = run_identity()
            task.update(status=status, summary=summary[:2000], next_step=next_step[:1000], revision=task["revision"] + 1)
            for reference in references:
                if reference not in task.setdefault("references", []):
                    task["references"].append(reference)
            return data
        return self.change(key, update)

    def accept_report(self, key, task_id, profile, message_id):
        def update(data):
            task = next(t for t in data["tasks"] if t["id"] == task_id)
            report = task.get("consult", {})
            if task["status"] != "recorded" or report.get("status") != "reported" or not report.get("report"):
                raise ValueError("Only a returned consultation report can be accepted.")
            task["accepted_report"] = {"profile": profile, "message_id": message_id,
                "digest": hashlib.sha256(report["report"].encode()).hexdigest()}
            return data
        return self.change(key, update)

    def handoff(self, key, task_id, profile, message_id):
        def update(data):
            task = next(t for t in data["tasks"] if t["id"] == task_id)
            if task["profile"] == profile or task["status"] != "pending":
                raise ValueError("Handoff requires another worker's unstarted task.")
            if not set(task["depends_on"]) <= {t["id"] for t in data["tasks"] if dependency_ready(t)}:
                raise ValueError("Prerequisites are not complete or accepted.")
            if any(a.get("task_id") == task_id for a in data.get("approvals", [])):
                raise ValueError("A task with approval history must stay with its existing owner workflow.")
            data["handoff"] = {"task_id": task_id, "profile": task["profile"], "from_profile": profile,
                "requested_message_id": message_id, "expires_at": time.time() + 3600}
            return data
        return self.change(key, update)

    def decision(self, key, text, owner_quote, message_id, *, kind="decision"):
        def update(data):
            value = {"text": text[:1000], "owner_quote": owner_quote[:1000], "message_id": message_id}
            items = data.setdefault("facts" if kind == "fact" else "decisions", [])
            if value not in items:
                items.append(value)
            return data
        return self.change(key, update)

    def rename(self, key, title, goal=None):
        if not title.strip() or len(title) > 100:
            raise ValueError("Project title must contain 1–100 characters.")
        def update(data):
            data["title"] = title
            if goal is not None:
                data["goal"] = goal[:2000]
            return data
        return self.change(key, update)

    def close(self, key):
        self.recover(key)
        def update(data):
            if any(a["status"] in {"pending", "approved", "executing", "unknown"} for a in data.get("approvals", [])):
                raise ValueError("Resolve outstanding approvals before closing the project.")
            if any(t["status"] not in {"completed", "cancelled", "recorded"} for t in data["tasks"]):
                raise ValueError("Resolve unfinished tasks before closing the project.")
            data["status"] = "completed"
            return data
        return self.change(key, update)

    def preview(self, key, profile, tool, args, preview, task_id=None, request_id=""):
        digest = call_digest(tool, args)
        approval_id = hashlib.sha256(f"{key}:{profile}:{digest}:{request_id}".encode()).hexdigest()[:16]
        def update(data):
            items = data.setdefault("approvals", [])
            for old in items:
                if old["id"] == approval_id and old["status"] in {"pending", "approved", "executing", "done", "unknown"}:
                    return data
            # A revised preview of the same step revokes its earlier version.
            if task_id:
                for old in items:
                    if old.get("task_id") == task_id and old["status"] in {"pending", "approved"}:
                        old["status"] = "superseded"
            items.append({"id": approval_id, "profile": profile, "tool": tool, "digest": digest,
                          "task_id": task_id, "preview": preview, "preview_text": json.dumps(preview, ensure_ascii=False, indent=2), "status": "pending",
                          "expires_at": time.time() + 3600, "message_id": ""})
            return data
        return self.change(key, update)

    def choose(self, key, approval_id, choice, message_id):
        def update(data):
            approval = next(a for a in data.get("approvals", []) if a["id"] == approval_id)
            if approval["status"] != "pending" or approval["expires_at"] < time.time():
                raise ValueError("Approval is expired, changed, or already used.")
            approval.update(status="approved" if choice == "승인" else "denied", message_id=message_id)
            return data
        return self.change(key, update)

    def claim_write(self, key, profile, tool, args, message_id):
        """A one-shot supplement to native tool approvals, never a replacement."""
        digest = call_digest(tool, args)
        def update(data):
            candidates = [a for a in data.get("approvals", []) if a["profile"] == profile and a["tool"] == tool]
            if not candidates:
                return data  # Existing tool-specific approval policies remain authoritative.
            match = next((a for a in reversed(candidates) if a["digest"] == digest and a["status"] == "approved" and a["message_id"] == message_id), None)
            if not match or match["status"] != "approved" or match["message_id"] != message_id or match["expires_at"] < time.time():
                raise ValueError("Approve this exact preview in this project before executing it.")
            match["status"] = "executing"
            match["run"] = run_identity()
            return data
        return self.change(key, update)

    def settle_write(self, key, profile, tool, args, success):
        digest = call_digest(tool, args)
        def update(data):
            for approval in data.get("approvals", []):
                if approval["profile"] == profile and approval["digest"] == digest and approval["status"] == "executing":
                    approval["status"] = "done" if success else "unknown"
            return data
        return self.change(key, update)

    def interrupted_writes(self, key, profile, message_id):
        def update(data):
            for approval in data.get("approvals", []):
                if approval["profile"] == profile and approval["message_id"] == message_id and approval["status"] == "executing":
                    approval["status"] = "unknown"
            return data
        return self.change(key, update)

    def recover(self, key):
        def update(data):
            for task in data["tasks"]:
                if task["status"] == "running" and not run_alive(task.get("run", {})):
                    task.update(status="unknown", next_step="이전 실행이 중단됐다. 원본 확인 후 이어간다.")
            for approval in data.get("approvals", []):
                if approval["status"] in {"pending", "approved"} and approval["expires_at"] < time.time():
                    approval["status"] = "expired"
                if approval["status"] == "executing" and not run_alive(approval.get("run", {})):
                    approval["status"] = "unknown"
            return data
        return self.change(key, update)

    def reconcile(self, key, approval_id, profile, quote, message_id):
        def update(data):
            approval = next(a for a in data["approvals"] if a["id"] == approval_id)
            if approval["profile"] != profile or approval["status"] != "unknown":
                raise ValueError("Only the assigned profile can resolve an uncertain approval.")
            approval.update(status="resolved", resolution={"owner_quote": quote, "message_id": message_id})
            return data
        return self.change(key, update)
