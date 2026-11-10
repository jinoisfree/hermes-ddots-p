"""Linked work execution with injected account, scope and approval services."""
from __future__ import annotations
import uuid
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo
from dataclasses import dataclass

PERSONAL_ROLLBACK_WINDOW_SECONDS = 1800

@dataclass(frozen=True)
class Services:
    """One call's dependencies. No profile or gateway modules are imported here."""
    APPLE_NOTES_DIRECT_MUTATION_SCHEMA: Any
    CALENDAR_DIRECT_MUTATION_SCHEMA: Any
    COMMON_WORK_DB: Any
    CommonWorkError: Any
    CommonWorkStore: Any
    PERSONAL_ROLLBACK_WINDOW_SECONDS: Any
    _BUNDLE_ARGUMENT_ALIASES: Any
    _BUNDLE_IGNORED_ARGUMENTS: Any
    _FILE_READ_SCOPES: Any
    _KNOWLEDGE_REF_MUTATION_TYPES: Any
    _NOTE_RENAME_SUMMARY_REQUIRED: Any
    _PERSONAL_ROLLBACK_LOCK: Any
    _PERSONAL_ROLLBACK_RETENTION_SECONDS: Any
    _append_personal_rollback_entry: Any
    _apple_notes_direct_mutation: Any
    _apply_bundle_argument_aliases: Any
    _bundle_argument_names: Any
    _bundle_completes: Any
    _bundle_completion: Any
    _bundle_digest: Any
    _bundle_key: Any
    _bundle_native_source: Any
    _calendar_alarm_error: Any
    _calendar_direct_mutation: Any
    _calendar_identity_error: Any
    _clear_pending_personal_owner: Any
    _clear_personal_rollback: Any
    _common_work_complete: Any
    _common_work_error: Any
    _common_work_profile: Any
    _common_work_store: Any
    _company_notion_page: Any
    _error: Any
    _home_profile: Any
    _is_executor: Any
    _latest_personal_rollback_entry: Any
    _link_bundle_sources: Any
    _lookup_common_work_source: Any
    _messages_lookup_in_request: Any
    _normalize_calendar_dates: Any
    _normalize_common_work_domain: Any
    _normalize_personal_bundle_args: Any
    _note_snapshot: Any
    _notes_create_folder: Any
    _notes_reuse_source: Any
    _personal_actor: Any
    _personal_executor: Any
    _personal_owner_error: Any
    _personal_role_problem: Any
    _personal_rollback_conversation: Any
    _personal_rollback_path: Any
    _preserve_note_context: Any
    _read_personal_rollback_journal: Any
    _request_scope_marked: Any
    _require_common_work_access: Any
    _require_knowledge_ref_access: Any
    _save_personal_rollback: Any
    _select_personal_rollback: Any
    _structured_note_body: Any
    _task_capture_owner_chat: Any
    _validate_bundle: Any
    _web_read_in_request: Any
    _write_personal_rollback_journal: Any
    get_session_env: Any
    host: Any
    mail_work: Any
    obsidian_notes: Any
    personal_roles: Any
    personal_scopes: Any
    team: Any
    vault: Any
    work_capture: Any


def _bundle_digest(services, args: dict[str, Any]) -> str:
    canonical = json.dumps(args, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

def _normalize_personal_bundle_args(services, args: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(args)
    normalized_operations = []
    for raw in args.get("operations") or []:
        if not isinstance(raw, dict):
            normalized_operations.append(raw)
            continue
        operation = dict(raw)
        arguments = dict(raw.get("arguments") or {}) if isinstance(raw.get("arguments"), dict) else raw.get("arguments")
        rollback_arguments = (
            dict(raw.get("rollback_arguments") or {})
            if isinstance(raw.get("rollback_arguments"), dict)
            else raw.get("rollback_arguments")
        )
        domain = services._normalize_common_work_domain(raw.get("domain"))
        action = str(raw.get("action") or "").strip().lower()
        if isinstance(arguments, dict) and domain == "notes" and action == "move":
            source_id = arguments.pop("source_id", "") or arguments.get("note_id", "")
            target_folder = (
                arguments.pop("destination_folder", "")
                or arguments.pop("target_folder", "")
                or arguments.get("folder", "")
            )
            arguments["note_id"] = source_id
            arguments["folder"] = target_folder
        for payload in (arguments, rollback_arguments):
            if isinstance(payload, dict):
                services._apply_bundle_argument_aliases(domain, payload)
                if domain == "calendar":
                    # Validation below reports errors; successful values also define the approval digest.
                    services._normalize_calendar_dates(payload, action)
        if (normalized.get('task_capture') is True and domain == 'calendar' and action == 'create'
                and isinstance(arguments, dict) and arguments.get('all_day') is True):
            arguments.pop('clear_alarms', None)
            arguments['alarms'] = []
        target_key = {"calendar": "event_id", "notes": "note_id"}.get(domain)
        if target_key and action in {"update", "move"} and isinstance(arguments, dict):
            if domain == "notes" and action == "update" and not isinstance(rollback_arguments, dict):
                rollback_arguments = {}  # the executor snapshots the note itself
            if isinstance(rollback_arguments, dict) and not str(rollback_arguments.get(target_key) or "").strip():
                rollback_arguments[target_key] = arguments.get(target_key, "")
        if isinstance(arguments, dict) and domain == "notes" and action in {"create", "update"}:
            preview_summary = str(arguments.get("preview_summary") or "").strip()
            summary = str(arguments.get("summary") or "").strip()
            original_text = str(arguments.get("original_text") or "")
            if preview_summary and summary and (original_text.strip() or services._notes_reuse_source(action, arguments)):
                arguments["body"] = services._structured_note_body(summary, original_text, preview_summary)
        if isinstance(arguments, dict) and action == "create":
            if domain == "notes":
                scoped = services.personal_scopes.config(services.host)
                if scoped is not None and not scoped.get('invalid') and services.team.has_role(services.personal_roles.profile(services.host), 'personal'):
                    arguments.setdefault('folder', scoped['personal']['notes_folder'])
                else:
                    arguments['folder'] = services._notes_create_folder(str(arguments.get('folder') or ''))
        operation["arguments"] = arguments
        if isinstance(rollback_arguments, dict):
            if domain == "notes" and action == "move":
                rollback_arguments["note_id"] = (
                    rollback_arguments.pop("source_id", "")
                    or rollback_arguments.get("note_id", "")
                    or arguments.get("note_id", "")
                )
            if domain == "notes" and action == "update":
                rollback_preview = str(rollback_arguments.get("preview_summary") or "").strip()
                rollback_summary = str(rollback_arguments.get("summary") or "").strip()
                rollback_original = str(rollback_arguments.get("original_text") or "")
                if rollback_preview and rollback_summary and rollback_original.strip():
                    rollback_arguments["body"] = services._structured_note_body(
                        rollback_summary, rollback_original, rollback_preview,
                    )
            operation["rollback_arguments"] = rollback_arguments
        operation["action"] = action
        normalized_operations.append(operation)
    if "operations" in args:
        normalized["operations"] = normalized_operations
    return normalized

def _bundle_key(services, payload_digest: str) -> str:
    identity = {
        "platform": services.get_session_env("HERMES_SESSION_PLATFORM", "").strip(),
        "scope_id": services.get_session_env("HERMES_SESSION_SCOPE_ID", "").strip(),
        "chat_id": services.get_session_env("HERMES_SESSION_CHAT_ID", "").strip(),
        "thread_id": services.get_session_env("HERMES_SESSION_THREAD_ID", "").strip(),
        "user_id": services.get_session_env("HERMES_SESSION_USER_ID", "").strip(),
        "message_id": services.get_session_env("HERMES_SESSION_MESSAGE_ID", "").strip(),
    }
    if not identity["message_id"]:
        identity["message_id"] = services.get_session_env("HERMES_SESSION_ID", "").strip()
    canonical = json.dumps(identity, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(f"{canonical}\x1f{payload_digest}".encode("utf-8")).hexdigest()

def _apply_bundle_argument_aliases(services, domain: str, payload: dict[str, Any]) -> None:
    for alias, canonical in services._BUNDLE_ARGUMENT_ALIASES.get(domain, {}).items():
        if alias in payload:
            value = payload.pop(alias)
            if canonical not in payload or payload[canonical] in (None, ""):
                payload[canonical] = value
    for ignored in services._BUNDLE_IGNORED_ARGUMENTS.get(domain, set()):
        payload.pop(ignored, None)

def _bundle_argument_names(services, domain: str) -> set[str]:
    schema = {
        "calendar": services.CALENDAR_DIRECT_MUTATION_SCHEMA,
        "notes": services.APPLE_NOTES_DIRECT_MUTATION_SCHEMA,
    }[domain]
    names = set(schema["parameters"]["properties"]) - {"action", "approved", "common_id"}
    return names | ({"body"} if domain == "notes" else set())

def _validate_bundle(services, args: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, str]], str | None]:
    title = str(args.get("title") or "").strip()
    if not title:
        return [], [], "bundle title is required"
    raw_operations = args.get("operations") or []
    raw_sources = args.get("existing_sources") or []
    if not raw_operations and not raw_sources:
        return [], [], "bundle requires operations or existing_sources"
    if len(raw_operations) > 20 or len(raw_sources) > 20:
        return [], [], "bundle supports at most 20 operations and 20 existing sources"

    allowed_actions = {
        "calendar": {"create", "update", "delete"},
        "notes": {"create", "update", "move", "delete"},
    }
    operations: list[dict[str, Any]] = []
    for index, raw in enumerate(raw_operations):
        if not isinstance(raw, dict) or not isinstance(raw.get("arguments"), dict):
            return [], [], f"invalid bundle operation at index {index}"
        domain = services._normalize_common_work_domain(raw.get("domain"))
        action = str(raw.get("action") or "").strip().lower()
        if domain not in allowed_actions or action not in allowed_actions[domain]:
            return [], [], f"invalid {domain or 'unknown'} bundle action: {action or '<empty>'}"
        arguments = dict(raw["arguments"])
        rollback_arguments = raw.get("rollback_arguments")
        if domain == "calendar":
            if error := services._calendar_alarm_error(arguments, action):
                return [], [], error
            if error := services._normalize_calendar_dates(arguments, action):
                return [], [], error
            if isinstance(rollback_arguments, dict):
                rollback_arguments = dict(rollback_arguments)
                if error := services._calendar_alarm_error(rollback_arguments, action):
                    return [], [], f"calendar rollback: {error}"
                if error := services._normalize_calendar_dates(rollback_arguments, action):
                    return [], [], f"calendar rollback: {error}"
            if error := services._calendar_identity_error(arguments, action):
                return [], [], error
        if any(key in arguments for key in {"approved", "common_id", "_skip_common_work"}):
            return [], [], "bundle operation contains reserved approval or linkage fields"
        unknown = sorted(set(arguments) - services._bundle_argument_names(domain))
        if unknown:
            # Unknown names used to be dropped silently while the bundle still reported success.
            return [], [], (
                f"{domain} {action} has unsupported argument(s) {', '.join(unknown)}; "
                f"use only: {', '.join(sorted(services._bundle_argument_names(domain)))}"
            )
        if domain == "notes" and action in {"create", "update"}:
            preview_summary = str(arguments.get("preview_summary") or "").strip()
            summary = str(arguments.get("summary") or "").strip()
            original_text = str(arguments.get("original_text") or "")
            if action == "update" and arguments.get("rename_title") is True and (not preview_summary or not summary):
                return [], [], services._NOTE_RENAME_SUMMARY_REQUIRED
            if not preview_summary or not summary or (not original_text.strip() and not services._notes_reuse_source(action, arguments)):
                return [], [], "notes create/update requires preview_summary, summary, and original_text"
            if "\n" in preview_summary or len(preview_summary) > 140:
                return [], [], "notes preview_summary must be one line and at most 140 characters"
            if arguments.get("body") != services._structured_note_body(summary, original_text, preview_summary):
                return [], [], "notes body must be assembled from preview_summary, summary, and original_text"
            attachments = arguments.get("attachments", [])
            if not isinstance(attachments, list) or len(attachments) > 10:
                return [], [], "notes attachments must be an array of at most 10 paths"
            if any(not isinstance(path, str) or not path.strip() for path in attachments):
                return [], [], "notes attachments must contain non-empty paths"
        if action in {"update", "move"}:
            if not isinstance(rollback_arguments, dict) or not rollback_arguments:
                return [], [], f"{domain} {action} requires rollback_arguments"
            target_key = {"calendar": "event_id", "notes": "note_id"}[domain]
            target_id = str(arguments.get(target_key) or "").strip()
            rollback_target_id = str(rollback_arguments.get(target_key) or "").strip()
            if not target_id:
                return [], [], (
                    f"{domain} {action} needs {target_key} in arguments: pass the id of the item to change "
                    "exactly as returned by the lookup"
                )
            if rollback_target_id != target_id:
                return [], [], f"{domain} {action} rollback target must match the forward target"
        elif rollback_arguments not in (None, {}):
            return [], [], f"{domain} {action} does not accept rollback_arguments"
        operation = {"domain": domain, "action": action, "arguments": arguments}
        if isinstance(rollback_arguments, dict):
            operation["rollback_arguments"] = dict(rollback_arguments)
        operations.append(operation)

    delete_flags = [operation["action"] == "delete" for operation in operations]
    if any(delete_flags) and not all(delete_flags):
        return [], [], "deletions cannot be mixed with create, update, or move"
    if any(delete_flags) and raw_sources:
        return [], [], "deletion bundles cannot add existing Common ID sources"

    sources: list[dict[str, str]] = []
    for index, raw in enumerate(raw_sources):
        if not isinstance(raw, dict):
            return [], [], f"invalid existing source at index {index}"
        domain = services._normalize_common_work_domain(raw.get("domain"))
        source_id = str(raw.get("source_id") or "").strip()
        if domain not in {"calendar", "notes"} or not source_id:
            return [], [], f"invalid existing source at index {index}"
        if domain == "notes" and source_id.isdecimal():
            return [], [], "Notes list indexes are not stable source IDs"
        sources.append({"domain": domain, "source_id": source_id})
    return operations, sources, None


def _bundle_plan_lines(services, operations: list[dict[str, Any]]) -> str:
    """One readable line per operation for the approval gate."""
    domains = {"calendar": "일정", "notes": "메모"}
    actions = {"create": "생성", "update": "수정", "move": "이동", "delete": "삭제"}
    lines = []
    for operation in operations:
        arguments = operation.get("arguments") or {}
        title = str(arguments.get("title") or arguments.get("note_id")
                    or arguments.get("event_id") or "(제목 없음)").strip()
        details = [
            f"{label} {str(arguments[key]).strip()}"
            for key, label in (("start", "시작"), ("folder", "폴더"))
            if str(arguments.get(key) or "").strip()
        ]
        line = (f"- {domains.get(operation['domain'], operation['domain'])} "
                f"{actions.get(operation['action'], operation['action'])}: {title}")
        lines.append(f"{line} ({', '.join(details)})" if details else line)
    return "\n".join(lines)

def _bundle_native_source(services,
    domain: str, action: str, arguments: dict[str, Any], result: dict[str, Any]
) -> dict[str, str] | None:
    if action == "delete":
        return None
    payload = result.get("result") if isinstance(result.get("result"), dict) else {}
    if isinstance(payload.get("after"), dict):
        # EventKit receipts nest the created/updated event under "after".
        payload = {**payload["after"], **{k: v for k, v in payload.items() if k != "after"}}
    target_id = str(result.get("target_id") or "").strip()
    keys = {
        "calendar": ("calendarItemIdentifier", "event_id", "id"),
        "notes": ("note_id", "stableNoteIdentifier", "id"),
    }[domain]
    source_id = target_id or next(
        (str(payload.get(key) or "").strip() for key in keys if payload.get(key)), "",
    )
    if not source_id:
        argument_key = {"calendar": "event_id", "notes": "note_id"}[domain]
        source_id = str(arguments.get(argument_key) or "").strip()
    return {"domain": domain, "source_id": source_id} if source_id else None

def _personal_rollback_path(services) -> Path:
    from hermes_constants import get_hermes_home
    from hermes_governance.app_undo import path_for
    return path_for(get_hermes_home())


def _rollback_partition(services):
    from hermes_governance.app_undo import partition, legacy_paths
    from hermes_constants import get_hermes_home
    return partition(services._personal_rollback_path(), 'personal',
                     legacy=legacy_paths(get_hermes_home()))


def _read_personal_rollback_journal(services) -> dict[str, Any]:
    with _rollback_partition(services) as (data, save): return data


def _write_personal_rollback_journal(services, payload: dict[str, Any]) -> None:
    with _rollback_partition(services) as (data, save):
        data['entries'] = payload['entries']
        save()


def _personal_rollback_conversation(services) -> dict[str, str]:
    """Thread-agnostic identity: Slack opens a thread per top-level message, so a rollback posted as a
    new message must still find changes made from earlier threads of the same channel and user."""
    return {
        "platform": services.get_session_env("HERMES_SESSION_PLATFORM", "").strip().lower(),
        "scope_id": services.get_session_env("HERMES_SESSION_SCOPE_ID", "").strip(),
        "chat_id": services.get_session_env("HERMES_SESSION_CHAT_ID", "").strip(),
        "user_id": services.get_session_env("HERMES_SESSION_USER_ID", "").strip(),
        "session_id": (
            "" if services.get_session_env("HERMES_SESSION_CHAT_ID", "").strip()
            else services.get_session_env("HERMES_SESSION_ID", "").strip()
        ),
    }

def _append_personal_rollback_entry(services, entry: dict[str, Any]) -> None:
    with services._PERSONAL_ROLLBACK_LOCK, _rollback_partition(services) as (journal, save):
        now = time.time()
        journal["version"] = 2
        journal["entries"] = [
            item for item in journal["entries"]
            if isinstance(item, dict)
            and now - float(item.get("created_at") or 0) < services._PERSONAL_ROLLBACK_RETENTION_SECONDS
        ]
        replacements = {op.get("arguments", {}).get("reconstruction", {}).get("new_id")
                        for op in entry.get("operations", [])} - {None}
        for previous in journal["entries"]:
            if previous.get("conversation") == services._personal_rollback_conversation() and replacements:
                previous["operations"] = [op for op in previous.get("operations", [])
                    if op.get("arguments", {}).get("reconstruction", {}).get("new_id") not in replacements]
                if not previous["operations"]:
                    previous["consumed"] = True
        journal["entries"].append({
            "conversation": services._personal_rollback_conversation(),
            "created_at": now,
            "consumed": False,
            **entry,
        })
        save()

def _save_personal_rollback(services, title: str, bundle_key: str, operations: list[dict[str, Any]]) -> None:
    services._append_personal_rollback_entry({
        "title": str(title), "bundle_key": str(bundle_key), "operations": operations,
    })

def _clear_personal_rollback(services, title: str = "") -> None:
    """Record a change that cannot be undone (e.g. a deletion) so rollback stops there instead of
    silently reverting something older behind it."""
    services._append_personal_rollback_entry({"title": str(title), "barrier": True, "operations": []})

def _latest_personal_rollback_entry(services,
    journal: dict[str, Any], *, window: float = PERSONAL_ROLLBACK_WINDOW_SECONDS,
) -> dict[str, Any] | None:
    conversation = services._personal_rollback_conversation()
    now = time.time()
    for entry in reversed(journal.get("entries") or []):
        if (
            isinstance(entry, dict)
            and entry.get("conversation") == conversation
            and entry.get("consumed") is not True
            and 0 <= now - float(entry.get("created_at") or 0) < window
        ):
            return entry
    return None


def _select_personal_rollback(services,
    journal: dict[str, Any], args: dict[str, Any],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Read-only selection/preview; never mutate a journal or call native tools."""
    if set(args) - {"bundle_key"} or ("bundle_key" in args and (
        not isinstance(args["bundle_key"], str) or not args["bundle_key"].strip()
    )):
        return None, {"ok": False, "error": "INVALID_ROLLBACK_ARGUMENTS"}
    from hermes_governance import bundle_undo
    chosen=bundle_undo.selected()
    if chosen is not None:
        entry=next((e for e in journal['entries'] if e.get('key')==chosen),None)
        if entry is None or not entry.get('app_ready') or entry.get('consumed'):
            return None, {'ok':False,'error':'APP_BUNDLE_CHANGE_UNVERIFIED'}
        return entry,None
    entry = services._latest_personal_rollback_entry(journal, window=services._PERSONAL_ROLLBACK_RETENTION_SECONDS)
    if entry is None:
        return None, {"ok": False, "error": "NO_RECENT_PERSONAL_WORK_ROLLBACK"}
    if entry.get("barrier"):
        return None, {
            "ok": False, "work_type": "personal_work_rollback", "owner_profile": services._personal_actor(),
            "error": "LATEST_CHANGE_NOT_REVERSIBLE", "title": entry.get("title"),
            "detail": "The most recent change (such as a deletion) cannot be undone, so older changes stay as they are.",
        }
    if "bundle_key" in args and args["bundle_key"] != entry.get("bundle_key"):
        return None, {"ok": False, "error": "ROLLBACK_BUNDLE_KEY_NOT_LATEST"}
    if not entry.get("operations"):
        return None, {"ok": False, "error": "LATEST_CHANGE_NOT_REVERSIBLE"}
    age = time.time() - float(entry["created_at"])
    if "bundle_key" not in args and age >= services.PERSONAL_ROLLBACK_WINDOW_SECONDS:
        return None, {
            "ok": False, "error": "OLDER_CHANGE_NEEDS_CONFIRMATION", "mutation_calls": 0,
            "bundle_key": entry.get("bundle_key"), "title": entry.get("title"),
            "changed_at": datetime_type.fromtimestamp(float(entry["created_at"]), ZoneInfo("Asia/Seoul")).strftime("%Y-%m-%d %H:%M"),
            "elapsed_minutes": int(age // 60),
            "targets": [{"domain": op["domain"], "action": op["action"]}
                        for op in entry["operations"]],
        }
    return entry, None

def _personal_work_rollback(services, args: dict[str, Any], **context: Any) -> str:
    if services.personal_roles.enabled(services.host):
        if problem := services._personal_owner_error('personal_work_rollback'):
            return problem
    with services._PERSONAL_ROLLBACK_LOCK, _rollback_partition(services) as (journal, save):
        entry, error = services._select_personal_rollback(journal, args)
        if error is not None:
            return json.dumps(error, ensure_ascii=False)
        operations = list(entry.get("operations") or [])

        handlers = {
            "calendar": services._calendar_direct_mutation,
            "notes": services._apple_notes_direct_mutation,
        }
        runner = context.get("runner")
        results: list[dict[str, Any]] = []
        remaining: list[dict[str, Any]] = []
        skipped = 0
        for index, operation in enumerate(operations):
            if operation.get("domain") not in handlers:
                # 2026-10-31: the Reminders feature was removed; an old entry is never replayed natively.
                skipped += 1
                results.append({"index": index, "domain": operation.get("domain"), "action": operation.get("action"),
                                "receipt": {"ok": False, "error": "REMOVED_DOMAIN: 이 종류의 변경은 더 이상 되돌리지 않는다."}})
                continue
            if operation.get("native_done"):
                result = {"ok": True, "native_mutation_skipped": True}
            elif operation.get('component') is not None:
                from hermes_constants import get_hermes_home
                from hermes_governance import bundle_undo
                try:result=bundle_undo.restore_change(get_hermes_home(),services.host,operation,entry,save,context)
                except (ValueError,OSError,KeyError) as error:result={'ok':False,'error':str(error)}
            else:
                native_args = {
                    **dict(operation["arguments"]),
                    "action": operation["action"],
                    "approved": True,
                    "_skip_common_work": True,
                    "_rollback": True,
                }
                raw = handlers[operation["domain"]](native_args, runner=runner)
                try:
                    result = json.loads(raw)
                except (TypeError, ValueError):
                    result = {"ok": False, "error": "native rollback returned invalid JSON"}
            results.append({
                "index": index,
                "domain": operation["domain"],
                "action": operation["action"],
                "receipt": result,
            })
            if result.get("ok") is not True:
                remaining.append(operation)
                continue
            if operation.get('component') is not None:
                operation['native_done']=True
                save()  # Cleanup failure must not execute the native inverse twice.
            if operation.get("unlink_created_source"):
                target_key = {
                    "calendar": "event_id", "notes": "note_id",
                }[operation["domain"]]
                try:
                    services._common_work_store().rollback_unlink_source(
                        domain=operation["domain"],
                        source_id=str(operation["arguments"].get(target_key) or ""),
                    )
                except (services.CommonWorkError, sqlite3.Error) as exc:
                    result["common_work_cleanup_error"] = str(exc)
                    retry_operation = dict(operation)
                    retry_operation["native_done"] = True
                    remaining.append(retry_operation)

        entry["operations"] = remaining
        entry["consumed"] = not remaining
        entry["rolled_back_at"] = time.time() if not remaining else None
        save()  # entry is a live element of journal["entries"]
        older = services._latest_personal_rollback_entry(journal)
        return json.dumps({
            "ok": not remaining and not skipped,
            "work_type": "personal_work_rollback",
            "owner_profile": services._personal_actor(),
            "title": entry.get("title"),
            "next_rollback_candidate": (older or {}).get("title") if not remaining else None,
            "status": "completed" if not remaining and not skipped else "partial",
            "approval_calls": 0,
            "mutation_calls": len(results),
            "operations": results,
            "remaining_operations": len(remaining),
        }, ensure_ascii=False)

def _link_bundle_sources(services,
    store: CommonWorkStore,
    *,
    title: str,
    requested_common_id: str,
    sources: list[dict[str, str]],
) -> dict[str, Any] | None:
    unique_sources = list({(source["domain"], source["source_id"]): source for source in sources}.values())
    if not unique_sources:
        return None
    existing_items = [
        item for source in unique_sources
        if (item := store.find_by_source(domain=source["domain"], source_id=source["source_id"]))
    ]
    existing_ids = {item["common_id"] for item in existing_items}
    if requested_common_id:
        existing_ids.add(requested_common_id)
        store.get(requested_common_id)
    if len(existing_ids) > 1:
        raise services.CommonWorkError("bundle sources already belong to different Common IDs")
    if existing_ids:
        common_id = next(iter(existing_ids))
        for source in unique_sources:
            linked = store.find_by_source(domain=source["domain"], source_id=source["source_id"])
            if linked is None:
                store.link(
                    common_id,
                    domain=source["domain"],
                    source_id=source["source_id"],
                    link_reason="approved_mutation",
                )
            elif linked["common_id"] != common_id:
                raise services.CommonWorkError("bundle source belongs to another Common ID")
        return store.get(common_id)
    return store.create(
        title=title,
        sources=unique_sources,
        link_reason="approved_mutation",
    )

def _task_capture_owner_chat(services):
    flags = ('HERMES_CRON_SESSION', 'HERMES_SINGLE_QUERY_SESSION', 'HERMES_KANBAN_TASK')
    return (services.team.has_role(services._common_work_profile(), 'work')
            and services.get_session_env('HERMES_SESSION_PLATFORM', '') in {'slack', 'photon'}
            and bool(services.get_session_env('HERMES_SESSION_CHAT_ID', '') and services.get_session_env('HERMES_SESSION_USER_ID', ''))
            and not any(services.get_session_env(flag, '') or os.environ.get(flag) for flag in flags))

def _bundle_completes(services, args: dict[str, Any]) -> bool:
    operations = args.get("operations") or []
    return bool(operations) and all(
        isinstance(op, dict) and str(op.get("action") or "").strip().lower() == "complete"
        and services._normalize_common_work_domain(op.get("domain")) in {"notes", "calendar"}
        for op in operations
    )

def _bundle_completion(services, args: dict[str, Any]) -> str | None:
    """'complete' on memos or events means the owner finished the work (2026-10-26): finish the
    Common ID instead of failing validation and letting the model fake it with a body edit."""
    if not services._bundle_completes(args):
        return None
    common_id = str(args.get("common_id") or "").strip()
    if not common_id:
        return services._error(
            "Memos and events have no 'complete' action. For linked work call common_work_complete with "
            "its common_id; move a memo with no Common ID by apple_notes_direct_mutation(action=move, "
            "folder=complete). Do not edit the memo body to mark it done."
        )
    return services._common_work_complete({"common_id": common_id})

def _personal_work_bundle(services, args: dict[str, Any], **context: Any) -> str:
    if error := services._personal_owner_error("personal_work_bundle"):
        return error
    if 'capture' in args or 'scope_change' in args:
        try:
            result=(services.work_capture.create(services.host,args['capture'],native=context.get('capture_native'))
                    if 'capture' in args else services.work_capture.transition(services.host,args['scope_change'],native=context.get('capture_native')))
            return json.dumps(result,ensure_ascii=False)
        except (ValueError,OSError,sqlite3.Error) as exc:return services._error(str(exc),mutation_calls=0)
    normalized_args = services._normalize_personal_bundle_args(args)
    if completion := services._bundle_completion(normalized_args):
        return completion
    operations, existing_sources, validation_error = services._validate_bundle(normalized_args)
    if validation_error:
        return services._error(validation_error)

    if normalized_args.get('task_capture') is True:
        if not services._task_capture_owner_chat():
            return services._error('TASK_CAPTURE_OWNER_CHAT_REQUIRED')
        kinds = [op['domain'] for op in operations]
        if len(kinds) != len(set(kinds)) or any(op['action'] != 'create' for op in operations):
            return services._error('task capture creates at most one original per selected destination',
                          mutation_calls=0, approval_calls=0, applied=False)

    # Check every note before any other operation or execution-ledger write.
    # The mutation checks again in case files disappear after this preflight.
    for operation in operations:
        if operation["domain"] == "notes" and operation["action"] in {"create", "update"}:
            arguments = operation["arguments"]
            try:
                if operation["action"] == "create":
                    continue
                files, _ = services._preserve_note_context(
                    str(arguments.get("note_id") or ""), arguments.get("attachments") or [],
                    str(arguments.get("original_text") or ""), context.get("runner") or subprocess.run,
                    reuse_source=services._notes_reuse_source("update", arguments),
                )
            except (ValueError, TypeError) as exc:
                return services._error(str(exc))

    from hermes_constants import get_hermes_home
    from hermes_governance import bundle_undo,app_tools,write_policy
    home=get_hermes_home()
    digest = services._bundle_digest(normalized_args)
    bundle_key = services._bundle_key(digest)
    store = services._common_work_store()
    try:
        if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
        replay=store.bundle_receipt(bundle_key=bundle_key,payload_digest=digest)
        if replay is not None:return json.dumps(replay,ensure_ascii=False)
        prepared=bundle_undo.admission(home,services.host,args,operations,context)
    except (ValueError,OSError,sqlite3.Error) as error:return services._error(str(error),mutation_calls=0)
    try:
        replay = store.begin_bundle_execution(bundle_key=bundle_key, payload_digest=digest)
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._error(str(exc))
    if replay is not None:
        return json.dumps(replay, ensure_ascii=False)

    with _rollback_partition(services) as (journal,save):
        entry={'key':uuid.uuid4().hex,'created_at':time.time(),'conversation':services._personal_rollback_conversation(),
            'app_conversation':app_tools.conversation(),'title':str(normalized_args['title']),'bundle_key':bundle_key,
            'status':'pending','consumed':False,'components':[],'operations':[],'app_ready':False}
        journal['entries'].append(entry);save()
        handlers = {
            "calendar": services._calendar_direct_mutation,
            "notes": services._apple_notes_direct_mutation,
        }
        results: list[dict[str, Any]] = []
        sources = list(existing_sources)
        failures: list[dict[str, Any]] = []
        rollback_operations: list[dict[str, Any]] = []
        runner = context.get("runner")
        mutation_calls = 0
        try:
            for index, operation in enumerate(operations):
                slot={'plan':{k:v for k,v in prepared[index].items() if k!='before'}}
                if prepared[index]['kind']!=write_policy.REVERSIBLE and not (operation['domain']=='notes' and operation['action']=='update'):
                    slot['before']=prepared[index]['before']
                entry['components'].append(slot);save()
                mutation_calls += 1
                result=bundle_undo.call(home,services.host,prepared[index],slot,save,handlers[operation['domain']],context)
                slot['receipt']=result;save()
                results.append({
                    "index": index,
                    "domain": operation["domain"],
                    "action": operation["action"],
                    "receipt": result,
                })
                if result.get("ok") is not True:
                    failures.append({
                        "index": index,
                        "domain": operation["domain"],
                        "error": result.get("error") or "native mutation failed",
                    })
                    continue
                source = services._bundle_native_source(
                    operation["domain"], operation["action"], operation["arguments"], result,
                )
                if operation["action"] != "delete" and source is None:
                    failures.append({
                        "index": index,
                        "domain": operation["domain"],
                        "error": "native mutation succeeded without a stable source ID",
                    })
                elif source is not None:
                    sources.append(source)
                changes=slot.get('changes',[])
                if len(changes)==1 and changes[0].get('status')=='done' and not changes[0].get('reference_only') and source is not None:
                    target_key={'calendar':'event_id','notes':'note_id'}[operation['domain']]
                    inverse={'domain':operation['domain'],'action':'app_restore','component':index,
                        'arguments':{target_key:source['source_id']},'unlink_created_source':operation['action']=='create'}
                    rollback_operations.insert(0,inverse)
                    entry['operations']=rollback_operations;save()

        except Exception as exc:
            failures.append({"index": index, "domain": operation["domain"],
                             "error": f"native mutation raised {type(exc).__name__}; verify original state before retrying"})

        common_work = None
        if not any(operation["action"] == "delete" for operation in operations):
            try:
                common_work = services._link_bundle_sources(
                    store,
                    title=str(normalized_args["title"]),
                    requested_common_id=str(normalized_args.get("common_id") or ""),
                    sources=sources,
                )
            except (services.CommonWorkError, sqlite3.Error) as exc:
                failures.append({"domain": "common_work", "error": str(exc)})

        successful_native = sum(result["receipt"].get("ok") is True for result in results)
        rollback_available=bool(rollback_operations)
        entry['operations']=rollback_operations
        entry['barrier']=successful_native>0 and not rollback_available
        entry['status']='partial' if failures else 'done'
        entry['app_ready']=bool(rollback_operations) and not failures and all(row['kind']==write_policy.REVERSIBLE for row in prepared)
        save()
        status = (
            "completed" if not failures
            else "partial" if successful_native or (existing_sources and common_work is not None)
            else "failed"
        )
        receipt = {
            "ok": status == "completed",
            "work_type": "personal_work_bundle",
            "owner_profile": services._personal_actor(),
            "bundle_key": bundle_key,
            "payload_digest": digest,
            "status": status,
            "approval_calls": int(bundle_undo.kind(prepared) not in (write_policy.READ,write_policy.REVERSIBLE)),
            "mutation_calls": mutation_calls,
            "rollback_available": rollback_available,
            "rollback_limitations":[change['limitation'] for slot in entry['components'] for change in slot.get('changes',[]) if change.get('limitation')],
            "operations": results,
            "common_work": common_work,
            "failures": failures,
            "replayed": False,
        }
        bundle_undo.result(entry,receipt)
        try:
            store.finish_bundle_execution(
                bundle_key=bundle_key,
                payload_digest=digest,
                status=status,
                receipt=receipt,
            )
        except (services.CommonWorkError, sqlite3.Error) as exc:
            entry['app_ready']=False;entry['status']='partial';save()
            receipt.pop('undo_key',None);receipt.pop('message',None)
            receipt["ok"] = False
            receipt["status"] = "partial" if successful_native else "failed"
            receipt["failures"].append({"domain": "bundle_ledger", "error": str(exc)})
        return json.dumps(receipt, ensure_ascii=False)

def _common_work_error(services, message: str) -> str:
    return json.dumps({"ok": False, "error": message}, ensure_ascii=False)

def _common_work_profile(services) -> str:
    return (
        services.get_session_env("HERMES_SESSION_PROFILE", "")
        or os.environ.get("HERMES_PROFILE") or services._home_profile()
        or "default"
    ).strip()

def _require_common_work_access(services, *domains: str, completion: bool = False) -> str | None:
    profile = services._common_work_profile()
    if completion:
        allowed = services._is_executor(profile)
    else:
        allowed_domains = {
            services._personal_executor(): {"calendar", "notes"},
        }.get(profile, set())
        allowed = not domains or set(domains).issubset(allowed_domains)
    if allowed:
        return None
    requested = ",".join(sorted(set(domains))) or "read"
    return services._common_work_error(
        f"common work access denied for profile={profile}, domains={requested}"
    )

def _common_work_store(services) -> CommonWorkStore:
    return services.CommonWorkStore.production(services.COMMON_WORK_DB)

def _require_knowledge_ref_access(services,
    ref_type: str | None = None, *, mutation: bool = False
) -> str | None:
    profile = services._common_work_profile()
    owned_types = services.team.pick(services._KNOWLEDGE_REF_MUTATION_TYPES, profile, None)
    if services._is_executor(profile):
        owned_types = services._KNOWLEDGE_REF_MUTATION_TYPES["personal"]
    elif mutation and services.personal_roles.enabled(services.host) and services.team.has_role(profile, 'personal'):
        owned_types = None
    allowed = owned_types is not None and (
        not mutation or str(ref_type or "").strip().casefold() in owned_types
    )
    if allowed:
        return None
    requested = str(ref_type or "read")
    return services._common_work_error(
        f"knowledge reference access denied for profile={profile}, ref_type={requested}"
    )

def _common_work_create(services, args: dict[str, Any], **_: Any) -> str:
    sources = [
        {**source, "domain": services._normalize_common_work_domain(source.get("domain"))}
        for source in args.get("sources") or []
    ]
    domains = [str(source.get("domain") or "") for source in sources]
    if error := services._require_common_work_access(*domains):
        return error
    try:
        item = services._common_work_store().create(
            title=args["title"],
            sources=sources,
            link_reason=str(args.get("link_reason") or ""),
        )
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    return services.obsidian_notes.linked_receipt(services.host, item)

def _common_work_get(services, args: dict[str, Any], **_: Any) -> str:
    requested_domain = services._normalize_common_work_domain(args.get("domain"))
    if error := services._require_common_work_access(*([requested_domain] if requested_domain else [])):
        return error
    try:
        if args.get("common_id"):
            candidate = str(args["common_id"])
            store = services._common_work_store()
            try:
                item = store.get(candidate)
            except services.CommonWorkError as exc:
                if not str(exc).startswith("unknown common_id:"):
                    raise
                matches = [
                    found for domain in ("calendar", "notes")
                    if (found := store.find_by_source(domain=domain, source_id=candidate))
                ]
                if len(matches) != 1:
                    raise
                item = matches[0]
        elif args.get("domain") and args.get("source_id"):
            item = services._common_work_store().find_by_source(
                domain=requested_domain, source_id=str(args["source_id"])
            )
        else:
            return services._common_work_error("common_id or domain plus source_id is required")
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    return json.dumps({"ok": True, "item": item}, ensure_ascii=False)

def _common_work_link(services, args: dict[str, Any], **_: Any) -> str:
    source = {
        **args["source"],
        "domain": services._normalize_common_work_domain(args["source"].get("domain")),
    }
    if error := services._require_common_work_access(str(source.get("domain") or "")):
        return error
    try:
        item = services._common_work_store().link(
            str(args["common_id"]),
            domain=str(source["domain"]),
            source_id=str(source["source_id"]),
            metadata=source.get("metadata") or {},
            link_reason=str(args.get("link_reason") or ""),
        )
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    return services.obsidian_notes.linked_receipt(services.host, item)

def _company_notion_page(services, identifier):
    import importlib.util
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home())
    from hermes_packs.notion import load_api
    api = load_api('_capture_notion_reader')
    page = api.request(home, 'GET', 'pages/' + api.object_id(identifier))
    if (str(page.get('parent', {}).get('database_id', '')).replace('-', '') != services.vault.text('notion.work_db', '(owner-vault-notion-work-db-unset)').replace('-', '') or page.get('archived') or page.get('in_trash')):
        raise services.CommonWorkError('active company Notion page required')
    return page

def _knowledge_ref_link(services, args: dict[str, Any], **_: Any) -> str:
    ref_type = str(args.get("ref_type") or "").strip().casefold()
    if error := services._require_knowledge_ref_access(ref_type, mutation=True):
        return error
    if (
        args.get("link_reason") == "explicit_existing_object_link"
        and args.get("approved") is not True
    ):
        return json.dumps({
            "ok": False,
            "approval_required": True,
            "required_user_message": "승인",
            "preview": {
                "common_id": args.get("common_id"),
                "ref_type": ref_type,
                "external_id": args.get("external_id"),
                "relation_type": args.get("relation_type"),
            },
        }, ensure_ascii=False)
    new_title = str(args.get('new_work_title') or '').strip()
    common_id = str(args.get('common_id') or '').strip()
    if not common_id:
        if (not services._task_capture_owner_chat() or not new_title or ref_type != 'notion_page'
                or args.get('link_reason') != 'verified_workflow_evidence'
                or services._personal_role_problem('personal_work_bundle', args)):
            return services._common_work_error(f"verified {services.team.first_with('work')} task registration required")
        try:
            page = services._company_notion_page(args['external_id'])
            titles = [v['title'] for v in page.get('properties', {}).values() if 'title' in v]
            if len(titles) != 1 or ''.join(v.get('plain_text', v.get('text', {}).get('content', '')) for v in titles[0]) != new_title:
                return services._common_work_error('Notion title does not match registered work')
        except (OSError, ValueError, KeyError, RuntimeError) as exc:
            return services._common_work_error(str(exc))
    try:
        item = services._common_work_store().link_knowledge_ref(
            common_id,
            ref_type=ref_type,
            external_id=str(args["external_id"]),
            relation_type=str(args["relation_type"]),
            link_reason=str(args["link_reason"]),
            source_session_id=args.get("source_session_id"),
            receipt_id=args.get("receipt_id"),
            metadata=args.get("metadata") or {},
            **({'new_work_title': new_title} if not common_id else {}),
        )
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    if ref_type == 'notion_page':
        try:
            for source in item.get('sources', []):
                if source['domain'] == 'notes' and services.obsidian_notes.handles(source['source_id']):
                    row = services.obsidian_notes.disk.Store().read(source['source_id'])
                    services.obsidian_notes.sync_properties(services.host, row, item)
        except Exception as exc:
            return json.dumps({'ok': False, 'item': item, 'linked': True,
                               'error': 'Notion 연결은 완료됐으나 메모 속성 확인 필요: '+str(exc)}, ensure_ascii=False)
    return json.dumps({"ok": True, "item": item}, ensure_ascii=False)

def _knowledge_ref_get(services, args: dict[str, Any], **_: Any) -> str:
    if error := services._require_knowledge_ref_access():
        return error
    common_id = str(args.get("common_id") or "").strip()
    if not common_id:
        return services._common_work_error("common_id is required")
    try:
        store = services._common_work_store()
        item = store.get(common_id)
        if args.get("include_unlinked") is True:
            item["knowledge_refs"] = store.list_knowledge_refs(
                common_id, include_unlinked=True
            )
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    return json.dumps({"ok": True, "item": item}, ensure_ascii=False)

def _knowledge_ref_unlink(services, args: dict[str, Any], **_: Any) -> str:
    try:
        store = services._common_work_store()
        references = store.list_knowledge_refs(str(args["common_id"]))
        reference = next(
            (item for item in references if item["ref_id"] == str(args["ref_id"])),
            None,
        )
        if reference is None:
            return services._common_work_error("active knowledge reference was not found")
        if error := services._require_knowledge_ref_access(
            str(reference["ref_type"]), mutation=True
        ):
            return error
        if args.get("approved") is not True:
            return json.dumps({
                "ok": False,
                "approval_required": True,
                "required_user_message": "승인",
                "preview": {
                    "common_id": args.get("common_id"),
                    "ref_id": args.get("ref_id"),
                    "ref_type": reference["ref_type"],
                    "external_id": reference["external_id"],
                    "reason": args.get("reason"),
                },
            }, ensure_ascii=False)
        item = store.unlink_knowledge_ref(
            str(args["common_id"]),
            ref_id=str(args["ref_id"]),
            reason=str(args["reason"]),
        )
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    return services.obsidian_notes.linked_receipt(services.host, item)

def _common_work_complete(services, args: dict[str, Any], **_: Any) -> str:
    if error := services._require_common_work_access(completion=True):
        return error
    try:
        item = services._common_work_store().complete(str(args["common_id"]), approved=True)
    except (services.CommonWorkError, sqlite3.Error) as exc:
        return services._common_work_error(str(exc))
    services._clear_pending_personal_owner()
    return json.dumps({
        "ok": True, "item": item,
        "cascade": "Within 10 minutes the watcher marks Notion Done, "
                   "calendar ✅/gray, 진행도: 완료 and moves linked memos to 'complete'; report it that way.",
    }, ensure_ascii=False)

def _mail_work(services, args, **_):
    action = str(args.get('action') or '')
    if error := services.mail_work.role_problem(services.host, action):
        return services._error(error)
    try:
        if action == 'match':
            return json.dumps(services.mail_work.match(services.COMMON_WORK_DB, args), ensure_ascii=False)
        if action == 'link':
            return json.dumps(services.mail_work.link(services._common_work_store(), args), ensure_ascii=False)
        if action == 'guide':
            return json.dumps(services.mail_work.guide(services._common_work_store(), args,
                                              session_id=services.get_session_env('HERMES_SESSION_ID', '')), ensure_ascii=False)
        if action == 'guide_clear':
            return json.dumps(services.mail_work.guide_clear(services._common_work_store(), args), ensure_ascii=False)
        return services._error('action must be match, link, guide or guide_clear')
    except (services.mail_work.MailWorkError, services.CommonWorkError, sqlite3.Error) as exc:
        return services._error(str(exc))

def _attach_common_work_links(services,
    items: list[dict[str, Any]], *, domain: str, source_id_field: str
) -> list[dict[str, Any]]:
    if not any(str(item.get(source_id_field) or "").strip() for item in items):
        for item in items:
            item["common_work"] = {"linked": False, "lookup_error": "native source ID missing"}
        return items
    try:
        store = services._common_work_store()
    except (services.CommonWorkError, sqlite3.Error) as exc:
        for item in items:
            item["common_work"] = {"linked": False, "lookup_error": (
                str(exc) if str(item.get(source_id_field) or "").strip() else "native source ID missing"
            )}
        return items
    for item in items:
        source_id = str(item.get(source_id_field) or "").strip()
        item["common_work"] = (
            services._lookup_common_work_source(domain, source_id, store=store)
            if source_id else {"linked": False, "lookup_error": "native source ID missing"}
        )
    return items
