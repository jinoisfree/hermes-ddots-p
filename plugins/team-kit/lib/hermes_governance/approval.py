"""Unchanged approval policy."""
from __future__ import annotations

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text

from hermes_facility.loading import source_path
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo


def _lead_skill_write_problem(services, args: Any) -> str | None:
    """Validate every effective skill operation without changing the caller's input."""
    guidance = "Only site-notes reference writes/removals and partial index/reference patches are allowed."
    def reject(reason):
        return reason + " " + guidance
    if not isinstance(args, dict):
        return reject("Invalid skill arguments.")
    operations = args.get("operations")
    if operations is None:
        operations = [args]
    if not isinstance(operations, list) or not operations:
        return reject("Expected a nonempty operations list.")
    def reference(path):
        if not isinstance(path, str) or not path.startswith("references/") or not path.endswith(".md"):
            return False
        host = path[len("references/"):-3]
        return (len(host) <= 253 and "." in host and ".." not in host
                and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part)
                        for part in host.split(".")))
    for op in operations:
        if not isinstance(op, dict):
            return reject("Invalid operation.")
        if op.get("name", args.get("name")) != "site-notes":
            return reject("The target must be site-notes.")
        action, path = op.get("action"), op.get("file_path")
        if action not in {"write_file", "remove_file", "patch"}:
            return reject("This skill action is not allowed.")
        if action == "patch":
            if op.get("content") is not None:
                return reject("Whole-skill rewrites are not allowed.")
            if path not in (None, "", "SKILL.md") and not reference(path):
                return reject("Invalid patch path.")
            if not isinstance(op.get("old_string"), str) or not op["old_string"] or not isinstance(op.get("new_string"), str):
                return reject("A patch needs old_string and new_string.")
        else:
            if not reference(path):
                return reject("Expected references/<lowercase-host>.md.")
            if action == "write_file" and (not isinstance(op.get("file_content"), str) or len(op["file_content"]) > 1500):
                return reject("Reference content must be a string of at most 1500 characters.")
    return None

def _lead_skill_write_classification(services, args: Any) -> tuple[str, str]:
    """Reject malformed shapes, exempt narrow site tips, ask for all other skill writes."""
    if not isinstance(args, dict):
        return "block", "Invalid skill arguments."
    ops = args.get("operations")
    ops = [args] if ops is None else ops
    if not isinstance(ops, list) or not ops:
        return "block", "Expected a nonempty operations list."
    if services._lead_learning_enabled():
        for op in ops:
            name = op.get("name", args.get("name", "")) if isinstance(op, dict) else ""
            if isinstance(name, str) and (name == "site-notes" or name.startswith(_owner_text("<<personal_skill_prefix>>-"))):
                return "block", ("Use team_learn(target='skill') for managed learning documents so the change "
                                 "can be reviewed and reverted in the morning report. Code/configuration changes go to Paseo.")
    actions = {"create": "만들기", "patch": "고치기", "edit": "고치기", "write_file": "파일 쓰기",
               "remove_file": "파일 지우기", "delete": "스킬 삭제"}
    summary, deleting = [], False
    for op in ops:
        if not isinstance(op, dict):
            return "block", "Invalid skill operation."
        name, action = op.get("name", args.get("name")), op.get("action")
        if not isinstance(name, str) or not name.strip() or not isinstance(action, str) or action not in actions:
            return "block", "Each skill operation needs a name and a supported action."
        for key in ("file_path", "content", "file_content", "old_string", "new_string", "category", "absorbed_into"):
            if op.get(key) is not None and not isinstance(op[key], str):
                return "block", "Skill text and path fields must be strings."
        if "replace_all" in op and not isinstance(op["replace_all"], bool):
            return "block", "replace_all must be a boolean."
        deleting |= action in {"delete", "remove_file"}
        text = op.get("file_content") or op.get("content") or op.get("new_string") or ""
        compact = lambda value: " ".join(value.split())
        summary.append(f"{actions[action]}: {compact(name)[:80]}" +
                       (f" / {compact(op['file_path'])[:100]}" if op.get("file_path") else "") +
                       (f" — {compact(text)[:100]}" if text else ""))
    if services._lead_skill_write_problem(args) is None:
        return "allow", ""
    header = "승인하면 스킬을 삭제·변경합니다" if deleting else "승인하면 스킬을 만들거나 고칩니다"
    return "approve", (f"{header} ({len(ops)}개 작업).\n" + "\n".join(summary[:3]))[:600]

def _team_kit_review_skill_write(services, tool_name: str) -> bool:
    """The core review fork writing its own skill: team-kit learning_self checks the scope and
    journals it for the morning report, so the chat-only skill and role gates here step aside."""
    if tool_name != "skill_manage":
        return False
    try:
        from tools.skill_provenance import is_background_review
        if not is_background_review():
            return False
        import importlib.util
        from hermes_constants import get_hermes_home
        if not services._REVIEW_SKILL_LEARNING:
            path = source_path('hermes_team_services.learning')
            spec = importlib.util.spec_from_file_location("review_skill_learning", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            services._REVIEW_SKILL_LEARNING.append(module)
        learning = services._REVIEW_SKILL_LEARNING[0]
        return learning.extension("learning_self").enabled(Path(get_hermes_home()), learning)
    except Exception as exc:
        logging.getLogger(services.logger_name).warning("Background skill review gate failed (%s)", type(exc).__name__)
        return False

def _lead_skill_context_problem(services) -> str | None:
    try:
        from tools.skill_provenance import is_background_review
        if services._lead_browse_context() != "chat" or is_background_review():
            return "Skill writes run only in the lead's human Slack or iMessage conversation, never in a background review."
    except Exception:
        return "Skill write context could not be verified; this call is refused."
    return None

def _skill_call_identity(services, args: Any, context: dict[str, Any]) -> tuple:
    return (tuple(services._conversation_scopes(str(context.get("session_id") or ""))),
            str(context.get("tool_call_id") or ""), str(context.get("turn_id") or ""),
            hashlib.sha256(json.dumps(args, sort_keys=True, ensure_ascii=False).encode()).hexdigest())

def _prune_skill_approvals(services) -> None:
    now = time.monotonic()
    for key in list(services._SKILL_APPROVALS):
        if now - services._SKILL_APPROVALS[key]["at"] > 600:
            del services._SKILL_APPROVALS[key]
    while len(services._SKILL_APPROVALS) >= 512:
        del services._SKILL_APPROVALS[next(iter(services._SKILL_APPROVALS))]

def _lead_skill_approval(services, args: Any, **context: Any) -> dict[str, str] | None:
    if problem := services._lead_skill_context_problem():
        return {"action": "block", "message": problem}
    try:
        decision, message = services._lead_skill_write_classification(args)
    except Exception:
        decision, message = "approve", "승인하면 스킬을 변경합니다. 작업 범위를 분류하지 못했습니다. 요청 내용을 확인해 주세요."
    if decision == "allow":
        return None
    if decision == "block":
        return {"action": "block", "message": message}
    key = "lead-skill:" + os.urandom(16).hex()
    try:
        identity = services._skill_call_identity(args, context)
        with services._SKILL_APPROVAL_LOCK:
            services._prune_skill_approvals()
            services._SKILL_APPROVALS["plugin_rule:" + key] = {"identity": identity, "at": time.monotonic(), "approved": False}
    except Exception:
        # Still ask in chat, but execution fails closed if no identity could be recorded.
        pass
    return {"action": "approve", "message": message, "rule_key": key}

def _lead_skill_approval_response(services, pattern_key: str = "", choice: str = "", **_: Any) -> None:
    """Only an actual human response grants a one-use permit; requesting approval does not."""
    with services._SKILL_APPROVAL_LOCK:
        services._prune_skill_approvals()
        pending = services._SKILL_APPROVALS.get(pattern_key)
        if pending is not None:
            if choice in {"once", "session", "always"}:
                pending["approved"] = True
            else:
                services._SKILL_APPROVALS.pop(pattern_key, None)

def _lead_skill_write_gate(services, args: Any, **context: Any) -> str | None:
    if problem := services._lead_skill_context_problem():
        return problem
    try:
        decision, message = services._lead_skill_write_classification(args)
        if decision == "allow":
            return None
        if decision == "block":
            return message
        identity = services._skill_call_identity(args, context)
        with services._SKILL_APPROVAL_LOCK:
            services._prune_skill_approvals()
            for key, pending in list(services._SKILL_APPROVALS.items()):
                if pending["identity"] == identity and pending["approved"]:
                    del services._SKILL_APPROVALS[key]
                    return None
        return "This skill write has no matching human approval; call skill_manage through the approval gate."
    except Exception:
        return "Skill write validation failed; this call is refused."

def _tool_execution_guard(services, tool_name: str, args: dict[str, Any], next_call, **context: Any) -> Any:
    profile = (services.get_session_env("HERMES_SESSION_PROFILE", "") or os.environ.get("HERMES_PROFILE") or services._home_profile() or "").strip()
    platform = (services.get_session_env("HERMES_SESSION_PLATFORM", "") or "").strip().lower()
    tool_name = str(tool_name or "")
    call_args = args if isinstance(args, dict) else {}
    try:
        services.video_job.expire()
    except Exception:
        return services._error("영상 제작 승인 만료를 정리하지 못해 실행을 거부한다.")
    if services._team_kit_review_skill_write(tool_name):
        return next_call(args)
    if problem := services._personal_role_problem(tool_name, call_args):
        return services._error(problem)
    if tool_name == 'gmail_direct' and services.full_mail_tools.handles(services.host, call_args):
        if problem := services.full_mail_tools.problem(services.host, call_args):
            return services._error(problem, mutation_calls=0)
        if services.request_approvals.allowed(services.host, tool_name, call_args, context):
            services.request_approvals.consume(services.host, tool_name, call_args, context)
        # Middleware is reached only after the native dispatcher approval succeeds.
        with services.full_mail_tools.execution(services.host, call_args):
            return next_call(args)
    if tool_name in services.request_approvals.WRITES:
        call_args = dict(call_args)
        permitted = services.request_approvals.allowed(services.host, tool_name, call_args, context)
        if permitted and services.request_approvals.consume(services.host, tool_name, call_args, context):
            call_args['approved'] = True
        call_args.pop('request_plan', None)
        args = call_args
    note_gate = services._notes_button_action(tool_name, call_args)
    if note_gate == "block":
        return services._error("PERSONAL_SCOPE_OWNER_CHAT_REQUIRED: 메모 쓰기는 인증된 소유자 대화에서만 가능하다.", mutation_calls=0)
    if note_gate == "approve":
        # The dispatcher runs this wrapper only after the approval gate succeeds.
        # Internal direct handlers still retain their preview safety check.
        args = call_args = {**call_args, "approved": True}
    if tool_name == "terminal" and services.selected_skills.enabled(services.host):
        try:
            args = services.selected_skills.wrap(services.host, call_args)
            if problem := services.video_job.missing_job_problem(services.host, args):
                return services._error(problem)
            services.video_job.grant(services.host, call_args, args, context)
        except Exception:
            return services._error("샌드박스 또는 영상 제작 승인 검증에 실패해 실행을 거부한다.")
    chat = platform in {"slack", "photon"}
    browse_context = services._lead_browse_context()
    if services.team.has_role(profile, 'personal') and tool_name == "skill_manage":
        if problem := services._lead_skill_write_gate(args, **context):
            return services._error(problem)
    if tool_name in services.LEAD_BROWSE_TOOLS and (os.environ.get("HERMES_KANBAN_TASK") or not browse_context) and not services._secretary_cron_back(profile, tool_name):
        if not services.team.has_role(profile, 'personal') or browse_context != "kanban":
            return services._error("Page actions run only in the lead profile's human chat or its own kanban card.")
    # A card run has no human watching its shell or file changes.
    if os.environ.get("HERMES_KANBAN_TASK") and tool_name in services.SHELL_TOOLS:
        return services._error(
            f"A card run does not use {tool_name}. If this task needs it, call kanban_block "
            "with kind='needs_input' and say exactly what you would run.")
    if services._is_wiki(profile) and chat and services._reads_the_web(tool_name):
        return services._error(_owner_text("<<default_name>> does not search or browse the web in chat; <<personal_full_name>> does web research"))
    if services._is_executor(profile) and chat:
        allowed_tools = {
            "calendar_direct_lookup",
            "calendar_direct_mutation",
            "google_calendar_color_get",
            "google_calendar_color_set",
            "apple_notes_direct_lookup",
            "apple_notes_direct_mutation",
            "gmail_direct",
            "messages_direct_lookup",
            "personal_work_bundle",
            "personal_work_rollback",
            "common_work_create",
            "common_work_get",
            "common_work_link",
            "common_work_complete",
            "knowledge_ref_link",
            "knowledge_ref_get",
            "knowledge_ref_unlink",
            "memory",
            "session_search",
        }
        allowed_tools |= services.LEARNING_TOOLS
        allowed_tools |= services.selected_skills.offered(services.host) | services.media_save.offered(services.host)
        if services.team.has_role(profile, 'work'):
            allowed_tools |= services.personal_roles.WORK_TOOLS
            allowed_tools |= services.personal_scopes.SCOPED_TOOLS if services.personal_scopes.config(services.host) is not None else frozenset()
            allowed_tools.discard('messages_direct_lookup')
        if services.team.has_role(profile, 'personal'):
            allowed_tools |= services.LEAD_CHAT_TOOLS
        if tool_name not in allowed_tools:
            return services._error(
                f"{services.PERSONAL_PROFILE} routed personal work permits only Calendar, "
                "Apple Notes, Gmail, and Messages direct tools"
                + (", plus web search, page reading, files in its readable folders, and its own background cards"
                   if services.team.has_role(profile, 'personal') else "")
            )
    if services.team.has_role(profile, 'personal') and (chat or os.environ.get("HERMES_KANBAN_TASK")):
        if tool_name == "kanban_create" and str(call_args.get("assignee") or "").strip() != profile:
            return services._error(f"{profile} may hand background work only to itself: set assignee to '{profile}'")
    # In chat and in its own card runs the lead profile sees files only where it was told it may.
    if services.team.has_role(profile, 'personal') and (chat or os.environ.get("HERMES_KANBAN_TASK")):
        if tool_name in services.LEAD_FILE_READ_TOOLS | services.LEAD_FILE_CHANGE_TOOLS:
            if problem := services._lead_file_problem(tool_name, call_args):
                return services._error(problem)
        if tool_name in services.LEAD_FILE_READ_TOOLS:
            from_web = services._inside(call_args.get("path"), [services._web_cache_root()]) is not None
            services._mark_request_scope(services._WEB_READ_SCOPES if from_web else services._FILE_READ_SCOPES)
    # Chat and unattended runs read whatever a search turns up, so the local browser stays off this
    # machine and its network, and the request is marked as having read third-party text.
    if tool_name in services.WEB_READ_TOOLS and (chat or os.environ.get("HERMES_KANBAN_TASK") or services.get_session_env("HERMES_CRON_SESSION", "")):
        if tool_name == "browser_navigate" and not services._public_web_url(call_args.get("url")):
            return services._error("browser_navigate reads public http(s) pages only; this address is not one")
        services._mark_request_scope(services._WEB_READ_SCOPES)
    if services.team.has_role(profile, 'personal') and chat and tool_name == "kanban_create":
        result = next_call(args)
        services._answer_in_one_post(result)
        return result
    if (services.team.has_role(profile, 'personal') or (services.team.has_role(profile, 'work') and services.personal_scopes.config(services.host) is not None)) and browse_context in {"chat", "kanban"} and tool_name in services.LEAD_BROWSE_TOOLS | {"browser_navigate", "browser_snapshot"}:
        next_call = services._browsing(next_call, tool_name, context)
    task_id = services._governed_task_id(context)
    contract = services._active_contract(task_id, context.get("board"))
    decision = services.enforcement_decision(contract, services._settings())
    if not task_id or contract.get("work_class") not in {
        "direct_lookup", "single_owner", "parallel",
    }:
        return next_call(args)
    state = services._runtime(task_id)
    if tool_name not in services.SAFETY_TOOLS and contract.get("read_write_mode") == "read-only" and services.MUTATION_TOOL_RE.search(tool_name):
        state["mutation_calls"] += 1
        state["trusted_fields"].add("mutation_calls")
        if decision["hard"]:
            services._hard_stop("TE_READ_ONLY_MUTATION", f"tool={tool_name}", state)
    if decision["hard"]:
        services._check_budgets(contract, state)
    state["tool_calls"] += 1
    state["trusted_fields"].add("tool_calls")
    started = time.monotonic()
    try:
        result = next_call(args)
    except Exception as exc:
        fingerprint = services._fingerprint_error(exc)
        count = int(state["error_fingerprints"].get(fingerprint, 0)) + 1
        state["error_fingerprints"][fingerprint] = count
        if decision["hard"] and count > int(contract.get("retry_budget", 1) or 0):
            services._hard_stop("TE_REPEATED_ERROR", f"fingerprint={fingerprint}", state)
        raise
    finally:
        elapsed = max(0.0, time.monotonic() - started)
        if tool_name in services.EXTERNAL_WAIT_TOOLS:
            state["external_wait_seconds"] += elapsed
            if "approval" in tool_name or "vault" in tool_name:
                state["approval_calls"] += 1
                state["trusted_fields"].add("approval_calls")
            state["trusted_fields"].add("external_wait_seconds")
        else:
            state["processing_seconds"] += elapsed
            state["trusted_fields"].add("processing_seconds")
    if decision["hard"]:
        services._check_budgets(contract, state)
    return result

def _gmail_mutation_plan(services, args: dict[str, Any]) -> str:
    """Readable confirmation, paired with the unchanged canonical arguments at the gate."""
    action = str(args.get("action") or "").strip().lower()
    titles = {"label_create": "라벨 만들기", "label_apply": "기존 메일에 라벨 적용",
              "filter_create": "향후 메일 필터 만들기", "filter_delete": "필터 삭제",
              "mail_organize": "메일 분류 일괄 실행", "inbox_restore": "받은편지함 복원"}
    account = args.get("account") or services._gmail_account()
    cfg = services.personal_scopes.config(services.host)
    if cfg and not cfg.get("invalid") and services.personal_scopes.current(services.host) in services.personal_scopes.OWNERS:
        account = services.personal_scopes.mailbox(services.host, args, cfg)
    lines = ["승인하면 아래 Gmail 변경을 한 번에 실행합니다.",
             f"계정: {account}", f"동작: {titles[action]} ({action})"]
    if action == "mail_organize":
        lines.append("실행 순서: 필터 삭제 → 분류 규칙 적용 → 받은편지함 복원")
        rules = args.get("rules", [])
        delete_ids = args.get("delete_filter_ids", [])
        restores = args.get("restore_inbox_queries", [])
    else:
        rules = [args] if action in {"label_create", "label_apply", "filter_create"} else []
        delete_ids = [args["filter_id"]] if action == "filter_delete" else []
        restores = [args["query"]] if action == "inbox_restore" else []
    for index, rule in enumerate(rules, 1):
        lines.append(f"규칙 {index} 라벨: {rule.get('label_name') or rule.get('label_id')}")
        if rule.get("criteria"):
            lines.append("조건: " + json.dumps(rule["criteria"], ensure_ascii=False, sort_keys=True))
        elif rule.get("query"):
            lines.append("조건 검색어: " + rule["query"])
        if action != "label_create":
            lines.append("받은편지함 제외: " + ("예" if rule.get("skip_inbox", False) else "아니요"))
        if action in {"mail_organize", "filter_create"}:
            lines.append("향후 메일 읽음 처리: " + ("예" if rule.get("mark_read", False) else "아니요"))
        if action == "mail_organize":
            lines.append("기존 메일 적용: " + ("예 (규칙당 최대 500통)" if rule.get("apply_existing", True) else "아니요"))
    for filter_id in delete_ids:
        lines.append("삭제할 필터 ID: " + filter_id)
    for query in restores:
        lines.append("받은편지함 복원 검색어: " + query + " (휴지통·스팸 제외, 최대 500통)")
    return "\n".join(lines)

def _notes_button_action(services, tool_name: str, args: dict[str, Any]) -> str | None:
    """Shared gate/execution classification; internal choice and recovery actions are excluded."""
    actions = {
        "apple_notes_direct_mutation": {"create", "update", "move", "delete"},
    }
    action = str(args.get("action") or "").strip().lower()
    if action not in actions.get(tool_name, set()):
        return None
    if services._personal_role_problem(tool_name, args):
        return "block"
    profile = services.personal_roles.profile(services.host)
    if not services._is_executor(profile) and not (services.team.has_role(profile, 'personal')
            and services.personal_scopes.config(services.host) is not None):
        return None
    if (services.personal_scopes.background(services.host)
            or services.get_session_env("HERMES_SESSION_PLATFORM", "").strip().lower() not in {"slack", "photon"}
            or not services.get_session_env("HERMES_SESSION_CHAT_ID", "")
            or not services.get_session_env("HERMES_SESSION_USER_ID", "")):
        return "block"
    return None if services._owner_chat_no_approval(tool_name, action, args) else "approve"

def _one_button_plan(services, tool_name: str, action: str, args: dict[str, Any]) -> str:
    """The readable plan shown above a single 승인·거절 button for a personal write."""
    if tool_name == "apple_notes_direct_mutation":
        titles = {"create": "만들기", "update": "수정", "move": "이동", "delete": "삭제"}
        lines = ["승인하면 아래 메모 변경을 실행합니다.", f"동작: {titles[action]}",
                 f"폴더: {args.get('folder') or '기존 폴더 유지'}",
                 f"제목: {args.get('title') or '기존 제목 유지'}",
                 f"메모 ID: …{str(args.get('note_id') or '')[-24:]}"]
        if args.get("preview_summary"):
            lines.append("한줄요약: " + str(args["preview_summary"]))
        if args.get("summary"):
            lines.append("적용할 요약 전체:\n" + str(args["summary"]))
        if action in {"create", "update"}:
            lines.append(f"원문 {len(str(args['original_text']))}자 보존" if args.get("original_text")
                         else "기존 원문 유지")
        for key, label in {"rename_title": "제목 변경", "mixed_mode": "첨부 처리 방식",
                           "remove_existing": "제거할 기존 첨부", "attachment_analysis": "첨부 분석",
                           "append_text": "추가할 글", "common_id": "연결 업무 ID"}.items():
            if key in args:
                lines.append(f"{label}: {args[key]}")
        if args.get("attachments"):
            lines.append("첨부: " + ", ".join(Path(str(p)).name for p in args["attachments"]))
        return "\n".join(lines)
    if tool_name == "contacts_direct_mutation":
        titles = {'update': '연락처 수정', 'delete': '연락처 삭제', 'group_rename': '그룹 이름 변경',
                  'group_delete': '그룹 삭제(멤버 연락처 유지)', 'group_remove': '그룹에서 연락처 제외'}
        changes = {key: value for key, value in args.items() if key not in {'action', 'contact_id', 'expected_name', 'group_id'}}
        backup = '\n삭제 전 백업을 저장하며 백업 실패 시 삭제하지 않습니다.' if action in {'delete', 'group_delete'} else ''
        return (f"승인하면 {titles[action]}를 실행합니다.\n대상: {args.get('expected_name') or args.get('group_id') or ''} "
                f"({args.get('contact_id') or args.get('group_id') or ''}){backup}\n변경: " + json.dumps(changes, ensure_ascii=False, sort_keys=True))
    if tool_name == "gmail_direct" and action in services.GMAIL_LABEL_FILTER_WRITES:
        return services._gmail_mutation_plan(args)
    if tool_name == "gmail_direct":
        lines = ["승인하면 메일을 보냅니다.", f"받는 사람: {args.get('to') or ''}"]
        if str(args.get("cc") or "").strip():
            lines.append(f"참조: {args['cc']}")
        if args.get("account"):
            lines.append(f"보내는 계정: {args['account']}")
        lines.append(f"제목: {args.get('subject') or ''}")
        attachments = args.get("attachments") or []
        if attachments:
            lines.append("첨부: " + ", ".join(Path(str(item)).name for item in attachments))
        lines.append("본문:\n" + str(args.get("body") or ""))
        return "\n".join(lines)
    target = " · ".join(str(value) for value in (
        args.get("expected_title"), args.get("expected_start"),
        args.get("account") or args.get("calendar_id"),
    ) if value)
    return f"승인하면 일정을 삭제합니다.\n- {target or args.get('event_id') or ''}"

def _personal_mutation_approval_single(services,
    tool_name: str,
    args: dict[str, Any],
    tool_call_id: str = "",
    turn_id: str = "",
    session_id: str = "",
    **_: Any,
) -> dict[str, str] | None:
    """Require a human gate for protected writes, including Gmail sends and label/filter changes."""
    profile = (
        services.get_session_env("HERMES_SESSION_PROFILE", "")
        or os.environ.get("HERMES_PROFILE") or services._home_profile()
        or "default"
    ).strip()
    chat = services.get_session_env("HERMES_SESSION_PLATFORM", "").strip().lower() in {"slack", "photon"}
    card_run = bool(os.environ.get("HERMES_KANBAN_TASK"))
    browse_context = services._lead_browse_context()
    if services._team_kit_review_skill_write(str(tool_name or "")):
        return None
    if services.team.has_role(profile, 'personal') and tool_name == "skill_manage":
        return services._lead_skill_approval(args, tool_call_id=tool_call_id, turn_id=turn_id, session_id=session_id)
    if tool_name in services.LEAD_BROWSE_TOOLS and (card_run or not browse_context) and not services._secretary_cron_back(profile, tool_name):
        if not services.team.has_role(profile, 'personal') or browse_context != "kanban":
            return {"action": "block", "message": (
                "Page actions run only in the lead profile's human chat or its own kanban card.")}
    if services.team.has_role(profile, 'work') and services.personal_scopes.config(services.host) is not None and tool_name in services.BROWSER_ACT_TOOLS:
        if browse_context != 'chat' or card_run:
            return {'action':'block','message':'예약·배경의 브라우저 클릭·입력·키 입력은 거부한다.'}
        try:
            return services._lead_browse_gate(str(tool_name), args if isinstance(args, dict) else {}, unattended=False,
                                    session_id=str(session_id or ''), tool_call_id=str(tool_call_id or ''))
        except Exception:
            return {'action':'approve','rule_key':f'secretary-browse:unchecked:{tool_call_id or time.time_ns()}',
                    'message':f'승인하면 실행합니다. 브라우저 조작을 미리 확인하지 못했습니다: {tool_name}'}
    if chat and services._is_wiki(profile) and tool_name in {"terminal", "execute_code", "process"}:
        command = " ".join(str((args or {}).get(key) or "") for key in ("command", "code")) if isinstance(args, dict) else ""
        if services._NETWORK_COMMAND_RE.search(command):
            digest = hashlib.sha256(command.encode("utf-8", "replace")).hexdigest()[:12]
            return {"action": "approve", "rule_key": f"wiki-network:{digest}",
                    "message": f"승인하면 실행합니다. 셸에서 네트워크를 쓰는 명령입니다: {' '.join(command.split())[:500]}"}
    if services.team.has_role(profile, 'personal') and (chat or card_run):
        call_args = args if isinstance(args, dict) else {}
        # A file call outside the readable folders is refused here, before the user is asked to approve it.
        if tool_name in services.LEAD_FILE_READ_TOOLS | services.LEAD_FILE_CHANGE_TOOLS:
            if problem := services._lead_file_problem(str(tool_name), call_args):
                return {"action": "block", "message": problem}
        try:
            gate = services._lead_address_gate(str(tool_name), call_args, unattended=card_run or not chat, session_id=str(session_id or ""))
        except Exception:
            if not card_run:
                raise
            logging.getLogger("team_delegation.personal").warning("card address gate failed", exc_info=True)
            return {"action": "block", "message": (
                f"Refused: {tool_name} could not be checked for unseen addresses. "
                "Call kanban_block with kind='needs_input' and describe the address for the user.")}
        if gate:
            return gate
        if tool_name in services.BROWSER_ACT_TOOLS:
            try:
                gate = services._lead_browse_gate(str(tool_name), call_args, unattended=browse_context != "chat",
                                         session_id=str(session_id or ""), tool_call_id=str(tool_call_id or ""))
            except Exception:  # a fault here must not let an unchecked click or text through
                logging.getLogger("team_delegation.personal").warning("browse gate failed", exc_info=True)
                if browse_context == "kanban":
                    gate = {"action": "block", "message": (
                        f"Refused: {tool_name} could not be checked before acting on the page. "
                        "Call kanban_block with kind='needs_input' and describe the action for the user.")}
                else:
                    gate = {"action": "approve", "rule_key": f"lead-browse:unchecked:{tool_call_id or time.time_ns()}",
                            "message": f"승인하면 실행합니다. 브라우저 조작을 미리 확인하지 못했습니다: {tool_name}"}
            if gate:
                return gate
    if problem := services._personal_role_problem(str(tool_name), args if isinstance(args, dict) else {}):
        return {"action": "block", "message": problem}
    if (services.team.has_role(profile, 'personal') and tool_name in {'write_file', 'patch'}
            and services.get_session_env('HERMES_SESSION_PLATFORM', '').strip().lower() == 'slack'):
        return services._lead_workspace_write_approval(tool_name, args, tool_call_id=tool_call_id)
    if tool_name == 'contacts_direct_mutation':
        payload, error = services._contacts_arguments(args, mutation=True)
        if error:
            return {'action': 'block', 'message': error}
        if payload['action'] in {'create', 'import_vcf', 'group_create', 'group_add'}:
            return None
        digest = hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]
        return {'action': 'approve', 'message': services._one_button_plan(tool_name, payload['action'], payload),
                'rule_key': f'contacts-mutation:{digest}:{tool_call_id or turn_id or digest}'}
    if not services._is_executor(profile) and not (services.team.has_role(profile, 'personal')
            and services.personal_scopes.config(services.host) is not None):
        return None
    if tool_name == "personal_work_bundle":
        if 'capture' in args or 'scope_change' in args:
            try:
                if not services._task_capture_owner_chat():raise ValueError('WORK_CAPTURE_OWNER_CHAT_REQUIRED')
                if 'capture' in args:services.work_capture.authorized(services.host)
                return None
            except ValueError as exc:return {'action':'block','message':str(exc)}
        approved_args = services._normalize_personal_bundle_args(args)
        if services._bundle_completes(approved_args):
            return None  # finishes the Common ID like common_work_complete, which needs no approval
        operations, existing_sources, validation_error = services._validate_bundle(approved_args)
        if validation_error:
            return {
                "action": "block",
                "message": f"승인 요청 전 개인업무 묶음 검증에 실패했습니다: {validation_error}",
            }
        if not services._bundle_requires_approval(operations, existing_sources):
            return None
        canonical = json.dumps(
            approved_args, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        )
        digest = hashlib.sha256(canonical.encode()).hexdigest()[:16]
        message_id = services.get_session_env("HERMES_SESSION_MESSAGE_ID", "").strip()
        thread_id = services.get_session_env("HERMES_SESSION_THREAD_ID", "").strip()
        scope = message_id or str(turn_id or thread_id or tool_call_id or digest)
        # The user already saw this exact bundle at the gate and has now answered 승인 in the thread:
        # that is the approval, not a reason to ask again.
        if services._approved_after_the_gate(digest, session_id=str(session_id or "")):
            return None
        services._note_gate_shown(digest)
        now = time.monotonic()
        with services._PERSONAL_BUNDLE_APPROVAL_LOCK:
            expired = [
                key for key, created_at in services._PERSONAL_BUNDLE_APPROVAL_SCOPES.items()
                if now - created_at > 3600
            ]
            for key in expired:
                services._PERSONAL_BUNDLE_APPROVAL_SCOPES.pop(key, None)
            if scope in services._PERSONAL_BUNDLE_APPROVAL_SCOPES and not _.get('request_plan_scope'):
                return {
                    "action": "block",
                    "message": (
                        "이 요청의 개인업무 승인은 이미 한 번 요청됐습니다. "
                        "재승인을 요청하지 말고 기존 실행 결과나 실패 원인을 보고하세요."
                    ),
                }
            services._PERSONAL_BUNDLE_APPROVAL_SCOPES[scope] = now
        delete_only = bool(operations) and all(
            operation["action"] == "delete" for operation in operations
        )
        services._remember_pending_personal_owner("personal_work_bundle", approved_args)
        if not any(operation["action"] == "delete" for operation in operations):
            # Only reachable for a bundle that changes an existing item after reading text messages,
            # the web or a file: show a readable plan.
            origin = ("문자에서 뽑은" if services._messages_lookup_in_request()
                      else "웹에서 읽은 내용으로 만든" if services._web_read_in_request()
                      else "파일에서 읽은 내용으로 만든")
            return {
                "action": "approve",
                # "승인하면" is the wording the ddots chat puts its 승인·거절 buttons under.
                "message": f"{origin} 항목입니다. 승인하면 전체를 한 번에 실행합니다:\n"
                + services._bundle_plan_lines(operations),
                "rule_key": f"personal-bundle:{scope}:{digest}",
            }
        return {
            "action": "approve",
            # Readable targets, and the wording the ddots chat puts its buttons under.
            "message": ("승인하면 삭제합니다:\n" if delete_only else "삭제가 들어 있습니다. 승인하면 전체를 한 번에 실행합니다:\n")
            + services._bundle_plan_lines(operations),
            "rule_key": f"personal-bundle:{scope}:{digest}",
        }
    if tool_name == "gmail_direct" and str(args.get("action") or "").strip().lower() in services.GMAIL_LABEL_FILTER_WRITES:
        if problem := services.personal_scopes.role_problem(services.host, "gmail_direct", args):
            return {"action": "block", "message": problem}
        if services.personal_scopes.background(services.host):
            return {"action": "block", "message": "PERSONAL_SCOPE_BACKGROUND_REFUSED: 예약·배경에서 라벨·필터 호출은 허용되지 않는다."}
        if (services.get_session_env("HERMES_SESSION_PLATFORM", "") not in {"slack", "photon"}
                or not services.get_session_env("HERMES_SESSION_CHAT_ID", "") or not services.get_session_env("HERMES_SESSION_USER_ID", "")):
            return {"action": "block", "message": "PERSONAL_SCOPE_OWNER_CHAT_REQUIRED: 라벨·필터는 인증된 소유자 대화에서만 가능하다."}
        try:
            services.gmail_rules.validate_operation(str(args["action"]).strip().lower(), args)
        except services.gmail_rules.RuleError as exc:
            return {"action": "block", "message": str(exc)}
        if failure := services._gmail_scope_preflight(args):
            return {"action": "block", "message": json.dumps(failure, ensure_ascii=False)}
    action = str(args.get("action") or "").strip().lower()
    # 2026-10-21 사용자 결정: 메일·일정 쓰기는 미리보기·글 승인 없이 버튼 승인 한 번으로 끝낸다.
    # 소유자가 대화에서 시킨 일정 만들기·고치기와 색 지정은 승인 없이 실행한다.
    if tool_name in {"calendar_direct_mutation", "google_calendar_color_set"} or (
            tool_name == "gmail_direct" and action in {"send", *services.GMAIL_LABEL_FILTER_WRITES}):
        if services.personal_scopes.background(services.host) or not chat:
            return {"action": "block", "message": (
                "PERSONAL_SCOPE_OWNER_CHAT_REQUIRED: 메일·일정 쓰기는 인증된 소유자 대화에서만 가능하다.")}
        if tool_name == "google_calendar_color_set" or (tool_name == "calendar_direct_mutation" and action != "delete"):
            return None
        exact_payload = {key: value for key, value in args.items() if key != "approved"}
        digest = hashlib.sha256(json.dumps(
            exact_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()[:16]
        return {
            "action": "approve",
            # "승인하면" is the wording the chat puts its 승인·거절 buttons under.
            "message": services._one_button_plan(tool_name, action, args),
            "rule_key": f"personal-mutation:{tool_name}:{digest}:{tool_call_id or turn_id or digest}",
        }
    # 2026-10-25: ordinary Notes edits use one button, never a text-preview round trip.
    note_gate = services._notes_button_action(tool_name, args)
    if note_gate == "block":
        return {"action": "block", "message": (
            "PERSONAL_SCOPE_OWNER_CHAT_REQUIRED: 메모 쓰기는 인증된 소유자 대화에서만 가능하다.")}
    if note_gate == "approve":
        exact_payload = {key: value for key, value in args.items() if key != "approved"}
        digest = hashlib.sha256(json.dumps(
            exact_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()[:16]
        return {"action": "approve", "message": services._one_button_plan(tool_name, action, args),
                "rule_key": f"personal-mutation:{tool_name}:{digest}:{tool_call_id or turn_id or digest}"}
    # Keep create exemptions and internal choice/recovery approval behavior unchanged.
    if (tool_name == "apple_notes_direct_mutation"
            and services._owner_chat_no_approval(tool_name, action, args)):
        return None
    if args.get("approved") is not True:
        return None
    mutation = tool_name == "apple_notes_direct_mutation"
    if not mutation:
        return None

    exact_payload = {key: value for key, value in args.items() if key != "approved"}
    canonical = json.dumps(
        exact_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    digest = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    call_scope = str(tool_call_id or turn_id or digest)
    message = f"정확한 외부 변경을 승인해야 합니다: {tool_name} {canonical}"
    return {
        "action": "approve",
        "message": message,
        "rule_key": f"personal-mutation:{tool_name}:{digest}:{call_scope}",
    }

def _personal_mutation_approval(services, tool_name, args, tool_call_id='', turn_id='', session_id='', **context):
    context.update(tool_call_id=tool_call_id, turn_id=turn_id, session_id=session_id)
    if not isinstance(args, dict):
        return services._personal_mutation_approval_single(tool_name, args, **context)
    if tool_name == 'gmail_direct' and services.full_mail_tools.handles(services.host, args):
        if args.get('action') in services.full_mail_tools.MAIL_READS:
            problem = services.full_mail_tools.problem(services.host, args)
            return {'action': 'block', 'message': problem} if problem else None
        if services.request_approvals.allowed(services.host, tool_name, args, context):
            return None
        decision = services.full_mail_tools.approval(services.host, args, context)
        return services.request_approvals.gate(services.host, tool_name, args, decision, context)
    if services.request_approvals.allowed(services.host, tool_name, args, context):
        return None
    clean = {k: v for k, v in args.items() if k != 'request_plan'}
    decision = services._personal_mutation_approval_single(tool_name, clean, request_plan_scope=bool(args.get('request_plan')), **context)
    return services.request_approvals.gate(services.host, tool_name, args, decision, context)

def _personal_owner_error(services, tool_name: str) -> str | None:
    fields = {"mutation_calls": 0} if tool_name.endswith("_mutation") else {}
    profile = (
        services.get_session_env("HERMES_SESSION_PROFILE", "")
        or os.environ.get("HERMES_PROFILE") or services._home_profile()
        or "default"
    ).strip()
    if problem := services._personal_role_problem(tool_name, {} if tool_name != 'gmail_direct' else {'action': 'read'}):
        return services._error(problem, **fields)
    if services.team.has_role(profile, 'work') and tool_name == 'messages_direct_lookup':
        return services._error('Messages lookup remains with the read-only oversight profile.')
    if (services.team.has_role(profile, 'personal') and services.personal_scopes.config(services.host) is not None
            and tool_name in services.personal_scopes.SCOPED_TOOLS):
        return None
    if services._is_executor(profile) or ((services.team.has_role(profile, 'personal') or services._is_executor(profile)) and tool_name in services.personal_roles.PERSONAL_READS):
        return None
    return services._error(f"{tool_name} is restricted to the {services._personal_executor()} profile", **fields)

def _lead_workspace_write_approval(services, tool_name, args, *, tool_call_id=''):
    """The Slack config delegates these two tools here; only owner scratch writes skip consent."""
    td = services.host
    from tools.skill_provenance import is_background_review
    if (services.personal_scopes.background(td) or services.get_session_env('HERMES_DIAGNOSIS_REQUEST', '')
            or os.environ.get('HERMES_DIAGNOSIS_REQUEST') or is_background_review()):
        return {'action': 'block', 'message': 'workspace 파일 쓰기는 소유자 Slack 대화에서만 가능하다. 예약·배경은 거부한다.'}
    workspace = services._lead_workspace_root()
    target = services._inside(args.get('path'), [workspace])
    requested = Path(str(args.get('path') or '')).expanduser()
    if target is not None:
        try:
            owner = services.video_job._owner(workspace.parent)
        except Exception:
            owner = None
        if (not services.selected_skills.owner_chat(td) or not owner
                or services.get_session_env('HERMES_SESSION_USER_ID', '') != owner):
            return {'action': 'block', 'message': 'workspace 파일 쓰기의 Slack 소유자를 확인하지 못했다.'}
        return None
    # Canonicalize only the profile-home alias (/Users may point into /Volumes).
    # Keep workspace's child links unresolved here so an escape cannot look like a normal Drive write.
    for parent in requested.parents:
        if parent.resolve() == workspace.parent:
            requested = workspace.parent / requested.relative_to(parent)
            break
    if requested == workspace or workspace in requested.parents:
        return {'action': 'block', 'message': 'workspace 밖으로 나가는 파일 경로·심링크는 거부한다.'}
    # Outside workspace, retain the per-call approval formerly supplied by tool_policy.
    canonical = json.dumps(args, ensure_ascii=False, sort_keys=True, default=str)
    digest = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    return {'action': 'approve', 'rule_key': f'lead-file-write:{tool_name}:{digest}:{tool_call_id}',
            'message': f"승인하면 파일을 {'만들거나 씁니다' if tool_name == 'write_file' else '고칩니다'}: {args.get('path')}"}

def _run_disclaimed(services, command: list[str], timeout: float) -> SimpleNamespace:
    """Run a helper as its own responsible process and return its exit code and stdout.

    macOS judges Full Disk Access by the responsible process, which for a normal child is the
    gateway's launcher. Disclaiming makes the reader answer for itself, so only the reader
    needs the grant.
    """
    import ctypes
    import select

    libc = ctypes.CDLL(None, use_errno=True)
    attr = ctypes.c_void_p()
    actions = ctypes.c_void_p()
    if libc.posix_spawnattr_init(ctypes.byref(attr)) != 0:
        raise OSError("posix_spawnattr_init failed")
    libc.posix_spawn_file_actions_init(ctypes.byref(actions))
    read_fd, write_fd = os.pipe()
    pid = ctypes.c_int()
    try:
        if libc.responsibility_spawnattrs_setdisclaim(ctypes.byref(attr), 1) != 0:
            raise OSError("responsibility disclaim failed")
        libc.posix_spawn_file_actions_adddup2(ctypes.byref(actions), write_fd, 1)
        libc.posix_spawn_file_actions_addclose(ctypes.byref(actions), read_fd)
        argv = (ctypes.c_char_p * (len(command) + 1))(*[os.fsencode(part) for part in command], None)
        environment = [f"{key}={value}".encode() for key, value in os.environ.items()]
        envp = (ctypes.c_char_p * (len(environment) + 1))(*environment, None)
        code = libc.posix_spawn(
            ctypes.byref(pid), os.fsencode(command[0]), ctypes.byref(actions), ctypes.byref(attr), argv, envp,
        )
        if code != 0:
            raise OSError(code, os.strerror(code))
    except BaseException:
        os.close(read_fd)
        raise
    finally:
        os.close(write_fd)
        libc.posix_spawn_file_actions_destroy(ctypes.byref(actions))
        libc.posix_spawnattr_destroy(ctypes.byref(attr))
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([read_fd], [], [], remaining)[0]:
                os.kill(pid.value, 9)
                os.waitpid(pid.value, 0)
                raise subprocess.TimeoutExpired(command, timeout)
            data = os.read(read_fd, 65536)
            if not data:
                break
            chunks.append(data)
    finally:
        os.close(read_fd)
    _, status = os.waitpid(pid.value, 0)
    return SimpleNamespace(
        returncode=os.waitstatus_to_exitcode(status),
        stdout=b"".join(chunks).decode("utf-8", "replace"),
        stderr="",
    )

def _owner_chat_create(services) -> bool:
    """A create the owner asked for in chat runs without approval (2026-10-25 사용자 결정)."""
    return (services.get_session_env("HERMES_SESSION_PLATFORM", "").strip().lower() in {"slack", "photon"}
            and not services.personal_scopes.background(services.host))

def _owner_chat_no_approval(services, tool_name: str, action: str, args: dict[str, Any]) -> bool:
    """Owner-chat writes that skip the approval button: creates (2026-10-25) and moving a memo the
    owner called finished into the Notes folder 'complete' (2026-10-26 사용자 결정)."""
    if not services._owner_chat_create():
        return False
    if action == "create":
        return True
    return (tool_name == "apple_notes_direct_mutation" and action == "move"
            and str(args.get("folder") or "").strip() == "complete")

def _mutation_preview(services, authority: str, action: str, target: dict[str, Any]) -> str:
    preview_digest = services._remember_pending_personal_owner(f"{authority}:{action}", target)
    return json.dumps({
        "ok": False,
        "approval_required": True,
        "authority": authority,
        "action": action,
        "preview": target,
        "required_user_message": "삭제 승인" if action == "delete" else "승인",
        "pending_owner_saved": preview_digest is not None,
        "preview_digest": preview_digest,
        "mutation_calls": 0,
    }, ensure_ascii=False)
