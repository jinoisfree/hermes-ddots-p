"""Direct-owner workflow governance and personal tools."""

from __future__ import annotations

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text


import json
import base64
import fcntl
import hashlib
import logging
import html
from html.parser import HTMLParser
import os
import re
import sqlite3
import subprocess
import tempfile
import sys
import threading
import time
import unicodedata
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo

from gateway.session_context import get_session_env

# The same execution context serves a plugin host or a standalone pack consumer.
_library = Path(__file__).resolve().parent.parent
if str(_library) not in sys.path:
    sys.path.insert(0, str(_library))
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from hermes_packs.files_docs import scoped_files as files_pack
import hermes_governance as governance_pack
from hermes_governance import contracts
from hermes_packs import native_tools as native_pack
from hermes_packs.native_tools import contacts_files
from hermes_packs import linked_work as linked_pack
from hermes_packs import notes as notes_pack
from hermes_packs.notes import notes_format, notes_rebuild, notes_screen, obsidian_notes
from hermes_packs import calendar as calendar_pack
from hermes_packs.sns import media_save, load_video_jobs
video_job = load_video_jobs(__name__ + ".video_job")
from hermes_packs import mail as mail_pack
from hermes_packs.mail import gmail_watch, gmail_rules, mail_app, gmail_extra, full_mail_tools, google_reauth



from hermes_packs.linked_work.common_work_links import CommonWorkError, CommonWorkStore

try:
    from . import artifact_tools, paseo_tools, limit_report, personal_roles
except ImportError:
    import artifact_tools, paseo_tools, limit_report, personal_roles


from hermes_packs.linked_work import deadline_time, mail_work, work_capture
from hermes_governance import request_approvals, selected_skills
import importlib.util as _ilu, pathlib as _pl, sys as _sys

from hermes_facility import team_registry as team, owner_vault as vault, usage_observed

# The profile that owns personal work: calendar, notes, mail and message lookups.
PERSONAL_PROFILE = team.first_with("personal")
# Keep the original storage namespace for native IDs, attachments and recovery history.
# The opt-in executor is a separate role; changing it never moves or recreates originals.
def _governance_services():
    return governance_pack.Services(
        __file__=__file__,
        logger_name=__name__,
        BROWSER_ACT_TOOLS=BROWSER_ACT_TOOLS,
        COMMON_WORK_DOMAIN_ALIASES=COMMON_WORK_DOMAIN_ALIASES,
        CommonWorkError=CommonWorkError,
        DEFAULT_NOTES_FOLDER=DEFAULT_NOTES_FOLDER,
        EXTERNAL_WAIT_TOOLS=EXTERNAL_WAIT_TOOLS,
        GMAIL_LABEL_FILTER_WRITES=GMAIL_LABEL_FILTER_WRITES,
        INBOX_NOTES_FOLDER=INBOX_NOTES_FOLDER,
        LEAD_BROWSE_TOOLS=LEAD_BROWSE_TOOLS,
        LEAD_CHAT_TOOLS=LEAD_CHAT_TOOLS,
        LEAD_FILE_CHANGE_TOOLS=LEAD_FILE_CHANGE_TOOLS,
        LEAD_FILE_READ_TOOLS=LEAD_FILE_READ_TOOLS,
        LEAD_PROFILE=LEAD_PROFILE,
        LEARNING_TOOLS=LEARNING_TOOLS,
        MUTATION_TOOL_RE=MUTATION_TOOL_RE,
        PERSONAL_PROFILE=PERSONAL_PROFILE,
        SAFETY_TOOLS=SAFETY_TOOLS,
        SHELL_TOOLS=SHELL_TOOLS,
        TokenEfficiencyHardStop=TokenEfficiencyHardStop,
        UNVERIFIED_LINK_NOTE=UNVERIFIED_LINK_NOTE,
        URL_OPEN_TOOLS=URL_OPEN_TOOLS,
        WEB_READ_TOOLS=WEB_READ_TOOLS,
        WIKI_PROFILES=WIKI_PROFILES,
        _ARTIFACT_POLICY=_ARTIFACT_POLICY,
        _BARE_HOST_RE=_BARE_HOST_RE,
        _CAPTION_ROWS=_CAPTION_ROWS,
        _COUNT_RE=_COUNT_RE,
        _DEALS_RE=_DEALS_RE,
        _FILE_READ_SCOPES=_FILE_READ_SCOPES,
        _GATE_MEMORY_SECONDS=_GATE_MEMORY_SECONDS,
        _INBOX_ROLLBACK_LOCK=_INBOX_ROLLBACK_LOCK,
        _INBOX_ROLLBACK_RESULTS=_INBOX_ROLLBACK_RESULTS,
        _JSON_UNICODE_RE=_JSON_UNICODE_RE,
        _LAST_BROWSER_ACT=_LAST_BROWSER_ACT,
        _LAST_USER_TEXT=_LAST_USER_TEXT,
        _LEAD_CARD_POLICY=_LEAD_CARD_POLICY,
        _LEAD_CHAT_POLICY=_LEAD_CHAT_POLICY,
        _LEAD_LEARNING_POLICY=_LEAD_LEARNING_POLICY,
        _MESSAGES_LOOKUP_LOCK=_MESSAGES_LOOKUP_LOCK,
        _MESSAGES_LOOKUP_SCOPES=_MESSAGES_LOOKUP_SCOPES,
        _NAVIGATION_KEYS=_NAVIGATION_KEYS,
        _NETWORK_COMMAND_RE=_NETWORK_COMMAND_RE,
        _PAGE_VIEWS=_PAGE_VIEWS,
        _PERSONAL_BUNDLE_APPROVAL_LOCK=_PERSONAL_BUNDLE_APPROVAL_LOCK,
        _PERSONAL_BUNDLE_APPROVAL_SCOPES=_PERSONAL_BUNDLE_APPROVAL_SCOPES,
        _PLUGIN_CONTEXT=_PLUGIN_CONTEXT,
        _REVIEW_SKILL_LEARNING=_REVIEW_SKILL_LEARNING,
        _RUNTIME=_RUNTIME,
        _SEEN_URLS=_SEEN_URLS,
        _SEEN_URLS_LOCK=_SEEN_URLS_LOCK,
        _SEEN_URLS_TTL_SECONDS=_SEEN_URLS_TTL_SECONDS,
        _SENDS_RE=_SENDS_RE,
        _SKILL_APPROVALS=_SKILL_APPROVALS,
        _SKILL_APPROVAL_LOCK=_SKILL_APPROVAL_LOCK,
        _SNAPSHOT_LINE_RE=_SNAPSHOT_LINE_RE,
        _SNAPSHOT_NAME_RE=_SNAPSHOT_NAME_RE,
        _SNAPSHOT_REF_RE=_SNAPSHOT_REF_RE,
        _URL_RE=_URL_RE,
        _WEB_READ_SCOPES=_WEB_READ_SCOPES,
        _WIKI_DIRECT_POLICY=_WIKI_DIRECT_POLICY,
        _WIKI_NO_WEB_POLICY=_WIKI_NO_WEB_POLICY,
        _active_contract=_active_contract,
        _acts_on_the_site=_acts_on_the_site,
        _address_key=_address_key,
        _addresses_in=_addresses_in,
        _answer_in_one_post=_answer_in_one_post,
        _append_request_policy=_append_request_policy,
        _approved_after_the_gate=_approved_after_the_gate,
        _browsing=_browsing,
        _bundle_completes=_bundle_completes,
        _bundle_plan_lines=_bundle_plan_lines,
        _bundle_requires_approval=_bundle_requires_approval,
        _calendar_event_get=_calendar_event_get,
        _card_tool_texts=_card_tool_texts,
        _check_budgets=_check_budgets,
        _clear_pending_personal_owner=_clear_pending_personal_owner,
        _common_source_day=_common_source_day,
        _common_work_profile=_common_work_profile,
        _common_work_store=_common_work_store,
        _common_work_summary=_common_work_summary,
        _company_auto_link_candidate=_company_auto_link_candidate,
        _company_notion_page=_company_notion_page,
        _contacts_arguments=_contacts_arguments,
        _conversation_scopes=_conversation_scopes,
        _current_inbound_route_reason=_current_inbound_route_reason,
        _current_page_address=_current_page_address,
        _error=_error,
        _fingerprint_error=_fingerprint_error,
        _gate_memory_path=_gate_memory_path,
        _gate_thread=_gate_thread,
        _gmail_account=_gmail_account,
        _gmail_mutation_plan=_gmail_mutation_plan,
        _gmail_scope_preflight=_gmail_scope_preflight,
        _governed_task_id=_governed_task_id,
        _hard_stop=_hard_stop,
        _home_profile=_home_profile,
        _inbox_rollback_note=_inbox_rollback_note,
        _inside=_inside,
        _is_executor=_is_executor,
        _is_wiki=_is_wiki,
        _lead_address_gate=_lead_address_gate,
        _lead_browse_context=_lead_browse_context,
        _lead_browse_gate=_lead_browse_gate,
        _lead_chat_policy=_lead_chat_policy,
        _lead_file_policy=_lead_file_policy,
        _lead_file_problem=_lead_file_problem,
        _lead_folders=_lead_folders,
        _lead_learning_enabled=_lead_learning_enabled,
        _lead_skill_approval=_lead_skill_approval,
        _lead_skill_context_problem=_lead_skill_context_problem,
        _lead_skill_write_classification=_lead_skill_write_classification,
        _lead_skill_write_gate=_lead_skill_write_gate,
        _lead_skill_write_problem=_lead_skill_write_problem,
        _lead_workspace_root=_lead_workspace_root,
        _lead_workspace_write_approval=_lead_workspace_write_approval,
        _mark_request_scope=_mark_request_scope,
        _messages_lookup_in_request=_messages_lookup_in_request,
        _messages_request_scope=_messages_request_scope,
        _normalize_common_work_domain=_normalize_common_work_domain,
        _normalize_personal_bundle_args=_normalize_personal_bundle_args,
        _note_browser_act=_note_browser_act,
        _note_gate_shown=_note_gate_shown,
        _note_link_state=_note_link_state,
        _note_verification_snapshot=_note_verification_snapshot,
        _notes_button_action=_notes_button_action,
        _notes_current_owner_text=_notes_current_owner_text,
        _one_button_plan=_one_button_plan,
        _owner_chat_create=_owner_chat_create,
        _owner_chat_no_approval=_owner_chat_no_approval,
        _page_off_the_public_web=_page_off_the_public_web,
        _page_view=_page_view,
        _pending_personal_path=_pending_personal_path,
        _pending_personal_route=_pending_personal_route,
        _pending_personal_store=_pending_personal_store,
        _personal_actor=_personal_actor,
        _personal_executor=_personal_executor,
        _personal_mutation_approval_single=_personal_mutation_approval_single,
        _personal_role_problem=_personal_role_problem,
        _personal_work_rollback=_personal_work_rollback,
        _prune_skill_approvals=_prune_skill_approvals,
        _public_web_url=_public_web_url,
        _read_from_the_web_cache=_read_from_the_web_cache,
        _read_gate_memory=_read_gate_memory,
        _reads_the_web=_reads_the_web,
        _refs_in=_refs_in,
        _register_approved_common_work_source=_register_approved_common_work_source,
        _remember_addresses=_remember_addresses,
        _remember_page=_remember_page,
        _remember_pending_personal_owner=_remember_pending_personal_owner,
        _request_scope_marked=_request_scope_marked,
        _runtime=_runtime,
        _safe_endpoint=_safe_endpoint,
        _secretary_cron_back=_secretary_cron_back,
        _settings=_settings,
        _shown_addresses=_shown_addresses,
        _skill_call_identity=_skill_call_identity,
        _squeezed=_squeezed,
        _strings=_strings,
        _task_capture_owner_chat=_task_capture_owner_chat,
        _task_contract=_task_contract,
        _team_kit_review_skill_write=_team_kit_review_skill_write,
        _tool_schema_name=_tool_schema_name,
        _trim_address=_trim_address,
        _typed_by_the_user=_typed_by_the_user,
        _unescaped=_unescaped,
        _unlink_owner_deleted_source=_unlink_owner_deleted_source,
        _usage=_usage,
        _validate_bundle=_validate_bundle,
        _web_cache_root=_web_cache_root,
        _web_read_in_request=_web_read_in_request,
        _wiki_direct_llm_request=_wiki_direct_llm_request,
        _write_gate_memory=_write_gate_memory,
        artifact_tools=artifact_tools,
        deadline_time=deadline_time,
        enforcement_decision=enforcement_decision,
        full_mail_tools=full_mail_tools,
        get_session_env=get_session_env,
        gmail_rules=gmail_rules,
        host=sys.modules[__name__],
        limit_report=limit_report,
        media_save=media_save,
        obsidian_notes=obsidian_notes,
        paseo_tools=paseo_tools,
        personal_roles=personal_roles,
        personal_scopes=personal_scopes,
        request_approvals=request_approvals,
        selected_skills=selected_skills,
        team=team,
        usage_observed=usage_observed,
        video_job=video_job,
        work_capture=work_capture,
    )


def _personal_executor():
    return governance_pack._personal_executor(_governance_services())



def _is_executor(profile):
    return governance_pack._is_executor(_governance_services(), profile)



def _personal_actor():
    return governance_pack._personal_actor(_governance_services())



def _personal_role_problem(name, args):
    return governance_pack._personal_role_problem(_governance_services(), name, args)



# The profile people talk to by default: the starter_user-world chat posts to it unless another character is
# picked. In chat it may also search the web, read and work pages in the local browser and hand
# long jobs to its own Kanban worker.
LEAD_PROFILE = PERSONAL_PROFILE
WEB_READ_TOOLS = frozenset({
    "web_search", "web_extract", "browser_navigate", "browser_snapshot", "browser_scroll",
})
# Working a page, in chat or the lead's own card: a site's search box, filters and map pins. Looking around runs
# freely, because the local browser carries no login. What would go out stops at _lead_browse_gate:
# typed text nobody showed it, and an element named for sending, voting, buying or logging in.
# Those acts ask in chat and are refused on a card, where nobody can approve them.
BROWSER_ACT_TOOLS = frozenset({"browser_click", "browser_type", "browser_press"})
LEAD_BROWSE_TOOLS = BROWSER_ACT_TOOLS | {"browser_back"}
# The wiki profile works in a shell (wiki_cli, staging files), so in chat it is kept off the web:
# what it would read there could steer that shell. Web research belongs to the lead profile.
WIKI_PROFILES = frozenset({"", "default"})


def _is_wiki(profile):
    return governance_pack._is_wiki(_governance_services(), profile)


SHELL_TOOLS = frozenset({"terminal", "process", "execute_code", "write_file", "patch", "delegate_task"})
# A shell command that reaches the network brings outside text in by another door.
_NETWORK_COMMAND_RE = contracts.build__NETWORK_COMMAND_RE(re)
# Files: only inside the folders named in settings.lead_folders (reading also covers the web cache,
# where the rest of a page that came back cut short is kept) and among the documents the user attached
# in chat. Changing one asks the user every time.
LEAD_FILE_READ_TOOLS = frozenset({"read_file", "search_files"})
LEAD_FILE_CHANGE_TOOLS = frozenset({"write_file", "patch", "file_trash"})
LEARNING_TOOLS = frozenset({"team_learn", "team_learn_review", "team_skill_review", "report_status", "team_recall", "team_work", "team_project"})
LEAD_CHAT_TOOLS = contracts.build_LEAD_CHAT_TOOLS(LEAD_BROWSE_TOOLS, LEAD_FILE_CHANGE_TOOLS, LEAD_FILE_READ_TOOLS, WEB_READ_TOOLS, artifact_tools)

DOMAIN_CHANNELS: frozenset[str] = frozenset()
RECEIPT_VERSION = "1"
_PERSONAL_BUNDLE_APPROVAL_LOCK = threading.RLock()
_PERSONAL_BUNDLE_APPROVAL_SCOPES: dict[str, float] = {}
_PERSONAL_ROLLBACK_LOCK = threading.RLock()
# Inbound requests that read text messages. Message text is written by third parties, so a
# write bundle in the same request always goes through the human approval gate.
_MESSAGES_LOOKUP_LOCK = threading.RLock()
_MESSAGES_LOOKUP_SCOPES: dict[str, float] = {}
# The same for requests that read search results or web pages, and for ones that read a file.
_WEB_READ_SCOPES: dict[str, float] = {}
_FILE_READ_SCOPES: dict[str, float] = {}
# Addresses each conversation has been shown: by the user, a search result, a page, a file, a mail.
# The lead profile may compose addresses in chat. Cards ask before receiving an unseen address
# and refuse to open one of their own making when nobody is there.
URL_OPEN_TOOLS = frozenset({"web_extract", "browser_navigate"})
_SEEN_URLS_LOCK = threading.RLock()
_SEEN_URLS: dict[str, tuple[float, frozenset[str]]] = {}
_SEEN_URLS_TTL_SECONDS = 6 * 3600
_URL_RE = re.compile(r"https?://[^\s<>\"'`\\\]}|]+", re.IGNORECASE)
_BARE_HOST_RE = re.compile(r"(?<![\w@/.:-])(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s<>\"'`\\\]}|]*)?", re.IGNORECASE)
_JSON_UNICODE_RE = re.compile(r"\\u([0-9a-fA-F]{4})")
UNVERIFIED_LINK_NOTE = "(확인 안 된 주소)"
# How each conversation's page looked the last time the model saw it (ref -> role and name), the text
# it may type into one (the user's own words; what search results and pages showed), and the last
# call that acted in the browser. Kept beside the addresses, and for as long.
_PAGE_VIEWS: dict[str, tuple[float, dict[str, tuple[str, str]], str, str]] = {}
_LAST_BROWSER_ACT: dict[str, str] = {}
_SNAPSHOT_LINE_RE = re.compile(r"^(?:\s*\d+\|)?(\s*)- ([\w/-]+)(.*)$")
_SNAPSHOT_NAME_RE = re.compile(r'\s*"(.*?)"\s*(?=\[|:|$|"\s*[,}])')
_SNAPSHOT_REF_RE = re.compile(r"\[(?:[^\]\n]*[, ])?ref=(e\d+)[\],]")
# An unnamed element takes the text just inside it as its name when it holds this few lines (a map
# pin, an icon with a caption). A larger unnamed block is a container.
_CAPTION_ROWS = 8
_COUNT_RE = re.compile(r"\d[\d,.]*(?:\s*(?:원|개|명|건|회|천|만|억|[km](?![a-z])))*", re.IGNORECASE)
_KO_LEAD = "(?:바로|지금|즉시|무료|간편|댓글|답글|리뷰|후기|글)*"
_KO_TAIL = "(?:하기|하러가기)?"
# The whole name is an act: one click on it changes something on the site, whatever kind of element.
_SENDS_RE = re.compile(
    f"(?:{_KO_LEAD}(?:추천|비추천|좋아요|싫어요|공감|신고|투표|공유|구독|팔로우|찜|등록|작성|쓰기|제출|전송|발송"
    f"|보내기|올리기|게시|삭제|탈퇴){_KO_TAIL})+"
    "|submit|post|send|publish|share|like|upvote|downvote|vote|subscribe|follow|delete|tweet|donate")
# The whole name starts a purchase, a booking or a login. As a link it only opens the next page, where
# the login and the typing still stand in the way; as anything else it asks first.
_DEALS_RE = re.compile(
    f"(?:{_KO_LEAD}(?:구매|결제|주문|예약|예매|신청|접수|응모|로그인|회원가입|가입|장바구니|담기){_KO_TAIL})+"
    "|buy|buynow|purchase|checkout|pay|paynow|placeorder|ordernow|booknow|reserve|signin|login|signup"
    "|register|addtocart")
# Keys that move around a page. A key that writes a character would type what browser_type checks.
_NAVIGATION_KEYS = frozenset({
    "tab", "escape", "esc", "arrowup", "arrowdown", "arrowleft", "arrowright", "pageup", "pagedown",
    "home", "end", "backspace", "delete",
})

# 루트 홈에서 계산한다(홈이 다른 맥에서도 맞다).
COMMON_WORK_DB = Path(
    os.environ.get(
        "HERMES_COMMON_WORK_DB",
        str(team.root_home() / "shared" / "common-work-links.sqlite3"),
    )
)

_PLUGIN_CONTEXT: Any = None
_RUNTIME: dict[str, dict[str, Any]] = {}
# 메모 폴더 이름은 사장 금고(obsidian.folders.*)에서 온다. 없으면 어떤 폴더 이름과도 같지 않은 표식이라 메모를 엉뚱한 폴더에 만들지 않는다.
DEFAULT_NOTES_FOLDER = vault.text("obsidian.folders.tasks", "(owner-vault-notes-folder-unset)")
MESSAGES_READER = Path(
    os.environ.get("HERMES_MESSAGES_READER", str(team.root_home() / "bin" / "hermes-messages-reader"))
)
INBOX_NOTES_FOLDER = vault.text("obsidian.folders.inbox_label", "(owner-vault-inbox-folder-unset)")
DOCTOR_FINAL_VOICE_CONTRACT = contracts.build_DOCTOR_FINAL_VOICE_CONTRACT()


def _pending_personal_route() -> dict[str, str] | None:
    return governance_pack._pending_personal_route(_governance_services())



def _current_inbound_route_reason() -> str:
    return governance_pack._current_inbound_route_reason(_governance_services())



def _notes_current_owner_text() -> str:
    return governance_pack._notes_current_owner_text(_governance_services())



def _notes_create_folder(requested: str) -> str:
    return governance_pack._notes_create_folder(_governance_services(), requested)



def _pending_personal_path() -> Path:
    return governance_pack._pending_personal_path(_governance_services())



def _pending_personal_store() -> Any:
    return governance_pack._pending_personal_store(_governance_services())



def _remember_pending_personal_owner(operation: str, payload: dict[str, Any]) -> str | None:
    return governance_pack._remember_pending_personal_owner(_governance_services(), operation, payload)



def _clear_pending_personal_owner() -> None:
    return governance_pack._clear_pending_personal_owner(_governance_services())



SAFETY_TOOLS = contracts.build_SAFETY_TOOLS()
EXTERNAL_WAIT_TOOLS = frozenset({
    "clarify", "browser_vault_enter_code", "browser_vault_unlock", "browser_vault_fill",
    "browser_vault_save_login",
})
MUTATION_TOOL_RE = re.compile(
    r"(^|_)(create|update|delete|remove|send|write|patch|attach|publish|modify|mutate|config_set)(_|$)",
    re.IGNORECASE,
)


class TokenEfficiencyHardStop(RuntimeError):
    """A governed workflow exceeded an explicitly enabled hard boundary."""

    middleware_hard_stop = True


def _home_profile() -> str:
    return governance_pack._home_profile(_governance_services())



def _settings() -> dict[str, Any]:
    return governance_pack._settings(_governance_services())



def enforcement_decision(contract: dict[str, Any] | None, settings: dict[str, Any] | None = None) -> dict[str, Any]:
    return governance_pack.enforcement_decision(_governance_services(), contract, settings)



def _task_contract(task_id: str | None, board: str | None = None) -> dict[str, Any]:
    return governance_pack._task_contract(_governance_services(), task_id, board)



def _active_contract(task_id: str | None = None, board: str | None = None) -> dict[str, Any]:
    return governance_pack._active_contract(_governance_services(), task_id, board)



def _governed_task_id(context: dict[str, Any]) -> str:
    return governance_pack._governed_task_id(_governance_services(), context)



def _runtime(task_id: str) -> dict[str, Any]:
    return governance_pack._runtime(_governance_services(), task_id)



def _hard_stop(code: str, detail: str, state: dict[str, Any] | None = None) -> None:
    return governance_pack._hard_stop(_governance_services(), code, detail, state)



def _usage(result: Any) -> dict[str, Any]:
    return governance_pack._usage(_governance_services(), result)



def _safe_endpoint(value: Any) -> str | None:
    return governance_pack._safe_endpoint(_governance_services(), value)



def _check_budgets(contract: dict[str, Any], state: dict[str, Any], *, before_model: bool = False) -> None:
    return governance_pack._check_budgets(_governance_services(), contract, state, before_model=before_model)



def _llm_execution_guard(request: dict[str, Any], next_call, **context: Any) -> Any:
    return governance_pack._llm_execution_guard(_governance_services(), request, next_call, **context)



def _tool_schema_name(tool: Any) -> str:
    return governance_pack._tool_schema_name(_governance_services(), tool)



_WIKI_DIRECT_POLICY = contracts.build__WIKI_DIRECT_POLICY()


def _append_request_policy(request: dict[str, Any], policy: str) -> dict[str, Any] | None:
    return governance_pack._append_request_policy(_governance_services(), request, policy)



def _reads_the_web(tool_name: str) -> bool:
    return governance_pack._reads_the_web(_governance_services(), tool_name)



def _lead_browse_context() -> str:
    return governance_pack._lead_browse_context(_governance_services())



_WIKI_NO_WEB_POLICY = contracts.build__WIKI_NO_WEB_POLICY()


def _wiki_direct_llm_request(request: dict[str, Any]) -> dict[str, Any] | None:
    return governance_pack._wiki_direct_llm_request(_governance_services(), request)



_LEAD_PAGE_CRAFT = contracts.build__LEAD_PAGE_CRAFT()


_LEAD_CHAT_POLICY = contracts.build__LEAD_CHAT_POLICY(LEAD_PROFILE, _LEAD_PAGE_CRAFT)

_LEAD_LEARNING_POLICY = contracts.build__LEAD_LEARNING_POLICY()


def _lead_learning_enabled() -> bool:
    return governance_pack._lead_learning_enabled(_governance_services())



def _lead_chat_policy() -> str:
    return governance_pack._lead_chat_policy(_governance_services())



_LEAD_CARD_POLICY = contracts.build__LEAD_CARD_POLICY(_LEAD_PAGE_CRAFT)


def _lead_file_policy() -> str:
    return governance_pack._lead_file_policy(_governance_services())



_TOOL_TIERS_MODULE = None


def _tiered_personal_request(request, **context):
    """Run display tiers only after the existing role/account allowlist."""
    global _TOOL_TIERS_MODULE
    from hermes_constants import get_hermes_home
    routed = _personal_direct_llm_request(request, **context)
    payload = routed['request'] if routed else request
    home = Path(get_hermes_home())
    if not team.home_has_role(home, 'work', 'personal'):
        return routed
    try:
        if _TOOL_TIERS_MODULE is None:
            import importlib.util
            from hermes_facility.loading import source_path
            path = source_path('hermes_team_services.tool_tiers')
            if not path.exists():
                return routed
            spec = importlib.util.spec_from_file_location('team_kit_display_tiers', path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _TOOL_TIERS_MODULE = module
        return _TOOL_TIERS_MODULE.request(home, payload, **context) or routed
    except Exception as exc:
        logging.getLogger(__name__).warning('Tool tier display failed: %s', type(exc).__name__)
        # Never discard the preceding permission filter if optional display shaping fails.
        return {'request': payload, 'source': 'team-delegation', 'tool_tiers_error': type(exc).__name__}



def _personal_direct_llm_request(request: dict[str, Any], **context: Any) -> dict[str, Any] | None:
    return governance_pack._personal_direct_llm_request(_governance_services(), request, **context)



_INBOX_ROLLBACK_RESULTS: dict[str, str] = {}
_INBOX_ROLLBACK_LOCK = threading.Lock()


def _inbox_rollback_note() -> str:
    return governance_pack._inbox_rollback_note(_governance_services())



def _fingerprint_error(exc: BaseException) -> str:
    return governance_pack._fingerprint_error(_governance_services(), exc)



def _lead_skill_write_problem(args: Any) -> str | None:
    return governance_pack._lead_skill_write_problem(_governance_services(), args)



def _lead_skill_write_classification(args: Any) -> tuple[str, str]:
    return governance_pack._lead_skill_write_classification(_governance_services(), args)



_SKILL_APPROVAL_LOCK = threading.RLock()
_SKILL_APPROVALS: dict[str, dict[str, Any]] = {}


_REVIEW_SKILL_LEARNING: list[Any] = []


def _team_kit_review_skill_write(tool_name: str) -> bool:
    return governance_pack._team_kit_review_skill_write(_governance_services(), tool_name)



def _lead_skill_context_problem() -> str | None:
    return governance_pack._lead_skill_context_problem(_governance_services())



def _skill_call_identity(args: Any, context: dict[str, Any]) -> tuple:
    return governance_pack._skill_call_identity(_governance_services(), args, context)



def _prune_skill_approvals() -> None:
    return governance_pack._prune_skill_approvals(_governance_services())



def _lead_skill_approval(args: Any, **context: Any) -> dict[str, str] | None:
    return governance_pack._lead_skill_approval(_governance_services(), args, **context)



def _lead_skill_approval_response(pattern_key: str = "", choice: str = "", **_: Any) -> None:
    return governance_pack._lead_skill_approval_response(_governance_services(), pattern_key, choice, **_)



def _lead_skill_write_gate(args: Any, **context: Any) -> str | None:
    return governance_pack._lead_skill_write_gate(_governance_services(), args, **context)



def _secretary_cron_back(profile, tool_name):
    return governance_pack._secretary_cron_back(_governance_services(), profile, tool_name)



def _tool_execution_guard(tool_name: str, args: dict[str, Any], next_call, **context: Any) -> Any:
    return governance_pack._tool_execution_guard(_governance_services(), tool_name, args, next_call, **context)



def _gmail_mutation_plan(args: dict[str, Any]) -> str:
    return governance_pack._gmail_mutation_plan(_governance_services(), args)



def _notes_button_action(tool_name: str, args: dict[str, Any]) -> str | None:
    return governance_pack._notes_button_action(_governance_services(), tool_name, args)



def _one_button_plan(tool_name: str, action: str, args: dict[str, Any]) -> str:
    return governance_pack._one_button_plan(_governance_services(), tool_name, action, args)



def _personal_mutation_approval_single(
    tool_name: str,
    args: dict[str, Any],
    tool_call_id: str = "",
    turn_id: str = "",
    session_id: str = "",
    **_: Any,
) -> dict[str, str] | None:
    return governance_pack._personal_mutation_approval_single(_governance_services(), tool_name, args, tool_call_id, turn_id, session_id, **_)



def _personal_mutation_approval(tool_name, args, tool_call_id='', turn_id='', session_id='', **context):
    return governance_pack._personal_mutation_approval(_governance_services(), tool_name, args, tool_call_id, turn_id, session_id, **context)



def _linked_services():
    return linked_pack.Services(
        APPLE_NOTES_DIRECT_MUTATION_SCHEMA=APPLE_NOTES_DIRECT_MUTATION_SCHEMA,
        CALENDAR_DIRECT_MUTATION_SCHEMA=CALENDAR_DIRECT_MUTATION_SCHEMA,
        COMMON_WORK_DB=COMMON_WORK_DB,
        CommonWorkError=CommonWorkError,
        CommonWorkStore=CommonWorkStore,
        PERSONAL_ROLLBACK_WINDOW_SECONDS=PERSONAL_ROLLBACK_WINDOW_SECONDS,
        _BUNDLE_ARGUMENT_ALIASES=_BUNDLE_ARGUMENT_ALIASES,
        _BUNDLE_IGNORED_ARGUMENTS=_BUNDLE_IGNORED_ARGUMENTS,
        _FILE_READ_SCOPES=_FILE_READ_SCOPES,
        _KNOWLEDGE_REF_MUTATION_TYPES=_KNOWLEDGE_REF_MUTATION_TYPES,
        _NOTE_RENAME_SUMMARY_REQUIRED=_NOTE_RENAME_SUMMARY_REQUIRED,
        _PERSONAL_ROLLBACK_LOCK=_PERSONAL_ROLLBACK_LOCK,
        _PERSONAL_ROLLBACK_RETENTION_SECONDS=_PERSONAL_ROLLBACK_RETENTION_SECONDS,
        _append_personal_rollback_entry=_append_personal_rollback_entry,
        _apple_notes_direct_mutation=_apple_notes_direct_mutation,
        _apply_bundle_argument_aliases=_apply_bundle_argument_aliases,
        _bundle_argument_names=_bundle_argument_names,
        _bundle_completes=_bundle_completes,
        _bundle_completion=_bundle_completion,
        _bundle_digest=_bundle_digest,
        _bundle_key=_bundle_key,
        _bundle_native_source=_bundle_native_source,
        _bundle_requires_approval=_bundle_requires_approval,
        _calendar_alarm_error=_calendar_alarm_error,
        _calendar_direct_mutation=_calendar_direct_mutation,
        _calendar_identity_error=_calendar_identity_error,
        _clear_pending_personal_owner=_clear_pending_personal_owner,
        _clear_personal_rollback=_clear_personal_rollback,
        _common_work_complete=_common_work_complete,
        _common_work_error=_common_work_error,
        _common_work_profile=_common_work_profile,
        _common_work_store=_common_work_store,
        _company_notion_page=_company_notion_page,
        _error=_error,
        _home_profile=_home_profile,
        _inverse_bundle_operation=_inverse_bundle_operation,
        _is_executor=_is_executor,
        _latest_personal_rollback_entry=_latest_personal_rollback_entry,
        _link_bundle_sources=_link_bundle_sources,
        _lookup_common_work_source=_lookup_common_work_source,
        _messages_lookup_in_request=_messages_lookup_in_request,
        _normalize_calendar_dates=_normalize_calendar_dates,
        _normalize_common_work_domain=_normalize_common_work_domain,
        _normalize_personal_bundle_args=_normalize_personal_bundle_args,
        _note_snapshot=_note_snapshot,
        _notes_create_folder=_notes_create_folder,
        _notes_reuse_source=_notes_reuse_source,
        _personal_actor=_personal_actor,
        _personal_executor=_personal_executor,
        _personal_owner_error=_personal_owner_error,
        _personal_role_problem=_personal_role_problem,
        _personal_rollback_conversation=_personal_rollback_conversation,
        _personal_rollback_path=_personal_rollback_path,
        _preserve_note_context=_preserve_note_context,
        _read_personal_rollback_journal=_read_personal_rollback_journal,
        _request_scope_marked=_request_scope_marked,
        _require_common_work_access=_require_common_work_access,
        _require_knowledge_ref_access=_require_knowledge_ref_access,
        _save_personal_rollback=_save_personal_rollback,
        _select_personal_rollback=_select_personal_rollback,
        _structured_note_body=_structured_note_body,
        _task_capture_owner_chat=_task_capture_owner_chat,
        _validate_bundle=_validate_bundle,
        _web_read_in_request=_web_read_in_request,
        _write_personal_rollback_journal=_write_personal_rollback_journal,
        get_session_env=get_session_env,
        host=sys.modules[__name__],
        mail_work=mail_work,
        obsidian_notes=obsidian_notes,
        personal_roles=personal_roles,
        personal_scopes=personal_scopes,
        team=team,
        vault=vault,
        work_capture=work_capture,
    )


def _mail_work(args, **_):
    return linked_pack._mail_work(_linked_services(), args, **_)



def _error(message: str, /, **fields: Any) -> str:
    return governance_pack._error(_governance_services(), message, **fields)



def _on_claim(*, task_id: str, board: str | None = None, run_id: int | None = None, **_: Any) -> None:
    return governance_pack._on_claim(_governance_services(), task_id=task_id, board=board, run_id=run_id, **_)



GATEWAY_RUNTIME_SNAPSHOT_SCHEMA = contracts.build_GATEWAY_RUNTIME_SNAPSHOT_SCHEMA()


REQUEST_USAGE_LOOKUP_SCHEMA = contracts.build_REQUEST_USAGE_LOOKUP_SCHEMA()


_REQUEST_USAGE_FIELDS = contracts.build__REQUEST_USAGE_FIELDS()


def _native_services():
    return native_pack.Services(
        CONTACTS_DIRECT_LOOKUP_SCHEMA=CONTACTS_DIRECT_LOOKUP_SCHEMA,
        CONTACTS_DIRECT_MUTATION_SCHEMA=CONTACTS_DIRECT_MUTATION_SCHEMA,
        WIKI_VAULT=WIKI_VAULT,
        MESSAGES_READER=MESSAGES_READER,
        RECEIPT_VERSION=RECEIPT_VERSION,
        _CONTACTS_CHAIN_FIELDS=_CONTACTS_CHAIN_FIELDS,
        _CONTACTS_STAGES=_CONTACTS_STAGES,
        _REQUEST_USAGE_FIELDS=_REQUEST_USAGE_FIELDS,
        _WIKI_MARKER_RE=_WIKI_MARKER_RE,
        _WIKI_OUTPUT_LIMIT=_WIKI_OUTPUT_LIMIT,
        _calendar_cache_root=_calendar_cache_root,
        _contacts_app_ready=_contacts_app_ready,
        _contacts_arguments=_contacts_arguments,
        _contacts_backup=_contacts_backup,
        _contacts_direct=_contacts_direct,
        _contacts_image_root=_contacts_image_root,
        _contacts_native_diagnostics=_contacts_native_diagnostics,
        _contacts_note=_contacts_note,
        _contacts_note_detail=_contacts_note_detail,
        _contacts_note_get=_contacts_note_get,
        _contacts_note_set=_contacts_note_set,
        _contacts_note_snapshot=_contacts_note_snapshot,
        _direct_receipt=_direct_receipt,
        _error=_error,
        _home_profile=_home_profile,
        _is_gateway_process=_is_gateway_process,
        _mark_messages_lookup=_mark_messages_lookup,
        _messages_reader=_messages_reader,
        _personal_owner_error=_personal_owner_error,
        _personal_role_problem=_personal_role_problem,
        _recorded_gateway_pid=_recorded_gateway_pid,
        _request_usage_message_order=_request_usage_message_order,
        _run_disclaimed=_run_disclaimed,
        _runtime=_runtime,
        _task_contract=_task_contract,
        _wiki_clip=_wiki_clip,
        _wiki_link=_wiki_link,
        _wiki_note_paths=_wiki_note_paths,
        _wiki_resolve=_wiki_resolve,
        contacts_files=contacts_files,
        get_session_env=get_session_env,
        team=team,
    )


def _request_usage_message_order(message_id: str) -> tuple[int, int, int, str]:
    return native_pack._request_usage_message_order(_native_services(), message_id)



def _request_usage_lookup(args: dict[str, Any], **_: Any) -> str:
    return native_pack._request_usage_lookup(_native_services(), args, **_)



def _is_gateway_process(pid: int) -> bool:
    return native_pack._is_gateway_process(_native_services(), pid)



def _recorded_gateway_pid() -> int | None:
    return native_pack._recorded_gateway_pid(_native_services())



def _gateway_runtime_snapshot(args: dict[str, Any], **_: Any) -> str:
    return native_pack._gateway_runtime_snapshot(_native_services(), args, **_)



MESSAGES_DIRECT_LOOKUP_SCHEMA = contracts.build_MESSAGES_DIRECT_LOOKUP_SCHEMA()


APPLE_NOTES_DIRECT_LOOKUP_SCHEMA = contracts.build_APPLE_NOTES_DIRECT_LOOKUP_SCHEMA()


APPLE_NOTES_DIRECT_MUTATION_SCHEMA = contracts.build_APPLE_NOTES_DIRECT_MUTATION_SCHEMA()


GMAIL_LABEL_FILTER_WRITES = frozenset({"label_create", "label_apply", "filter_create", "filter_delete", "mail_organize", "inbox_restore"})
GMAIL_LABEL_FILTER_ACTIONS = GMAIL_LABEL_FILTER_WRITES | {"labels", "filter_list"}
GMAIL_WRITE_FIELDS = contracts.build_GMAIL_WRITE_FIELDS()
GMAIL_CRITERIA_SCHEMA = contracts.build_GMAIL_CRITERIA_SCHEMA()


GMAIL_DIRECT_SCHEMA = contracts.build_GMAIL_DIRECT_SCHEMA(GMAIL_CRITERIA_SCHEMA)


full_mail_tools.extend_schema(GMAIL_DIRECT_SCHEMA)


def _personal_owner_error(tool_name: str) -> str | None:
    return governance_pack._personal_owner_error(_governance_services(), tool_name)



def _direct_receipt(work_type: str, authority: str, items: list[dict[str, Any]],
                    page: dict[str, Any] | None = None) -> str:
    return governance_pack._direct_receipt(_governance_services(), work_type, authority, items, page)



COMMON_WORK_DOMAIN_ALIASES = contracts.build_COMMON_WORK_DOMAIN_ALIASES()


def _normalize_common_work_domain(value: Any) -> str:
    return governance_pack._normalize_common_work_domain(_governance_services(), value)



def _common_work_summary(item: dict[str, Any] | None) -> dict[str, Any]:
    return governance_pack._common_work_summary(_governance_services(), item)



def _lookup_common_work_source(
    domain: str, source_id: str, *, store: CommonWorkStore | None = None
) -> dict[str, Any]:
    return governance_pack._lookup_common_work_source(_governance_services(), domain, source_id, store=store)



def _attach_common_work_links(
    items: list[dict[str, Any]], *, domain: str, source_id_field: str
) -> list[dict[str, Any]]:
    return linked_pack._attach_common_work_links(_linked_services(), items, domain=domain, source_id_field=source_id_field)



def _company_auto_link_candidate(item, day):
    return governance_pack._company_auto_link_candidate(_governance_services(), item, day)



def _register_approved_common_work_source(
    *, domain: str, source_id: str, title: str, common_id: str = "", source_date: str | None = None
) -> dict[str, Any]:
    return governance_pack._register_approved_common_work_source(_governance_services(), domain=domain, source_id=source_id, title=title, common_id=common_id, source_date=source_date)



def _messages_request_scope() -> str:
    return governance_pack._messages_request_scope(_governance_services())



def _mark_request_scope(scopes: dict[str, float]) -> None:
    return governance_pack._mark_request_scope(_governance_services(), scopes)



def _request_scope_marked(scopes: dict[str, float]) -> bool:
    return governance_pack._request_scope_marked(_governance_services(), scopes)



def _mark_messages_lookup() -> None:
    return governance_pack._mark_messages_lookup(_governance_services())



def _messages_lookup_in_request() -> bool:
    return governance_pack._messages_lookup_in_request(_governance_services())



def _web_read_in_request() -> bool:
    return governance_pack._web_read_in_request(_governance_services())



def _public_web_url(url: Any) -> bool:
    return governance_pack._public_web_url(_governance_services(), url)



_LAST_USER_TEXT: dict[str, str] = {}
_GATE_MEMORY_SECONDS = 7 * 86400


def _gate_memory_path() -> Path:
    return governance_pack._gate_memory_path(_governance_services())



def _gate_thread() -> str:
    return governance_pack._gate_thread(_governance_services())



def _read_gate_memory() -> dict[str, dict[str, float]]:
    return governance_pack._read_gate_memory(_governance_services())



def _write_gate_memory(data: dict[str, dict[str, float]]) -> None:
    return governance_pack._write_gate_memory(_governance_services(), data)



def _note_gate_shown(digest: str) -> None:
    return governance_pack._note_gate_shown(_governance_services(), digest)



def _approved_after_the_gate(digest: str, *, session_id: str = "") -> bool:
    return governance_pack._approved_after_the_gate(_governance_services(), digest, session_id=session_id)



def _typed_by_the_user(text: str) -> str:
    return governance_pack._typed_by_the_user(_governance_services(), text)



def _answer_in_one_post(created: Any) -> None:
    return governance_pack._answer_in_one_post(_governance_services(), created)



def _trim_address(url: str) -> str:
    return governance_pack._trim_address(_governance_services(), url)



def _address_key(url: Any) -> str:
    return governance_pack._address_key(_governance_services(), url)



def _addresses_in(text: str, *, typed: bool = False) -> set[str]:
    return governance_pack._addresses_in(_governance_services(), text, typed=typed)



def _strings(value: Any):
    return governance_pack._strings(_governance_services(), value)



def _conversation_scopes(session_id: str = "") -> list[str]:
    return governance_pack._conversation_scopes(_governance_services(), session_id)



def _remember_addresses(request: dict[str, Any], session_id: str = "") -> None:
    return governance_pack._remember_addresses(_governance_services(), request, session_id)



def _shown_addresses(session_id: str = "") -> frozenset[str]:
    return governance_pack._shown_addresses(_governance_services(), session_id)



def _lead_address_gate(
    tool_name: str, args: dict[str, Any], *, unattended: bool, session_id: str = "",
) -> dict[str, str] | None:
    return governance_pack._lead_address_gate(_governance_services(), tool_name, args, unattended=unattended, session_id=session_id)



def _unescaped(text: str) -> str:
    return governance_pack._unescaped(_governance_services(), text)



def _squeezed(text: Any) -> str:
    return governance_pack._squeezed(_governance_services(), text)



def _refs_in(text: str) -> dict[str, tuple[str, str]]:
    return governance_pack._refs_in(_governance_services(), text)



def _read_from_the_web_cache(arguments: Any) -> bool:
    return governance_pack._read_from_the_web_cache(_governance_services(), arguments)



def _card_tool_texts(content: Any) -> list[str]:
    return governance_pack._card_tool_texts(_governance_services(), content)



def _remember_page(request: dict[str, Any], session_id: str = "") -> None:
    return governance_pack._remember_page(_governance_services(), request, session_id)



def _page_view(session_id: str = "") -> tuple[dict[str, tuple[str, str]], str, str]:
    return governance_pack._page_view(_governance_services(), session_id)



def _note_browser_act(tool_name: str, session_id: str = "") -> None:
    return governance_pack._note_browser_act(_governance_services(), tool_name, session_id)



def _acts_on_the_site(role: str, label: str) -> bool:
    return governance_pack._acts_on_the_site(_governance_services(), role, label)



def _lead_browse_gate(
    tool_name: str, args: dict[str, Any], *, unattended: bool, session_id: str = "", tool_call_id: str = "",
) -> dict[str, str] | None:
    return governance_pack._lead_browse_gate(_governance_services(), tool_name, args, unattended=unattended, session_id=session_id, tool_call_id=tool_call_id)



def _browsing(next_call, tool_name: str, context: dict[str, Any]):
    return governance_pack._browsing(_governance_services(), next_call, tool_name, context)



def _current_page_address(task_id: Any) -> str:
    return governance_pack._current_page_address(_governance_services(), task_id)



def _page_off_the_public_web(task_id: Any, url: str | None = None) -> str:
    return governance_pack._page_off_the_public_web(_governance_services(), task_id, url)



def _mark_unverified_links(response_text: Any = "", platform: Any = "", session_id: Any = "", **_: Any) -> str | None:
    return governance_pack._mark_unverified_links(_governance_services(), response_text, platform, session_id, **_)



def _web_cache_root() -> Path:
    return governance_pack._web_cache_root(_governance_services())



def _attachment_root() -> Path:
    return governance_pack._attachment_root(_governance_services())




def _image_attachment_root() -> Path:
    return governance_pack._image_attachment_root(_governance_services())



def _video_attachment_root() -> Path:
    return governance_pack._video_attachment_root(_governance_services())



def _generated_root() -> Path:
    return governance_pack._generated_root(_governance_services())



def _lead_workspace_root() -> Path:
    # Do not resolve workspace itself: a symlink must not expand this allowance.
    return governance_pack._lead_workspace_root(_governance_services())



def _lead_workspace_write_approval(tool_name, args, *, tool_call_id=''):
    return governance_pack._lead_workspace_write_approval(_governance_services(), tool_name, args, tool_call_id=tool_call_id)



def _file_services():
    return files_pack.Services(
        context=_PLUGIN_CONTEXT, folders=_lead_folders, resolve=_inside,
        read_tools=LEAD_FILE_READ_TOOLS, web_cache=_web_cache_root,
        attachments=_attachment_root, images=_image_attachment_root,
        videos=_video_attachment_root, generated=_generated_root,
        workspace=_lead_workspace_root, error=_error,
        list_limit=_FILE_LIST_LIMIT, problem=_lead_file_problem, trash_script=_TRASH_SCRIPT,
    )


def _lead_folders() -> list[Path]:
    return files_pack.folders(_file_services())


def _inside(path: Any, roots: list[Path]) -> Path | None:
    return files_pack.inside(path, roots)


def _lead_file_problem(tool_name: str, args: dict[str, Any]) -> str | None:
    return files_pack.problem(_file_services(), tool_name, args)


_ARTIFACT_POLICY = contracts.build__ARTIFACT_POLICY()


def _artifact_generate(engine: str, args: dict[str, Any], **_: Any) -> str:
    return governance_pack._artifact_generate(_governance_services(), engine, args, **_)



def _paseo(args: dict[str, Any], **_: Any) -> str:
    return governance_pack._paseo(_governance_services(), args, **_)



def _limit_report(args: dict[str, Any], **_: Any) -> str:
    return governance_pack._limit_report(_governance_services(), args, **_)



FILE_LIST_SCHEMA = contracts.build_FILE_LIST_SCHEMA()
_FILE_LIST_LIMIT = 500


def _file_list(args: dict[str, Any], **_: Any) -> str:
    return files_pack.list_files(_file_services(), args, **_)


FILE_TRASH_SCHEMA = contracts.build_FILE_TRASH_SCHEMA()
# NSFileManager's own trash call: the item keeps its place in the Trash and iCloud sees a normal delete.
_TRASH_SCRIPT = (
    'ObjC.import("Foundation"); function run(argv) { return $.NSFileManager.defaultManager'
    '.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(argv[0]), null, null) ? "trashed" : "failed"; }'
)


def _file_trash(args: dict[str, Any], runner: Any = None, **_: Any) -> str:
    return files_pack.trash(_file_services(), args, runner=runner, **_)


def _run_disclaimed(command: list[str], timeout: float) -> SimpleNamespace:
    return governance_pack._run_disclaimed(_governance_services(), command, timeout)



def _messages_reader(runner: Any) -> tuple[Path | None, str]:
    return native_pack._messages_reader(_native_services(), runner)



def _messages_direct_lookup(args: dict[str, Any], **context: Any) -> str:
    return native_pack._messages_direct_lookup(_native_services(), args, **context)



class _NoteHTML(notes_pack.NoteHTML):
    def __init__(self):
        super().__init__(_notes_services())


def _notes_services():
    return notes_pack.Services(
        DEFAULT_NOTES_FOLDER=DEFAULT_NOTES_FOLDER,
        INBOX_NOTES_FOLDER=INBOX_NOTES_FOLDER,
        NOTE_CHOICE_LIMIT=NOTE_CHOICE_LIMIT,
        NOTE_CONTEXT_LIMIT=NOTE_CONTEXT_LIMIT,
        NOTE_ORIGINAL_HEADING=NOTE_ORIGINAL_HEADING,
        NOTE_PREVIEW_HEADING=NOTE_PREVIEW_HEADING,
        NOTE_PROGRESS_VALUES=NOTE_PROGRESS_VALUES,
        NOTE_STATE_RETENTION_DAYS=NOTE_STATE_RETENTION_DAYS,
        NOTE_SUMMARY_HEADING=NOTE_SUMMARY_HEADING,
        NoteAttachmentsNotPreserved=NoteAttachmentsNotPreserved,
        PERSONAL_PROFILE=PERSONAL_PROFILE,
        _LINKED_TITLE_AUTHORITY=_LINKED_TITLE_AUTHORITY,
        _NOTE_DUE_LABEL=_NOTE_DUE_LABEL,
        _NOTE_EXPORTS=_NOTE_EXPORTS,
        _NOTE_FILE_NAME_RE=_NOTE_FILE_NAME_RE,
        _NOTE_FILE_SIGNATURES=_NOTE_FILE_SIGNATURES,
        _NOTE_IMAGE_SUFFIXES=_NOTE_IMAGE_SUFFIXES,
        _NOTE_MARKS_DONE=_NOTE_MARKS_DONE,
        _NOTE_MARKS_OPEN=_NOTE_MARKS_OPEN,
        _NOTE_PROGRESS=_NOTE_PROGRESS,
        _NOTE_RENAME_SUMMARY_REQUIRED=_NOTE_RENAME_SUMMARY_REQUIRED,
        _NOTE_VERIFY_BUDGET_SECONDS=_NOTE_VERIFY_BUDGET_SECONDS,
        _NOTE_VERIFY_INTERVAL_SECONDS=_NOTE_VERIFY_INTERVAL_SECONDS,
        _NoteHTML=_NoteHTML,
        _append_note_rebuild=_append_note_rebuild,
        _apple_notes_direct_mutation=_apple_notes_direct_mutation,
        _apple_notes_restore=_apple_notes_restore,
        _apply_note_choice=_apply_note_choice,
        _attach_common_work_links=_attach_common_work_links,
        _cached_files_named=_cached_files_named,
        _calendar_cache_root=_calendar_cache_root,
        _clean_note_block_name=_clean_note_block_name,
        _clear_pending_personal_owner=_clear_pending_personal_owner,
        _direct_receipt=_direct_receipt,
        _drop_existing_note_files=_drop_existing_note_files,
        _error=_error,
        _export_note_attachments=_export_note_attachments,
        _is_note_image=_is_note_image,
        _linked_note_sections=_linked_note_sections,
        _mutation_preview=_mutation_preview,
        _note_apply_edits=_note_apply_edits,
        _note_block_icon=_note_block_icon,
        _note_choices=_note_choices,
        _note_choices_path=_note_choices_path,
        _note_context_path=_note_context_path,
        _note_first_title=_note_first_title,
        _note_html_with_progress=_note_html_with_progress,
        _note_link_state=_note_link_state,
        _note_missing_files=_note_missing_files,
        _note_native_info=_note_native_info,
        _note_parse_day=_note_parse_day,
        _note_plaintext=_note_plaintext,
        _note_progress=_note_progress,
        _note_progress_html=_note_progress_html,
        _note_verification_snapshot=_note_verification_snapshot,
        _notes_create_folder=_notes_create_folder,
        _notes_html=_notes_html,
        _notes_layout=_notes_layout,
        _notes_original_html=_notes_original_html,
        _notes_reuse_source=_notes_reuse_source,
        _notes_summary_html=_notes_summary_html,
        _original_from_plaintext=_original_from_plaintext,
        _owner_chat_no_approval=_owner_chat_no_approval,
        _personal_owner_error=_personal_owner_error,
        _preserve_note_context=_preserve_note_context,
        _read_note_context=_read_note_context,
        _register_approved_common_work_source=_register_approved_common_work_source,
        _remember_note_context=_remember_note_context,
        _removed_summary_blocks=_removed_summary_blocks,
        _save_note_choice=_save_note_choice,
        _select_note_attachments=_select_note_attachments,
        _seoul_stamp=_seoul_stamp,
        _squash=_squash,
        _stable_note_files=_stable_note_files,
        _structured_note_body=_structured_note_body,
        _unlink_owner_deleted_source=_unlink_owner_deleted_source,
        _update_note_state=_update_note_state,
        _verify_note_after_update=_verify_note_after_update,
        _verify_note_update=_verify_note_update,
        deadline_time=deadline_time,
        host=sys.modules[__name__],
        notes_format=notes_format,
        notes_rebuild=notes_rebuild,
        notes_screen=notes_screen,
        obsidian_notes=obsidian_notes,
    )


def _clean_note_block_name(name: str) -> str:
    # Strip decorative icons (including variation selectors), not letters or numbers.
    return notes_pack._clean_note_block_name(_notes_services(), name)



def _removed_summary_blocks(body_html: str, summary: str) -> list[str] | None:
    return notes_pack._removed_summary_blocks(_notes_services(), body_html, summary)



def _apple_notes_direct_lookup(args: dict[str, Any], **context: Any) -> str:
    return notes_pack._apple_notes_direct_lookup(_notes_services(), args, **context)



def _owner_chat_create() -> bool:
    return governance_pack._owner_chat_create(_governance_services())



def _owner_chat_no_approval(tool_name: str, action: str, args: dict[str, Any]) -> bool:
    return governance_pack._owner_chat_no_approval(_governance_services(), tool_name, action, args)



def _mutation_preview(authority: str, action: str, target: dict[str, Any]) -> str:
    return governance_pack._mutation_preview(_governance_services(), authority, action, target)



def _common_source_day(domain, result):
    return governance_pack._common_source_day(_governance_services(), domain, result)



def _unlink_owner_deleted_source(domain: str, source_id: str) -> list[str]:
    return governance_pack._unlink_owner_deleted_source(_governance_services(), domain, source_id)



def _native_mutation_result(
    authority: str,
    action: str,
    target_id: str | None,
    proc: Any,
    *,
    common_work_domain: str = "",
    common_work_title: str = "",
    common_id: str = "",
) -> str:
    return governance_pack._native_mutation_result(_governance_services(), authority, action, target_id, proc, common_work_domain=common_work_domain, common_work_title=common_work_title, common_id=common_id)



def _squash(text: str) -> str:
    return notes_pack._squash(_notes_services(), text)



def _seoul_stamp() -> str:
    return notes_pack._seoul_stamp(_notes_services())



NOTE_SUMMARY_HEADING = "[요약정리]"
NOTE_ORIGINAL_HEADING = "[원문]"
NOTE_PREVIEW_HEADING = "[한줄요약]"


def _structured_note_body(summary: Any, original_text: Any, preview_summary: Any = "") -> str:
    return notes_pack._structured_note_body(_notes_services(), summary, original_text, preview_summary)



def _note_block_icon(heading: str) -> str:
    return notes_pack._note_block_icon(_notes_services(), heading)



def _notes_summary_html(summary: str, layout: str = "table") -> str:
    # Keep the layout argument for callers; both folders share the same summary.
    return notes_pack._notes_summary_html(_notes_services(), summary, layout)



def _notes_original_html(original: str) -> str:
    return notes_pack._notes_original_html(_notes_services(), original)



_NOTE_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp"}


def _is_note_image(path: str) -> bool:
    return notes_pack._is_note_image(_notes_services(), path)



# Same note body → same exported originals within one update (preflight and rebuild).
_NOTE_EXPORTS: dict[tuple[str, str], list[str]] = {}
_NOTE_FILE_SIGNATURES = ((b"%PDF", ".pdf"), (b"\x89PNG", ".png"), (b"\xff\xd8\xff", ".jpg"),
                         (b"GIF8", ".gif"), (b"II*\x00", ".tif"), (b"MM\x00*", ".tif"))


def _export_note_attachments(note_id: str, runner: Any, body_html: str) -> list[str] | None:
    return notes_pack._export_note_attachments(_notes_services(), note_id, runner, body_html)



def _drop_existing_note_files(attachments, existing, mode) -> list[str]:
    return notes_pack._drop_existing_note_files(_notes_services(), attachments, existing, mode)



def _select_note_attachments(paths, existing=()):
    # Fresh HTML imports documents before native image attachments.
    return notes_pack._select_note_attachments(_notes_services(), paths, existing)



def _note_native_info(note_id: str, runner: Any) -> tuple[str | None, str]:
    return notes_pack._note_native_info(_notes_services(), note_id, runner)



def _notes_layout(folder: str) -> str:
    return notes_pack._notes_layout(_notes_services(), folder)



def _notes_html(
    title: str,
    body: str,
    attachments: list[str] | None = None,
    updated_at: str | None = None,
    created_at: str | None = None,
    attachment_analysis: str = "",
    layout: str = "table",
    progress: str = "",
) -> str:
    return notes_pack._notes_html(_notes_services(), title, body, attachments, updated_at, created_at, attachment_analysis, layout, progress)



NOTE_PROGRESS_VALUES = ("진행중", "완료")
_NOTE_PROGRESS = re.compile(r"· 진행도: (진행중|완료)\s*$")


def _note_progress_html(progress: str) -> str:
    # Lives on the 생성: line so the structured-summary parser and linked-work content ignore it.
    return notes_pack._note_progress_html(_notes_services(), progress)



def _note_progress(body_html: str) -> str:
    return notes_pack._note_progress(_notes_services(), body_html)



def _note_html_with_progress(body_html: str, progress: str) -> str | None:
    return notes_pack._note_html_with_progress(_notes_services(), body_html, progress)



def _stable_note_files(paths: list[str]) -> list[str]:
    return notes_pack._stable_note_files(_notes_services(), paths)



def _note_context_path() -> Path:
    return notes_pack._note_context_path(_notes_services())



def _read_note_context() -> dict[str, Any]:
    return notes_pack._read_note_context(_notes_services())



NOTE_STATE_RETENTION_DAYS = 30
NOTE_CONTEXT_LIMIT = 1000
NOTE_CHOICE_LIMIT = 200


def _update_note_state(path, key, row, limit):
    return notes_pack._update_note_state(_notes_services(), path, key, row, limit)



def _remember_note_context(note_id: str, attachments: list[str], original_text: str) -> None:
    return notes_pack._remember_note_context(_notes_services(), note_id, attachments, original_text)



_NOTE_FILE_NAME_RE = re.compile(
    r"[^\s/\\:*?\"<>|]+\.(?:pdf|png|jpe?g|gif|heic|heif|webp|docx?|xlsx?|pptx?|hwpx?|txt|csv|zip)",
    re.IGNORECASE,
)


def _note_plaintext(note_id: str, runner: Any) -> str:
    return notes_pack._note_plaintext(_notes_services(), note_id, runner)



def _cached_files_named(names: list[str]) -> list[str]:
    return notes_pack._cached_files_named(_notes_services(), names)



def _original_from_plaintext(plaintext: str, *, strip_prefix: bool = True) -> str:
    return notes_pack._original_from_plaintext(_notes_services(), plaintext, strip_prefix=strip_prefix)



NoteAttachmentsNotPreserved = notes_pack.NoteAttachmentsNotPreserved


def _preserve_note_context(
    note_id: str, attachments: list[str], original_text: str, runner: Any, *, reuse_source: bool = False,
) -> tuple[list[str], str]:
    return notes_pack._preserve_note_context(_notes_services(), note_id, attachments, original_text, runner, reuse_source=reuse_source)



def _note_snapshot(note_id: str, runner: Any) -> dict[str, str] | None:
    return notes_pack._note_snapshot(_notes_services(), note_id, runner)



def _note_verification_snapshot(note_id: str, runner: Any, *, timeout: float = 30) -> dict[str, Any] | None:
    return notes_pack._note_verification_snapshot(_notes_services(), note_id, runner, timeout=timeout)



def _verify_note_update(before, after, managed_files, removed):
    return notes_pack._verify_note_update(_notes_services(), before, after, managed_files, removed)



_NOTE_VERIFY_INTERVAL_SECONDS = 0.25
# Local Notes probe: PDF/body settled in 6.333–7.249s across 3 creates and 3 updates.
_NOTE_VERIFY_BUDGET_SECONDS = 10.0


def _note_first_title(snapshot):
    return notes_pack._note_first_title(_notes_services(), snapshot)



def _verify_note_after_update(note_id, runner, before, files, removed, *, title=None):
    return notes_pack._verify_note_after_update(_notes_services(), note_id, runner, before, files, removed, title=title)




def _note_missing_files(note_id, files, runner):
    return notes_pack._note_missing_files(_notes_services(), note_id, files, runner)



def _append_plain_note(note_id, line, before, runner=subprocess.run):
    return notes_pack._append_plain_note(_notes_services(), note_id, line, before, runner)


def _note_choices_path() -> Path:
    return notes_pack._note_choices_path(_notes_services())



def _note_choices() -> dict[str, Any]:
    return notes_pack._note_choices(_notes_services())



def _save_note_choice(choice: dict[str, Any]) -> None:
    return notes_pack._save_note_choice(_notes_services(), choice)



def _apply_note_choice(args: dict[str, Any], runner: Any) -> str:
    return notes_pack._apply_note_choice(_notes_services(), args, runner)



def _append_note_rebuild(note_id, line, before, runner=subprocess.run):
    return notes_pack._append_note_rebuild(_notes_services(), note_id, line, before, runner)



_NOTE_MARKS_OPEN = ("☐", "[ ]")
_NOTE_MARKS_DONE = ("☑", "✅", "✔", "✓", "[x]", "[X]")
_NOTE_DUE_LABEL = "다음 마감"


def _note_link_state(plaintext: str) -> dict[str, Any]:
    return notes_pack._note_link_state(_notes_services(), plaintext)



def _note_parse_day(text: str) -> str | None:
    return notes_pack._note_parse_day(_notes_services(), text)



def _note_apply_edits(body_html: str, edits: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    return notes_pack._note_apply_edits(_notes_services(), body_html, edits)



def _edit_linked_note(note_id, before, lines, edits, runner=subprocess.run):
    return notes_pack._edit_linked_note(_notes_services(), note_id, before, lines, edits, runner)



_LINKED_TITLE_AUTHORITY = object()


def _linked_note_sections(body_html):
    return notes_pack._linked_note_sections(_notes_services(), body_html)



def _rename_linked_note(note_id, title, before, runner=subprocess.run):
    return notes_pack._rename_linked_note(_notes_services(), note_id, title, before, runner)



def _set_linked_note_progress(note_id, progress, runner=subprocess.run):
    return notes_pack._set_linked_note_progress(_notes_services(), note_id, progress, runner)



def _notes_reuse_source(action, args):
    return notes_pack._notes_reuse_source(_notes_services(), action, args)



_NOTE_RENAME_SUMMARY_REQUIRED = (
    "APPLE_NOTES_RENAME_SUMMARY_REQUIRED: include_body=true로 현재 메모를 먼저 읽고 "
    "기존 preview_summary와 summary의 모든 줄을 그대로 넘겨야 한다. original_text는 생략한다."
)


def _apple_notes_restore(args: dict[str, Any], runner: Any) -> str:
    return notes_pack._apple_notes_restore(_notes_services(), args, runner)



def _apple_notes_direct_mutation(args: dict[str, Any], **context: Any) -> str:
    # Only strict company linked-work adapters may reuse this preservation path in background.
    return notes_pack._apple_notes_direct_mutation(_notes_services(), args, **context)



def _mail_services():
    return mail_pack.Services(
        GMAIL_LABEL_FILTER_ACTIONS=GMAIL_LABEL_FILTER_ACTIONS,
        GMAIL_LABEL_FILTER_WRITES=GMAIL_LABEL_FILTER_WRITES,
        GMAIL_WRITE_FIELDS=GMAIL_WRITE_FIELDS,
        MAIL_BODY=MAIL_BODY,
        MAIL_FILE_BYTES=MAIL_FILE_BYTES,
        MAIL_FILE_LIMIT=MAIL_FILE_LIMIT,
        MAIL_SEND_BYTES=MAIL_SEND_BYTES,
        MAIL_THREAD_BODY=MAIL_THREAD_BODY,
        MAIL_THREAD_MESSAGES=MAIL_THREAD_MESSAGES,
        _GMAIL_NOT_SENT=_GMAIL_NOT_SENT,
        _PLUGIN_CONTEXT=_PLUGIN_CONTEXT,
        _attachment_root=_attachment_root,
        _clear_pending_personal_owner=_clear_pending_personal_owner,
        _company_mail_cron_read=_company_mail_cron_read,
        _error=_error,
        _gmail_account=_gmail_account,
        _gmail_direct=_gmail_direct,
        _gmail_extra=_gmail_extra,
        _gmail_local_execute=_gmail_local_execute,
        _gmail_lookup_body=_gmail_lookup_body,
        _gmail_outage_test=_gmail_outage_test,
        _gmail_python=_gmail_python,
        _gmail_root=_gmail_root,
        _gmail_scope_preflight=_gmail_scope_preflight,
        _gmail_success_receipt=_gmail_success_receipt,
        _inside=_inside,
        _lead_folders=_lead_folders,
        _lookup_bodies=_lookup_bodies,
        _mail_account_read=_mail_account_read,
        _mail_app_accounts=_mail_app_accounts,
        _mail_app_execute=_mail_app_execute,
        _mail_download=_mail_download,
        _mail_download_name=_mail_download_name,
        _mail_send_files=_mail_send_files,
        _mail_thread=_mail_thread,
        _personal_actor=_personal_actor,
        _personal_owner_error=_personal_owner_error,
        _personal_role_problem=_personal_role_problem,
        _unquoted=_unquoted,
        full_mail_tools=full_mail_tools,
        get_session_env=get_session_env,
        gmail_extra=gmail_extra,
        gmail_rules=gmail_rules,
        gmail_watch=gmail_watch,
        google_reauth=google_reauth,
        host=sys.modules[__name__],
        mail_app=mail_app,
        personal_roles=personal_roles,
        personal_scopes=personal_scopes,
        team=team,
    )


def _gmail_success_receipt(operation: str, entry: dict[str, Any], gmail_error: str = "") -> str:
    return mail_pack._gmail_success_receipt(_mail_services(), operation, entry, gmail_error)



def _gmail_account() -> str:
    return mail_pack._gmail_account(_mail_services())



def _gmail_python(hermes_home: Path) -> Path:
    # Managed Hermes moved its dependencies out of the old checkout venv. Resolve the same
    # selected dependency interpreter cron uses; do not pin an install generation.
    return mail_pack._gmail_python(_mail_services(), hermes_home)



def _gmail_local_execute(
    operation: str,
    values: dict[str, Any],
    *,
    runner: Any = None,
) -> str:
    return mail_pack._gmail_local_execute(_mail_services(), operation, values, runner=runner)



# Long enough for a whole business letter, so a foreign one can be translated in full.
MAIL_BODY = 15000
MAIL_THREAD_MESSAGES = 8
MAIL_THREAD_BODY = 2500


def _unquoted(body: str) -> str:
    return mail_pack._unquoted(_mail_services(), body)



def _mail_thread(message_id: str, runner: Any = None) -> str:
    return mail_pack._mail_thread(_mail_services(), message_id, runner)



MAIL_FILE_LIMIT = 10
MAIL_FILE_BYTES = 25 * 1024 * 1024
MAIL_SEND_BYTES = 20 * 1024 * 1024


def _gmail_root() -> Path:
    return mail_pack._gmail_root(_mail_services())



def _gmail_outage_test() -> bool:
    return mail_pack._gmail_outage_test(_mail_services())



def _gmail_extra(request: dict[str, Any], runner: Any = None) -> tuple[Any, str]:
    return mail_pack._gmail_extra(_mail_services(), request, runner)



def _mail_send_files(raw: Any) -> tuple[list[Path], str]:
    return mail_pack._mail_send_files(_mail_services(), raw)



def _mail_download_name(name: str, taken: set[str]) -> str:
    return mail_pack._mail_download_name(_mail_services(), name, taken)



def _mail_download(message_id: str, runner: Any = None, mail_runner: Any = None, *, account: str = "") -> str:
    return mail_pack._mail_download(_mail_services(), message_id, runner, mail_runner, account=account)



# Gmail failures after which the message is known not to have left; a timeout or an unreadable
# answer may hide a sent message, so those never trigger a second send.
_GMAIL_NOT_SENT = ("GMAIL_NOT_CONNECTED", "GMAIL_LOCAL_API_FAILED:", "GMAIL_LOCAL_API_UNAVAILABLE")


def _mail_app_execute(operation: str, values: dict[str, Any], gmail_error: str, runner: Any = None) -> str | None:
    return mail_pack._mail_app_execute(_mail_services(), operation, values, gmail_error, runner)



def _mail_app_accounts(runner):
    return mail_pack._mail_app_accounts(_mail_services(), runner)



def _company_mail_cron_read(action, account):
    return mail_pack._company_mail_cron_read(_mail_services(), action, account)



def _lookup_bodies(rows, read):
    return mail_pack._lookup_bodies(_mail_services(), rows, read)



def _gmail_lookup_body(mid, runner, mail_runner):
    # Reuse the bounded read + nested MIME/attachment extraction, including scope guards.
    return mail_pack._gmail_lookup_body(_mail_services(), mid, runner, mail_runner)



def _mail_account_read(args, account, runner):
    return mail_pack._mail_account_read(_mail_services(), args, account, runner)



def _gmail_scope_preflight(args, runner=None):
    return mail_pack._gmail_scope_preflight(_mail_services(), args, runner)



def _google_reauth(args, **_):
    return mail_pack._google_reauth(_mail_services(), args, **_)



def _gmail_direct(args: dict[str, Any], runner: Any = None, mail_runner: Any = None, **_: Any) -> str:
    return mail_pack._gmail_direct(_mail_services(), args, runner, mail_runner, **_)



CALENDAR_DIRECT_LOOKUP_SCHEMA = contracts.build_CALENDAR_DIRECT_LOOKUP_SCHEMA()


CALENDAR_DIRECT_MUTATION_SCHEMA = contracts.build_CALENDAR_DIRECT_MUTATION_SCHEMA()


GOOGLE_CALENDAR_COLOR_SET_SCHEMA = contracts.build_GOOGLE_CALENDAR_COLOR_SET_SCHEMA()


GOOGLE_CALENDAR_COLOR_NAMES = contracts.build_GOOGLE_CALENDAR_COLOR_NAMES()
GOOGLE_CALENDAR_COLOR_GET_SCHEMA = contracts.build_GOOGLE_CALENDAR_COLOR_GET_SCHEMA(GOOGLE_CALENDAR_COLOR_SET_SCHEMA)


def _calendar_services():
    return calendar_pack.Services(
        GOOGLE_CALENDAR_COLOR_NAMES=GOOGLE_CALENDAR_COLOR_NAMES,
        GOOGLE_CALENDAR_EVENTS_SCOPE=GOOGLE_CALENDAR_EVENTS_SCOPE,
        PERSONAL_PROFILE=PERSONAL_PROFILE,
        Path=Path,
        RECEIPT_VERSION=RECEIPT_VERSION,
        _attach_common_work_links=_attach_common_work_links,
        _calendar_alarm_error=_calendar_alarm_error,
        _calendar_cache_root=_calendar_cache_root,
        _calendar_direct_lookup=_calendar_direct_lookup,
        _calendar_event_get=_calendar_event_get,
        _calendar_event_lookup=_calendar_event_lookup,
        _calendar_identity_error=_calendar_identity_error,
        _clear_pending_personal_owner=_clear_pending_personal_owner,
        _error=_error,
        _google_calendar_color_failure=_google_calendar_color_failure,
        _google_calendar_color_service=_google_calendar_color_service,
        _google_calendar_color_target=_google_calendar_color_target,
        _google_calendar_color_token_path=_google_calendar_color_token_path,
        _google_calendar_http_error_code=_google_calendar_http_error_code,
        _google_event_matches_eventkit=_google_event_matches_eventkit,
        _native_mutation_result=_native_mutation_result,
        _normalize_calendar_dates=_normalize_calendar_dates,
        _personal_actor=_personal_actor,
        _personal_owner_error=_personal_owner_error,
        _resolve_calendar_date=_resolve_calendar_date,
        date_type=date_type,
        datetime_type=datetime_type,
        vault=vault,
    )


def _calendar_cache_root(owner_profile: str | None = None) -> Path:
    return calendar_pack._calendar_cache_root(_calendar_services(), owner_profile)



def _resolve_calendar_date(value: Any, timezone: str, *, now: datetime_type | None = None) -> str | None:
    return calendar_pack._resolve_calendar_date(_calendar_services(), value, timezone, now=now)



def _calendar_direct_lookup(args: dict[str, Any], **context: Any) -> str:
    return calendar_pack._calendar_direct_lookup(_calendar_services(), args, **context)



def _normalize_calendar_dates(payload: dict[str, Any], action: str) -> str | None:
    return calendar_pack._normalize_calendar_dates(_calendar_services(), payload, action)



def _calendar_alarm_error(args: dict[str, Any], action: str) -> str | None:
    return calendar_pack._calendar_alarm_error(_calendar_services(), args, action)



def _calendar_identity_error(args: dict[str, Any], action: str) -> str | None:
    return calendar_pack._calendar_identity_error(_calendar_services(), args, action)



def _calendar_event_lookup(event_id: str, runner: Any = subprocess.run) -> dict[str, Any]:
    return calendar_pack._calendar_event_lookup(_calendar_services(), event_id, runner)



def _calendar_event_get(event_id: str, runner: Any = subprocess.run) -> dict[str, Any] | None:
    return calendar_pack._calendar_event_get(_calendar_services(), event_id, runner)



def _calendar_event_move(event: dict[str, Any], start: str, end: str, runner: Any = subprocess.run) -> dict[str, Any] | None:
    return calendar_pack._calendar_event_move(_calendar_services(), event, start, end, runner)



def _calendar_event_rename(event, title, runner=subprocess.run):
    return calendar_pack._calendar_event_rename(_calendar_services(), event, title, runner)



def _calendar_event_set_notes(event, notes, runner=subprocess.run):
    return calendar_pack._calendar_event_set_notes(_calendar_services(), event, notes, runner)



def _calendar_event_add_alarm(event, minutes, runner=subprocess.run):
    return calendar_pack._calendar_event_add_alarm(_calendar_services(), event, minutes, runner)



def _calendar_direct_mutation(args: dict[str, Any], **context: Any) -> str:
    return calendar_pack._calendar_direct_mutation(_calendar_services(), args, **context)



_CONTACTS_PHONE = {"type": "array", "maxItems": 30, "items": {
    "type": "object", "properties": {
        "label": {"type": "string", "enum": ["mobile", "work", "work_fax", "main", "other"]},
        "value": {"type": "string", "minLength": 1}}, "required": ["label", "value"], "additionalProperties": False}}
_CONTACTS_EMAIL = {"type": "array", "maxItems": 30, "items": {
    "type": "object", "properties": {
        "label": {"type": "string", "enum": ["work", "home", "other"]},
        "value": {"type": "string", "minLength": 1}}, "required": ["label", "value"], "additionalProperties": False}}
CONTACTS_DIRECT_LOOKUP_SCHEMA = contracts.build_CONTACTS_DIRECT_LOOKUP_SCHEMA()
CONTACTS_DIRECT_MUTATION_SCHEMA = contracts.build_CONTACTS_DIRECT_MUTATION_SCHEMA(_CONTACTS_EMAIL, _CONTACTS_PHONE)


def _contacts_image_root() -> Path:
    return native_pack._contacts_image_root(_native_services())



def _contacts_arguments(args: dict[str, Any], *, mutation: bool) -> tuple[dict[str, Any], str | None]:
    return native_pack._contacts_arguments(_native_services(), args, mutation=mutation)



def _contacts_note_detail(value: Any) -> str:
    return native_pack._contacts_note_detail(_native_services(), value)



def _contacts_app_ready(runner: Any) -> tuple[bool, str]:
    return native_pack._contacts_app_ready(_native_services(), runner)



def _contacts_note(contact_id: str, *, note: str | None = None, runner: Any = None) -> dict[str, Any]:
    return native_pack._contacts_note(_native_services(), contact_id, note=note, runner=runner)



def _contacts_note_set(contact_id: str, note: str, *, runner: Any = None) -> dict[str, Any]:
    return native_pack._contacts_note_set(_native_services(), contact_id, note, runner=runner)



def _contacts_note_get(contact_id: str, *, runner: Any = None) -> dict[str, Any]:
    return native_pack._contacts_note_get(_native_services(), contact_id, runner=runner)



def _contacts_note_snapshot(result: dict[str, Any], note_result: dict[str, Any], *, mutation: bool) -> None:
    return native_pack._contacts_note_snapshot(_native_services(), result, note_result, mutation=mutation)



_CONTACTS_CHAIN_FIELDS = {'depth': int, 'domain': str, 'code': int,
                          'user_info_keys': list, 'validation_key': str, 'affected_types': list,
                          'exception_name': str}
_CONTACTS_STAGES = {'arguments', 'authorize', 'fetch', 'validate', 'backup_check', 'apply', 'save', 'save_verify',
                    'readback', 'serialize', 'done'}


def _contacts_native_diagnostics(result: dict[str, Any]) -> None:
    return native_pack._contacts_native_diagnostics(_native_services(), result)



def _contacts_backup(payload: dict[str, Any], native: Any, runner: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    return native_pack._contacts_backup(_native_services(), payload, native, runner)



def _contacts_direct(args: dict[str, Any], *, mutation: bool, **context: Any) -> str:
    return native_pack._contacts_direct(_native_services(), args, mutation=mutation, **context)



def _contacts_direct_lookup(args: dict[str, Any], **context: Any) -> str:
    return native_pack._contacts_direct_lookup(_native_services(), args, **context)



def _contacts_direct_mutation(args: dict[str, Any], **context: Any) -> str:
    return native_pack._contacts_direct_mutation(_native_services(), args, **context)



GOOGLE_CALENDAR_EVENTS_SCOPE = "https://www.googleapis.com/auth/calendar.events"


def _google_calendar_color_token_path() -> Path:
    return calendar_pack._google_calendar_color_token_path(_calendar_services())



def _google_calendar_color_service() -> Any:
    return calendar_pack._google_calendar_color_service(_calendar_services())



def _google_calendar_http_error_code(exc: Exception) -> str:
    return calendar_pack._google_calendar_http_error_code(_calendar_services(), exc)



def _google_event_matches_eventkit(item: dict[str, Any], target: dict[str, Any]) -> bool:
    return calendar_pack._google_event_matches_eventkit(_calendar_services(), item, target)



def _google_calendar_color_failure(exc: Exception, mutation_calls: int = 0) -> str:
    return calendar_pack._google_calendar_color_failure(_calendar_services(), exc, mutation_calls)



def _google_calendar_color_target(args: dict[str, Any], context: dict[str, Any]):
    return calendar_pack._google_calendar_color_target(_calendar_services(), args, context)



def _google_calendar_color_get(args: dict[str, Any], **context: Any) -> str:
    return calendar_pack._google_calendar_color_get(_calendar_services(), args, **context)



def _google_calendar_color_set(args: dict[str, Any], **context: Any) -> str:
    return calendar_pack._google_calendar_color_set(_calendar_services(), args, **context)



PERSONAL_WORK_BUNDLE_SCHEMA = contracts.build_PERSONAL_WORK_BUNDLE_SCHEMA()


def _bundle_digest(args: dict[str, Any]) -> str:
    return linked_pack._bundle_digest(_linked_services(), args)



def _normalize_personal_bundle_args(args: dict[str, Any]) -> dict[str, Any]:
    return linked_pack._normalize_personal_bundle_args(_linked_services(), args)



def _bundle_key(payload_digest: str) -> str:
    return linked_pack._bundle_key(_linked_services(), payload_digest)



# Names the model has actually used for native fields (from past bundles); mapped instead of dropped.
_BUNDLE_ARGUMENT_ALIASES: dict[str, dict[str, str]] = {
    "notes": {
        "id": "note_id", "source_id": "note_id", "stableNoteIdentifier": "note_id",
        "destination_folder": "folder", "target_folder": "folder",
    },
    "calendar": {"id": "event_id", "source_id": "event_id", "calendarItemIdentifier": "event_id"},
}
# Harmless extras the native tools never used; dropping them keeps long-working requests valid.
_BUNDLE_IGNORED_ARGUMENTS = {"calendar": {"timezone"}, "notes": set()}


def _apply_bundle_argument_aliases(domain: str, payload: dict[str, Any]) -> None:
    return linked_pack._apply_bundle_argument_aliases(_linked_services(), domain, payload)



def _bundle_argument_names(domain: str) -> set[str]:
    return linked_pack._bundle_argument_names(_linked_services(), domain)



def _validate_bundle(args: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, str]], str | None]:
    return linked_pack._validate_bundle(_linked_services(), args)



def _bundle_requires_approval(
    operations: list[dict[str, Any]], existing_sources: list[dict[str, str]],
) -> bool:
    return linked_pack._bundle_requires_approval(_linked_services(), operations, existing_sources)



def _bundle_plan_lines(operations: list[dict[str, Any]]) -> str:
    return linked_pack._bundle_plan_lines(_linked_services(), operations)



def _bundle_native_source(
    domain: str, action: str, arguments: dict[str, Any], result: dict[str, Any]
) -> dict[str, str] | None:
    return linked_pack._bundle_native_source(_linked_services(), domain, action, arguments, result)



PERSONAL_WORK_ROLLBACK_SCHEMA = contracts.build_PERSONAL_WORK_ROLLBACK_SCHEMA()


def _personal_rollback_path() -> Path:
    return linked_pack._personal_rollback_path(_linked_services())



def _read_personal_rollback_journal() -> dict[str, Any]:
    return linked_pack._read_personal_rollback_journal(_linked_services())



def _write_personal_rollback_journal(payload: dict[str, Any]) -> None:
    return linked_pack._write_personal_rollback_journal(_linked_services(), payload)



# Rollback undoes the conversation's changes newest-first, one per request, within this window.
PERSONAL_ROLLBACK_WINDOW_SECONDS = linked_pack.PERSONAL_ROLLBACK_WINDOW_SECONDS
_PERSONAL_ROLLBACK_RETENTION_SECONDS = 86400


def _personal_rollback_conversation() -> dict[str, str]:
    return linked_pack._personal_rollback_conversation(_linked_services())



def _append_personal_rollback_entry(entry: dict[str, Any]) -> None:
    return linked_pack._append_personal_rollback_entry(_linked_services(), entry)



def _save_personal_rollback(title: str, bundle_key: str, operations: list[dict[str, Any]]) -> None:
    return linked_pack._save_personal_rollback(_linked_services(), title, bundle_key, operations)



def _clear_personal_rollback(title: str = "") -> None:
    return linked_pack._clear_personal_rollback(_linked_services(), title)



def _latest_personal_rollback_entry(
    journal: dict[str, Any], *, window: float = PERSONAL_ROLLBACK_WINDOW_SECONDS,
) -> dict[str, Any] | None:
    return linked_pack._latest_personal_rollback_entry(_linked_services(), journal, window=window)



def _inverse_bundle_operation(
    operation: dict[str, Any], receipt: dict[str, Any],
) -> dict[str, Any] | None:
    return linked_pack._inverse_bundle_operation(_linked_services(), operation, receipt)



def _select_personal_rollback(
    journal: dict[str, Any], args: dict[str, Any],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    return linked_pack._select_personal_rollback(_linked_services(), journal, args)



def _personal_work_rollback(args: dict[str, Any], **context: Any) -> str:
    return linked_pack._personal_work_rollback(_linked_services(), args, **context)



def _link_bundle_sources(
    store: CommonWorkStore,
    *,
    title: str,
    requested_common_id: str,
    sources: list[dict[str, str]],
) -> dict[str, Any] | None:
    return linked_pack._link_bundle_sources(_linked_services(), store, title=title, requested_common_id=requested_common_id, sources=sources)



def _task_capture_owner_chat():
    return linked_pack._task_capture_owner_chat(_linked_services())



def _bundle_completes(args: dict[str, Any]) -> bool:
    return linked_pack._bundle_completes(_linked_services(), args)



def _bundle_completion(args: dict[str, Any]) -> str | None:
    return linked_pack._bundle_completion(_linked_services(), args)



def _personal_work_bundle(args: dict[str, Any], **context: Any) -> str:
    return linked_pack._personal_work_bundle(_linked_services(), args, **context)



COMMON_WORK_SOURCE_SCHEMA = contracts.build_COMMON_WORK_SOURCE_SCHEMA()

COMMON_WORK_CREATE_SCHEMA = contracts.build_COMMON_WORK_CREATE_SCHEMA(COMMON_WORK_SOURCE_SCHEMA)

COMMON_WORK_GET_SCHEMA = contracts.build_COMMON_WORK_GET_SCHEMA()

COMMON_WORK_LINK_SCHEMA = contracts.build_COMMON_WORK_LINK_SCHEMA(COMMON_WORK_SOURCE_SCHEMA)

# 2026-10-26 사용자 결정: 대화 완료도 업무 완료 신호다. 연결 원본 표시는 10분 감시(work_completion)가 맡는다.
COMMON_WORK_COMPLETE_DESCRIPTION = contracts.build_COMMON_WORK_COMPLETE_DESCRIPTION()

COMMON_WORK_COMPLETE_SCHEMA = contracts.build_COMMON_WORK_COMPLETE_SCHEMA()

KNOWLEDGE_REF_TYPES = contracts.build_KNOWLEDGE_REF_TYPES()

KNOWLEDGE_RELATION_TYPES = contracts.build_KNOWLEDGE_RELATION_TYPES()

KNOWLEDGE_REF_LINK_SCHEMA = contracts.build_KNOWLEDGE_REF_LINK_SCHEMA(KNOWLEDGE_REF_TYPES, KNOWLEDGE_RELATION_TYPES)

KNOWLEDGE_REF_GET_SCHEMA = contracts.build_KNOWLEDGE_REF_GET_SCHEMA()

KNOWLEDGE_REF_UNLINK_SCHEMA = contracts.build_KNOWLEDGE_REF_UNLINK_SCHEMA()


def _common_work_error(message: str) -> str:
    return linked_pack._common_work_error(_linked_services(), message)



def _common_work_profile() -> str:
    return linked_pack._common_work_profile(_linked_services())



def _require_common_work_access(*domains: str, completion: bool = False) -> str | None:
    return linked_pack._require_common_work_access(_linked_services(), *domains, completion=completion)



def _common_work_store() -> CommonWorkStore:
    return linked_pack._common_work_store(_linked_services())



_KNOWLEDGE_REF_MUTATION_TYPES = contracts.build__KNOWLEDGE_REF_MUTATION_TYPES()


def _require_knowledge_ref_access(
    ref_type: str | None = None, *, mutation: bool = False
) -> str | None:
    return linked_pack._require_knowledge_ref_access(_linked_services(), ref_type, mutation=mutation)



def _common_work_create(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._common_work_create(_linked_services(), args, **_)



def _common_work_get(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._common_work_get(_linked_services(), args, **_)



def _common_work_link(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._common_work_link(_linked_services(), args, **_)



def _company_notion_page(identifier):
    return linked_pack._company_notion_page(_linked_services(), identifier)



def _knowledge_ref_link(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._knowledge_ref_link(_linked_services(), args, **_)



def _knowledge_ref_get(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._knowledge_ref_get(_linked_services(), args, **_)



def _knowledge_ref_unlink(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._knowledge_ref_unlink(_linked_services(), args, **_)



def _common_work_complete(args: dict[str, Any], **_: Any) -> str:
    return linked_pack._common_work_complete(_linked_services(), args, **_)



# 소유자 위키 볼트는 사장 금고(obsidian.wiki_vault_path)에서 온다. 없으면 존재하지 않는 자리라 읽기가 실패한다.
WIKI_VAULT = Path(
    os.environ.get(
        _owner_text("HERMES_<<owner_label_upper>>1_VAULT"),
        str(vault.path("obsidian.wiki_vault_path") or team.root_home() / "owner" / "(wiki-vault-unset)"),
    )
)
_WIKI_OUTPUT_LIMIT = 12000
_WIKI_MARKER_RE = re.compile(
    r"(?:\b(?:E2E|재검증)-[\w-]+|\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\b)",
    re.IGNORECASE,
)

WIKI_DIRECT_SCHEMA = contracts.build_WIKI_DIRECT_SCHEMA()


def _wiki_clip(text: str) -> tuple[str, bool]:
    return native_pack._wiki_clip(_native_services(), text)



def _wiki_note_paths(vault: Path) -> list[tuple[str, ...]]:
    return native_pack._wiki_note_paths(_native_services(), vault)



def _wiki_link(relative: str, notes: list[tuple[str, ...]] | None = None) -> str:
    return native_pack._wiki_link(_native_services(), relative, notes)



def _wiki_resolve(vault: Path, raw: str) -> Path | None:
    return native_pack._wiki_resolve(_native_services(), vault, raw)



def _wiki_direct(args: dict[str, Any], **_: Any) -> str:
    return native_pack._wiki_direct(_native_services(), args, **_)



def register(ctx) -> None:
    from hermes_facility.pack_selection import scoped_context
    ctx = scoped_context(ctx)
    global _PLUGIN_CONTEXT
    _PLUGIN_CONTEXT = ctx
    manifest = getattr(ctx, "manifest", None)

    def declared_capability(name: str) -> set[str] | None:
        values = getattr(manifest, name, None)
        return set(values) if values is not None else None

    declared_tools = declared_capability("provides_tools")
    declared_hooks = declared_capability("provides_hooks")
    declared_middleware = declared_capability("provides_middleware")

    if team.has_role(str(getattr(ctx, "profile_name", "") or "").strip(), 'doctor'):
        ctx.register_system_prompt_section(
            f"team-delegation.{team.first_with('doctor')}-final-voice",
            DOCTOR_FINAL_VOICE_CONTRACT,
            position="after_memory",
            max_chars=1000,
        )

    def register_tool(**kwargs: Any) -> Any:
        if kwargs.get('name') == 'gmail_direct':
            kwargs['schema'] = full_mail_tools.profile_schema(sys.modules[__name__], kwargs['schema'],
                                                            str(getattr(ctx, 'profile_name', '') or ''))
        if declared_tools is not None and kwargs.get("name") not in declared_tools:
            return None
        if kwargs.get('name') in request_approvals.WRITES:
            from copy import deepcopy
            kwargs['schema'] = deepcopy(kwargs['schema'])
            kwargs['schema']['parameters'].setdefault('properties', {})['request_plan'] = request_approvals.PLAN_SCHEMA
        if personal_roles.enabled(sys.modules[__name__]):
            profile_name = str(getattr(ctx, 'profile_name', '') or '')
            name = kwargs.get('name')
            allowed = personal_roles.READS | ((personal_scopes.SCOPED_TOOLS | personal_roles.SECRETARY_FILES | personal_roles.SECRETARY_BROWSER) - {'notion'}
                if personal_scopes.config(sys.modules[__name__]) is not None else frozenset())
            if personal_scopes.config(sys.modules[__name__]) is not None:allowed -= {'notion'}
            if team.has_role(profile_name, 'personal') and media_save.config(sys.modules[__name__]).get('enabled') is True:
                allowed |= {'media_save'}
            if team.has_role(profile_name, 'personal') and name not in allowed:
                return None
            if team.has_role(profile_name, 'work') and name not in (
                    personal_roles.PERSONAL_READS | personal_roles.PERSONAL_WRITES | personal_roles.WORK_TOOLS):
                return None
            if team.has_role(profile_name, 'work') and name == 'messages_direct_lookup':
                return None
            original = kwargs['handler']
            def guarded(args, _name=name, _handler=original, **context):
                if problem := _personal_role_problem(_name, args):
                    return _error(problem)
                return _handler(args, **context)
            kwargs['handler'] = guarded
            if team.has_role(profile_name, 'personal') and name == 'gmail_direct':
                request = personal_roles.readonly_request(sys.modules[__name__], {'tools': [kwargs['schema']]})
                kwargs['schema'] = request['request']['tools'][0]
        return ctx.register_tool(**kwargs)

    def register_hook(name: str, handler: Any) -> Any:
        if declared_hooks is not None and name not in declared_hooks:
            return None
        return ctx.register_hook(name, handler)

    def register_middleware(name: str, handler: Any) -> Any:
        if declared_middleware is not None and name not in declared_middleware:
            return None
        return ctx.register_middleware(name, handler)

    from hermes_packs.diagnosis import diagnosis
    diagnosis.register(register_tool)
    if (team.has_role(str(getattr(ctx, 'profile_name', '') or ''), 'personal')
            and ctx.get_config('personal_report', {}).get('enabled') is True):
        try:
            from . import personal_report
        except ImportError:
            import personal_report
        register_tool(name='personal_report', toolset='team-delegation', schema=personal_report.SCHEMA,
                      handler=lambda args, **kw: personal_report.handle(sys.modules[__name__], args))

    if (team.has_role(str(getattr(ctx, 'profile_name', '') or ''), 'personal')
            and media_save.config(sys.modules[__name__]).get('enabled') is True):
        register_tool(name='media_save', toolset='team-delegation', schema=media_save.SCHEMA,
                      handler=lambda args, **kw: media_save.handle(sys.modules[__name__], args), emoji='💾')

    register_tool(
        name="request_usage_lookup",
        toolset="team-delegation",
        schema=REQUEST_USAGE_LOOKUP_SCHEMA,
        handler=_request_usage_lookup,
        description="Read one prior request-local numeric usage record in the current Slack thread.",
        emoji="📊",
    )
    register_tool(
        name="calendar_direct_lookup",
        toolset="team-delegation",
        schema=CALENDAR_DIRECT_LOOKUP_SCHEMA,
        handler=_calendar_direct_lookup,
        description="Read-only EventKit calendar lookup for the configured personal-work roles.",
        emoji="📅",
    )
    register_tool(
        name="calendar_direct_mutation",
        toolset="team-delegation",
        schema=CALENDAR_DIRECT_MUTATION_SCHEMA,
        handler=_calendar_direct_mutation,
        description="Execute EventKit calendar mutations for the configured personal executor.",
        emoji="📅",
    )
    register_tool(
        name="google_calendar_color_get", toolset="team-delegation",
        schema=GOOGLE_CALENDAR_COLOR_GET_SCHEMA, handler=_google_calendar_color_get,
        description="Read one exact Google Calendar event color without changes.", emoji="🎨",
    )
    register_tool(
        name="google_calendar_color_set",
        toolset="team-delegation",
        schema=GOOGLE_CALENDAR_COLOR_SET_SCHEMA,
        handler=_google_calendar_color_set,
        description="Set one Google Calendar event color immediately and report the result.",
        emoji="🎨",
    )
    if team.has_role(str(getattr(ctx, 'profile_name', '') or ''), 'work'):
        register_tool(name='contacts_direct_lookup', toolset='team-delegation',
                      schema=CONTACTS_DIRECT_LOOKUP_SCHEMA, handler=_contacts_direct_lookup, emoji='📇')
        register_tool(name='contacts_direct_mutation', toolset='team-delegation',
                      schema=CONTACTS_DIRECT_MUTATION_SCHEMA, handler=_contacts_direct_mutation, emoji='📇')
    register_tool(
        name="apple_notes_direct_lookup",
        toolset="team-delegation",
        schema=APPLE_NOTES_DIRECT_LOOKUP_SCHEMA,
        handler=_apple_notes_direct_lookup,
        description="Read Apple Notes directly through memo.",
        emoji="📝",
    )
    register_tool(
        name="apple_notes_direct_mutation",
        toolset="team-delegation",
        schema=APPLE_NOTES_DIRECT_MUTATION_SCHEMA,
        handler=_apple_notes_direct_mutation,
        description="Preview and execute approved Apple Notes mutations through Notes.app.",
        emoji="📝",
    )
    register_tool(
        name="gmail_direct",
        toolset="team-delegation",
        schema=GMAIL_DIRECT_SCHEMA,
        handler=_gmail_direct,
        description="Read mail, threads and attachments through local Gmail OAuth, with Mail app fallback; send approved mail with cc and attachments.",
        emoji="✉️",
    )
    register_tool(
        name="messages_direct_lookup",
        toolset="team-delegation",
        schema=MESSAGES_DIRECT_LOOKUP_SCHEMA,
        handler=_messages_direct_lookup,
        description="Read received text messages from the local Messages database; read-only.",
        emoji="💬",
    )
    register_tool(
        name="gateway_runtime_snapshot",
        toolset="team-delegation",
        schema=GATEWAY_RUNTIME_SNAPSHOT_SCHEMA,
        handler=_gateway_runtime_snapshot,
        description=_owner_text("One read-only launchd and Gateway PID snapshot for a <<doctor_english_name>> system_lookup task."),
        emoji="🔎",
    )
    register_tool(
        name="personal_work_bundle",
        toolset="team-delegation",
        schema=PERSONAL_WORK_BUNDLE_SCHEMA,
        handler=_personal_work_bundle,
        description=(
            "Execute one Calendar and Apple Notes work bundle with risk-based approval "
            "and one Common ID receipt."
        ),
        emoji="📦",
    )
    register_tool(
        name="personal_work_rollback",
        toolset="team-delegation",
        schema=PERSONAL_WORK_ROLLBACK_SCHEMA,
        handler=_personal_work_rollback,
        description="Undo the latest change within 30 minutes immediately; within 24 hours, preview and confirm before passing bundle_key.",
        emoji="↩️",
    )
    register_tool(
        name="common_work_create",
        toolset="team-delegation",
        schema=COMMON_WORK_CREATE_SCHEMA,
        handler=_common_work_create,
        description="Create one Common ID from verified Calendar or stable Notes source IDs.",
        emoji="🔗",
    )
    register_tool(
        name="common_work_get",
        toolset="team-delegation",
        schema=COMMON_WORK_GET_SCHEMA,
        handler=_common_work_get,
        description="Resolve one Common ID or one linked native source ID.",
        emoji="🔎",
    )
    register_tool(
        name="common_work_link",
        toolset="team-delegation",
        schema=COMMON_WORK_LINK_SCHEMA,
        handler=_common_work_link,
        description="Attach a verified Calendar or stable Notes source ID to an active Common ID.",
        emoji="➕",
    )
    register_tool(
        name="common_work_complete",
        toolset="team-delegation",
        schema=COMMON_WORK_COMPLETE_SCHEMA,
        handler=_common_work_complete,
        description=COMMON_WORK_COMPLETE_DESCRIPTION,
        emoji="✅",
    )
    register_tool(
        name="knowledge_ref_link",
        toolset="team-delegation",
        schema=KNOWLEDGE_REF_LINK_SCHEMA,
        handler=_knowledge_ref_link,
        description="Link verified Gmail, Wiki, memory, session, or receipt evidence to one Common ID.",
        emoji="🧠",
    )
    register_tool(
        name="knowledge_ref_get",
        toolset="team-delegation",
        schema=KNOWLEDGE_REF_GET_SCHEMA,
        handler=_knowledge_ref_get,
        description="Read knowledge references linked to one Common ID.",
        emoji="🔎",
    )
    register_tool(
        name="knowledge_ref_unlink",
        toolset="team-delegation",
        schema=KNOWLEDGE_REF_UNLINK_SCHEMA,
        handler=_knowledge_ref_unlink,
        description="After explicit approval, soft-unlink one knowledge reference without deleting its source.",
        emoji="➖",
    )
    # The default profile (위키담당) answers Wiki questions; other profiles never see the tool.
    if team.has_role(str(getattr(ctx, "profile_name", "") or "default").strip(), "wiki"):
        register_tool(
            name="wiki_direct",
            toolset="team-delegation",
            schema=WIKI_DIRECT_SCHEMA,
            handler=_wiki_direct,
            description=_owner_text("One-call read-only <<owner_label_title>>1 Wiki meta, knowledge, or inventory lookup for <<default_name>>."),
            emoji="📚",
        )
    if team.has_role(str(getattr(ctx, "profile_name", "") or "").strip(), 'personal'):
        register_tool(
            name="limit_report", toolset="team-delegation", schema=limit_report.SCHEMA,
            handler=_limit_report, description=_owner_text("<<doctor_name>> 새벽 처리 대기열에 못한 일 다섯 항목을 한 번 기록한다. Slack 보고는 보내지 않는다."),
            emoji="📩",
        )
        register_tool(
            name="paseo", toolset="team-delegation", schema=paseo_tools.SCHEMA,
            handler=_paseo, description="Operate local Paseo conversations as instructed by the user.",
            emoji="🛠️",
        )
        for name, engine in (("claude_code_artifact", "claude"),):
            register_tool(
                name=name, toolset="team-delegation", schema=artifact_tools.schema(name),
                handler=lambda args, _engine=engine, **kwargs: _artifact_generate(_engine, args, **kwargs),
                description="Generate one small standalone artifact; real development belongs in Paseo.",
                emoji="🧩",
            )
    # Only the lead profile works with files in its readable folders.
    if team.has_role(str(getattr(ctx, "profile_name", "") or "").strip(), 'personal'):
        register_tool(
            name="file_list",
            toolset="team-delegation",
            schema=FILE_LIST_SCHEMA,
            handler=_file_list,
            description="List one level of a readable folder.",
            emoji="📂",
        )
        register_tool(
            name="file_trash",
            toolset="team-delegation",
            schema=FILE_TRASH_SCHEMA,
            handler=_file_trash,
            description="Move one file or folder in the readable folders to the Trash after approval.",
            emoji="🗑️",
        )
    if team.has_role(str(getattr(ctx, 'profile_name', '') or '').strip(), 'work'):
        from hermes_packs.linked_work import linked_work_read
        register_tool(name='linked_work_read', toolset='team-delegation', schema=linked_work_read.SCHEMA,
                      handler=lambda args, **_: linked_work_read.handle(sys.modules[__name__], args),
                      description=linked_work_read.SCHEMA['description'], emoji='🔎')
        register_tool(name='google_reauth', toolset='team-delegation', schema=google_reauth.SCHEMA,
                      handler=_google_reauth, description=google_reauth.SCHEMA['description'], emoji='🔑')
        register_tool(name='mail_work', toolset='team-delegation', schema=mail_work.SCHEMA,
                      handler=_mail_work, description=mail_work.SCHEMA['description'], emoji='📬')
    register_middleware("llm_request", _tiered_personal_request)
    register_middleware("llm_execution", _llm_execution_guard)
    register_middleware("tool_execution", _tool_execution_guard)
    if team.has_role(str(getattr(ctx, 'profile_name', '') or ''), 'work'):
        from functools import partial
        from hermes_constants import get_hermes_home
        from hermes_packs.linked_work import link_decisions
        register_hook('pre_gateway_dispatch', partial(link_decisions.dispatch, Path(get_hermes_home())))
        from hermes_packs.linked_work import conflict_decisions
        register_hook('pre_gateway_dispatch', partial(conflict_decisions.dispatch, Path(get_hermes_home())))
        from hermes_packs.linked_work import work_tool_writes
        register_hook('post_tool_call', partial(work_tool_writes.observe, Path(get_hermes_home())))
    if team.has_role(str(getattr(ctx, 'profile_name', '') or ''), 'personal'):
        from functools import partial
        from hermes_constants import get_hermes_home
        register_hook('pre_gateway_dispatch', partial(video_job.dispatch, Path(get_hermes_home())))
    register_hook("pre_tool_call", _personal_mutation_approval)
    register_hook("post_approval_response", _lead_skill_approval_response)
    register_hook('post_approval_response', request_approvals.response)
    register_hook('post_llm_call', request_approvals.ended)
    # Through team-kit's single output hook: a second transform hook would skip team-kit's checks.
    from hermes_facility import output_steps
    output_steps.add('team-delegation.unverified_links', _mark_unverified_links)
    register_hook("kanban_task_claimed", _on_claim)


# Account-bound API is additive while company linked EventKit IDs stay in use.
# 개인·회사 Gmail 주소는 사장 금고에서 온다(없으면 enum 없이 문자열만 받고 계정 검사는 계정 범위 설정이 한다).
_CALENDAR_ACCOUNTS = tuple(a for a in (vault.text('accounts.personal.gmail'), vault.text('accounts.company.gmail')) if a)
for _schema in (CALENDAR_DIRECT_LOOKUP_SCHEMA, CALENDAR_DIRECT_MUTATION_SCHEMA,
                GOOGLE_CALENDAR_COLOR_GET_SCHEMA, GOOGLE_CALENDAR_COLOR_SET_SCHEMA):
    _schema['parameters']['properties']['account'] = ({'type':'string','enum':list(_CALENDAR_ACCOUNTS)} if _CALENDAR_ACCOUNTS else {'type':'string'})
if _CALENDAR_ACCOUNTS:CALENDAR_DIRECT_LOOKUP_SCHEMA['parameters']['properties']['account']['enum'].append('all')
CALENDAR_DIRECT_LOOKUP_SCHEMA['parameters']['properties']['backend'] = {'type':'string','enum':['eventkit','google']}
CALENDAR_DIRECT_LOOKUP_SCHEMA['description'] += ' Google API: backend=google, account=mailbox or all; personal default is Google. Company default EventKit is retained.'
CALENDAR_DIRECT_MUTATION_SCHEMA['description'] += ' Personal scope uses account-verified Google API with google: event IDs; company remains EventKit.'
for _schema in (GOOGLE_CALENDAR_COLOR_GET_SCHEMA, GOOGLE_CALENDAR_COLOR_SET_SCHEMA):
    _schema['parameters']['properties'].update({
        'target':{'type':'string','enum':['event','calendar'],'default':'event'},
        'event_id':{'type':'string','description':'Exact google: event ID from API lookup.'},
    })
    _schema['parameters']['required'] = []
    _schema['description'] += ' Uses the selected account credential. target=calendar reads or applies owner blue/company and yellow/personal, recording original RGB before patch. Event mode requires exact event_id or legacy date+eventkit_id.'


# Personal/company ownership is enforced at native handlers as well as request middleware.
try:
    from . import personal_scopes
except ImportError:
    import personal_scopes
personal_scopes.install(sys.modules[__name__])
personal_scopes.install_mail(sys.modules[__name__])
