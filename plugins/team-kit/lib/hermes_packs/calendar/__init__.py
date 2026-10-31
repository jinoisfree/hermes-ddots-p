"""Calendar execution with injected account, scope and approval services."""
from __future__ import annotations
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo
from dataclasses import dataclass

QUERY_SOURCE = Path(__file__).with_name("eventkit_calendar_query.swift")
MUTATION_SOURCE = Path(__file__).with_name("eventkit_calendar_mutation.swift")

@dataclass(frozen=True)
class Services:
    """One call's dependencies. No profile or gateway modules are imported here."""
    GOOGLE_CALENDAR_COLOR_NAMES: Any
    GOOGLE_CALENDAR_EVENTS_SCOPE: Any
    PERSONAL_PROFILE: Any
    Path: Any
    RECEIPT_VERSION: Any
    _attach_common_work_links: Any
    _calendar_alarm_error: Any
    _calendar_cache_root: Any
    _calendar_direct_lookup: Any
    _calendar_event_get: Any
    _calendar_event_lookup: Any
    _calendar_identity_error: Any
    _clear_pending_personal_owner: Any
    _error: Any
    _google_calendar_color_failure: Any
    _google_calendar_color_service: Any
    _google_calendar_color_target: Any
    _google_calendar_color_token_path: Any
    _google_calendar_http_error_code: Any
    _google_event_matches_eventkit: Any
    _native_mutation_result: Any
    _normalize_calendar_dates: Any
    _personal_actor: Any
    _personal_owner_error: Any
    _resolve_calendar_date: Any
    date_type: Any
    datetime_type: Any
    vault: Any


def _calendar_cache_root(services, owner_profile: str | None = None) -> Path:
    try:
        from hermes_constants import get_hermes_home
        root = services.Path(get_hermes_home())
    except Exception:
        root = services.Path.home() / ".hermes"
    if owner_profile:
        install_root = root.parent.parent if root.parent.name == "profiles" else root
        root = install_root / "profiles" / owner_profile
    cache = root / "cache" / "calendar-direct-lookup"
    cache.mkdir(parents=True, exist_ok=True)
    return cache

def _resolve_calendar_date(services, value: Any, timezone: str, *, now: datetime_type | None = None) -> str | None:
    raw = str(value or "today").strip().lower()
    try:
        zone = ZoneInfo(timezone)
    except (KeyError, ValueError):
        return None
    current = (now or services.datetime_type.now(zone)).astimezone(zone).date()
    if raw == "today":
        return current.isoformat()
    if raw == "tomorrow":
        return (current + timedelta(days=1)).isoformat()
    try:
        return services.date_type.fromisoformat(raw).isoformat()
    except ValueError:
        return None

def _calendar_direct_lookup(services, args: dict[str, Any], **context: Any) -> str:
    if problem := services._personal_owner_error('calendar_direct_lookup'):
        return problem
    timezone = str(args.get("timezone") or "Asia/Seoul").strip()
    if timezone != "Asia/Seoul":
        return services._error("timezone must be Asia/Seoul")
    requested_date = services._resolve_calendar_date(args.get("date"), timezone)
    if requested_date is None:
        return services._error("date must be today, tomorrow, or a valid YYYY-MM-DD value")

    try:
        cache_root = services._calendar_cache_root(services.PERSONAL_PROFILE)
        source = QUERY_SOURCE
        binary = cache_root / "eventkit_calendar_query-v2"
        runner = context.get("runner") or subprocess.run
        if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
            compiled = runner(
                ["/usr/bin/swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                capture_output=True, text=True, timeout=60,
            )
            if compiled.returncode != 0:
                return services._error("TE_CALENDAR_EXECUTOR_COMPILE_FAILED")

        started = time.monotonic()
        attempts = 0
        fingerprints: set[str] = set()
        raw: dict[str, Any] | None = None
        errors: list[str] = []
        while attempts < 2:
            attempts += 1
            proc = runner(
                [str(binary), requested_date, timezone], capture_output=True, text=True, timeout=30,
            )
            try:
                parsed = json.loads(proc.stdout) if proc.returncode == 0 else None
            except ValueError:
                parsed = None
            if isinstance(parsed, dict):
                raw = parsed
                break
            stderr = (proc.stderr or "").strip()
            reason = (
                "TE_CALENDAR_PARSER_ERROR" if proc.returncode == 0
                else "TE_CALENDAR_EVENTKIT_TRANSIENT" if proc.returncode == 70
                else "TE_CALENDAR_PERMISSION_DENIED" if proc.returncode == 77
                else "TE_CALENDAR_EXECUTOR_ERROR"
            )
            fingerprint = hashlib.sha256(f"{reason}\x1f{proc.returncode}\x1f{stderr}".encode()).hexdigest()[:16]
            errors.append(f"{reason}:{fingerprint}")
            if fingerprint in fingerprints or reason not in {"TE_CALENDAR_PARSER_ERROR", "TE_CALENDAR_EVENTKIT_TRANSIENT"}:
                break
            fingerprints.add(fingerprint)

    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"TE_CALENDAR_EXECUTOR_ERROR:{type(exc).__name__}")

    processing_seconds = round(max(0.0, time.monotonic() - started), 6)
    if raw is None:
        return json.dumps({
            "ok": False, "error": "calendar lookup failed", "reason_codes": errors,
            "retry_count": max(0, attempts - 1), "mutation_calls": 0,
        }, ensure_ascii=False)

    events = list(raw.get("events") or [])
    services._attach_common_work_links(
        events, domain="calendar", source_id_field="calendarItemIdentifier"
    )
    source_ids = ["EventKit/macOS Calendar", f"date:{requested_date}", f"timezone:{timezone}"]
    receipt = {
        "receipt_version": services.RECEIPT_VERSION,
        "executor_version": "2",
        "work_class": "direct_lookup",
        "work_type": "calendar_lookup",
        "owner_profile": services._personal_actor(),
        "idempotency_key": f"calendar-v1:{requested_date}:{timezone}",
        "source_ids": source_ids,
        "scope": f"date:{requested_date}",
        "query_scope": {
            "timezone": timezone,
            "start_inclusive": raw.get("rangeStartInclusive"),
            "end_exclusive": raw.get("rangeEndExclusive"),
            "selection_rule": raw.get("selectionRule"),
            "calendar_mode": "all EventKit event calendars",
        },
        "queried_at": raw.get("queriedAt"),
        "result_count": len(events),
        "results": events,
        "calendar_results": raw.get("calendars") or [],
        "conflict_count": int(raw.get("conflictCount") or 0),
        "mutation_calls": 0,
        "approval_calls": 0,
        "model_calls": "measurement_missing",
        "tool_calls": 1,
        "input_tokens": "measurement_missing",
        "output_tokens": "measurement_missing",
        "total_tokens": "measurement_missing",
        "processing_seconds": processing_seconds,
        "external_wait_seconds": 0,
        "retry_count": max(0, attempts - 1),
        "source_query_calls": 1,
        "cache_reused": False,
        "error_codes": errors + [
            "measurement_missing:model_calls", "measurement_missing:input_tokens",
            "measurement_missing:output_tokens", "measurement_missing:total_tokens",
        ],
        "quality_gates": {
            "source_read_succeeded": True,
            "read_only": True,
            "all_eventkit_calendars": True,
            "half_open_overlap_rule": raw.get("selectionRule") == "event.end > start && event.start < end",
            "chronological": True,
            "model_call_budget": 3,
        },
    }
    return json.dumps({"ok": True, "receipt": receipt}, ensure_ascii=False)

def _normalize_calendar_dates(services, payload: dict[str, Any], action: str) -> str | None:
    """Normalize atomically, so invalid bundle inputs remain available for validation."""
    if action not in {"create", "update"}:
        return None
    normalized = dict(payload)
    moments = {}
    date_only = r"\d{4}-\d{2}-\d{2}"
    pattern = date_only + r"(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?"
    guidance = "use YYYY-MM-DD (all-day), YYYY-MM-DD HH:MM (Asia/Seoul), or ISO-8601 with an offset"
    for field in ("start", "end"):
        if field not in payload:
            continue
        value = payload[field]
        try:
            if not isinstance(value, str) or not re.fullmatch(pattern, value.strip()):
                raise ValueError
            moment = services.datetime_type.fromisoformat(value.strip().replace("Z", "+00:00"))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=ZoneInfo("Asia/Seoul"))
            moments[field] = moment.replace(microsecond=0)
        except ValueError:
            return f"calendar {field} is not a valid date/time; {guidance}"
        if field == "start" and re.fullmatch(date_only, value.strip()):
            normalized.setdefault("all_day", True)
    if normalized.get("all_day") is True:
        if "start" in moments:
            moments["start"] = moments["start"].replace(hour=0, minute=0, second=0)
        if action == "create" and "end" not in moments and "start" in moments:
            moments["end"] = moments["start"]
        if "end" in moments:
            moments["end"] = moments["end"].replace(hour=23, minute=59, second=59)
    if action == "create":
        for field in ("start", "end"):
            if field not in moments:
                return f"calendar {field} is required; {guidance}"
    if "start" in moments and "end" in moments and moments["end"] <= moments["start"]:
        return f"calendar end must be later than start; {guidance}"
    normalized.update({field: moment.isoformat(timespec="seconds") for field, moment in moments.items()})
    payload.update(normalized)
    return None

def _calendar_alarm_error(services, args: dict[str, Any], action: str) -> str | None:
    if "alarms" not in args and "clear_alarms" not in args:
        return None
    if action not in {"create", "update"}:
        return "calendar alarms apply only to create/update"
    if "clear_alarms" in args and type(args["clear_alarms"]) is not bool:
        return "clear_alarms must be a boolean"
    if "alarms" in args:
        alarms = args["alarms"]
        if not isinstance(alarms, list) or len(alarms) > 5 or any(
            type(value) is not int or value < 0 or value > 5256000 for value in alarms
        ):
            return "alarms must be up to 5 integers from 0 to 5256000 minutes before start"
        if args.get("clear_alarms"):
            return "use alarms or clear_alarms, not both"
    return None

def _calendar_identity_error(services, args: dict[str, Any], action: str) -> str | None:
    if action == "create":
        return None
    if not isinstance(args.get("expected_title"), str) or not args.get("expected_start"):
        return "calendar update/delete requires expected_title and expected_start from lookup"
    try:
        value = services.datetime_type.fromisoformat(str(args["expected_start"]).replace("Z", "+00:00"))
        if value.tzinfo is None:
            raise ValueError()
    except ValueError:
        return "expected_start must be the original ISO8601 occurrence start with timezone"
    args["expected_start"] = value.isoformat()
    return None

def _calendar_event_lookup(services, event_id: str, runner: Any = subprocess.run) -> dict[str, Any]:
    """Typed read-only outcome; never interpret a denied/failed read as deletion."""
    try:
        from . import source_lookup
    except ImportError:
        from hermes_packs.linked_work import source_lookup
    if str(event_id).startswith('google:'):
        return source_lookup.result('out_of_scope', 'google_calendar_source')
    source = MUTATION_SOURCE
    binary = services._calendar_cache_root(services.PERSONAL_PROFILE) / "eventkit_calendar_mutation-v1"
    try:
        if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
            compiled = runner(["/usr/bin/swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                              capture_output=True, text=True, timeout=120, check=False)
            if compiled.returncode != 0:
                return source_lookup.result('transient', 'calendar_executor_compile_failed')
        proc = runner([str(binary), json.dumps({"action": "get", "event_id": event_id})],
                      capture_output=True, text=True, timeout=30, check=False)
        if proc.returncode:
            return source_lookup.calendar_failure(proc.returncode, proc.stderr or '')
        data = json.loads(proc.stdout)
    except subprocess.TimeoutExpired:
        return source_lookup.result('transient', 'calendar_read_timeout')
    except (OSError, ValueError):
        return source_lookup.result('transient', 'calendar_read_failed')
    if not isinstance(data, dict) or not isinstance(data.get("before"), dict):
        return source_lookup.result('transient', 'calendar_read_invalid')
    row = {**data["before"], "recurring": data.get("action") == "get_recurring"}
    return source_lookup.result('unsupported' if row['recurring'] else 'ok',
                                'recurring_calendar' if row['recurring'] else 'read_ok', row)

def _calendar_event_get(services, event_id: str, runner: Any = subprocess.run) -> dict[str, Any] | None:
    """Compatibility wrapper: preserve snapshots (including recurring) or None."""
    return services._calendar_event_lookup(event_id, runner)['row']

def _calendar_event_move(services, event: dict[str, Any], start: str, end: str, runner: Any = subprocess.run) -> dict[str, Any] | None:
    """Watcher-only: move one non-recurring event, matched by ID, title and current start."""
    if services._calendar_event_get(event["calendarItemIdentifier"], runner) is None:
        return None
    binary = services._calendar_cache_root(services.PERSONAL_PROFILE) / "eventkit_calendar_mutation-v1"
    payload = {"action": "update", "event_id": event["calendarItemIdentifier"], "expected_title": event["title"],
               "expected_start": event["start"], "start": start, "end": end, "span": "this"}
    try:
        proc = runner([str(binary), json.dumps(payload, ensure_ascii=False)],
                      capture_output=True, text=True, timeout=30, check=False)
        data = json.loads(proc.stdout) if proc.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    return data.get("after") if isinstance(data, dict) else None

def _calendar_event_rename(services, event, title, runner=subprocess.run):
    """Watcher-only title update, pinned to the original title/start and one event instance."""
    before = services._calendar_event_get(event['calendarItemIdentifier'], runner)
    if not before or before.get('title') != event['title'] or before.get('start') != event['start']:
        return None
    binary = services._calendar_cache_root(services.PERSONAL_PROFILE) / 'eventkit_calendar_mutation-v1'
    payload = {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_title': event['title'],
               'expected_start': event['start'], 'title': title, 'span': 'this'}
    proc = runner([str(binary), json.dumps(payload, ensure_ascii=False)], capture_output=True, text=True, timeout=30, check=False)
    data = json.loads(proc.stdout) if proc.returncode == 0 else {}
    after = data.get('after') or {}
    return after if after.get('title') == title and all(after.get(k) == before.get(k) for k in ('start', 'end', 'calendarIdentifier', 'notes')) else None

def _calendar_event_set_notes(services, event, notes, runner=subprocess.run):
    """Watcher-only (work_completion 진행도) notes update, pinned to title/start and one event instance."""
    before = services._calendar_event_get(event['calendarItemIdentifier'], runner)
    if not before or before.get('title') != event['title'] or before.get('start') != event['start'] or before.get('recurring'):
        return None
    binary = services._calendar_cache_root(services.PERSONAL_PROFILE) / 'eventkit_calendar_mutation-v1'
    payload = {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_title': event['title'],
               'expected_start': event['start'], 'notes': notes, 'span': 'this'}
    proc = runner([str(binary), json.dumps(payload, ensure_ascii=False)], capture_output=True, text=True, timeout=30, check=False)
    try:
        data = json.loads(proc.stdout) if proc.returncode == 0 else {}
    except ValueError:
        return None
    after = data.get('after') or {}
    return after if (after.get('notes') or '') == notes and all(after.get(k) == before.get(k) for k in ('title', 'start', 'end', 'calendarIdentifier')) else None

def _calendar_event_add_alarm(services, event, minutes, runner=subprocess.run):
    """Watcher-only (zoom_alarm_sync): add one relative alarm to one occurrence, keeping the others.

    span stays "this" so a recurring series is never split; absolute alarms are left untouched by refusing.
    """
    details = event.get('alarmDetails') or []
    if any(row.get('absoluteDate') for row in details):
        return None
    current = sorted({int(round(-float(row['relativeOffset']) / 60)) for row in details})
    if minutes in current or len(current) >= 5:
        return None
    binary = services._calendar_cache_root(services.PERSONAL_PROFILE) / 'eventkit_calendar_mutation-v1'
    source = MUTATION_SOURCE
    if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
        compiled = runner(['/usr/bin/swiftc', '-parse-as-library', str(source), '-o', str(binary)],
                          capture_output=True, text=True, timeout=120, check=False)
        if compiled.returncode != 0:
            return None
    payload = {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_title': event['title'],
               'expected_start': event['start'], 'alarms': current + [minutes], 'span': 'this'}
    try:
        proc = runner([str(binary), json.dumps(payload, ensure_ascii=False)], capture_output=True, text=True, timeout=30, check=False)
        data = json.loads(proc.stdout) if proc.returncode == 0 else {}
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    before, after = data.get('before') or {}, data.get('after') or {}
    kept = ('title', 'start', 'end', 'calendarIdentifier', 'location', 'notes', 'url')
    if not before or any(after.get(k) != before.get(k) for k in kept):
        return None
    return after if minutes in [int(round(v)) for v in after.get('alarms') or []] else None

def _calendar_direct_mutation(services, args: dict[str, Any], **context: Any) -> str:
    if error := services._personal_owner_error("calendar_direct_mutation"):
        return error
    action = str(args.get("action") or "").strip().lower()
    if action not in {"create", "update", "delete"}:
        return services._error("invalid calendar mutation action", mutation_calls=0)
    args = dict(args)
    if error := services._normalize_calendar_dates(args, action):
        return services._error(error, mutation_calls=0)
    if error := services._calendar_alarm_error(args, action):
        return services._error(error, mutation_calls=0)
    if "_restore_alarms" in args and not args.get("_rollback"):
        return services._error("alarm snapshots are reserved for rollback", mutation_calls=0)
    if error := services._calendar_identity_error(args, action):
        return services._error(error, mutation_calls=0)
    event_id = str(args.get("event_id") or "").strip()
    title = str(args.get("title") or "").strip()
    start = str(args.get("start") or "").strip()
    end = str(args.get("end") or "").strip()
    if action == "create" and not all((title, start, end)):
        return services._error("title, start, and end are required for calendar creation", mutation_calls=0)
    if action != "create" and not event_id:
        return services._error("event_id is required for this action", mutation_calls=0)
    span = str(args.get("span") or "this").strip().lower()
    if span not in {"this", "future"}:
        return services._error("span must be this or future", mutation_calls=0)

    source = MUTATION_SOURCE
    cache_root = services._calendar_cache_root(services.PERSONAL_PROFILE)
    binary = cache_root / "eventkit_calendar_mutation-v1"
    runner = context.get("runner") or subprocess.run
    write_started = False
    try:
        if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
            compiled = runner(
                ["/usr/bin/swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                capture_output=True, text=True, timeout=60, check=False,
            )
            if compiled.returncode != 0:
                return services._error("TE_CALENDAR_MUTATION_EXECUTOR_COMPILE_FAILED", mutation_calls=0)
        payload = dict(args)
        payload.pop("approved", None)
        payload.pop("common_id", None)
        payload.pop("_skip_common_work", None)
        write_started = True
        proc = runner(
            [str(binary), json.dumps(payload, ensure_ascii=False)],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"CALENDAR_NATIVE_UNAVAILABLE:{type(exc).__name__}",
                      **({} if write_started else {"mutation_calls": 0}))
    return services._native_mutation_result(
        "EventKit Calendar", action, event_id or None, proc,
        common_work_domain="" if args.get("_skip_common_work") else "calendar",
        common_work_title=title,
        common_id=str(args.get("common_id") or ""),
    )

def _google_calendar_color_token_path(services) -> Path:
    override = os.environ.get("HERMES_GOOGLE_CALENDAR_COLOR_TOKEN", "").strip()
    if override:
        return services.Path(override).expanduser()
    try:
        from hermes_constants import get_hermes_home
        root = services.Path(get_hermes_home())
    except Exception:
        root = services.Path.home() / ".hermes"
    install_root = root.parent.parent if root.parent.name == "profiles" else root
    return install_root / "profiles" / services.PERSONAL_PROFILE / "google_calendar_color_token.json"

def _google_calendar_color_service(services) -> Any:
    token_path = services._google_calendar_color_token_path()
    if not token_path.is_file():
        raise FileNotFoundError("GOOGLE_CALENDAR_COLOR_NOT_CONNECTED")
    token_payload = json.loads(token_path.read_text(encoding="utf-8"))
    token_scopes = set(token_payload.get("scopes") or [])
    if token_scopes != {services.GOOGLE_CALENDAR_EVENTS_SCOPE}:
        raise PermissionError("GOOGLE_CALENDAR_COLOR_SCOPE_MISMATCH")
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build

    credentials = Credentials.from_authorized_user_file(
        str(token_path), [services.GOOGLE_CALENDAR_EVENTS_SCOPE],
    )
    if credentials.expired and credentials.refresh_token:
        credentials.refresh(Request())
        token_path.write_text(credentials.to_json(), encoding="utf-8")
        token_path.chmod(0o600)
    if not credentials.valid:
        raise PermissionError("GOOGLE_CALENDAR_COLOR_TOKEN_INVALID")
    return build("calendar", "v3", credentials=credentials, cache_discovery=False)

def _google_calendar_http_error_code(services, exc: Exception) -> str:
    from google.auth.exceptions import RefreshError
    if isinstance(exc, RefreshError) or "invalid_grant" in str(exc):
        return "GOOGLE_CALENDAR_COLOR_REAUTH_REQUIRED"
    if isinstance(exc, (FileNotFoundError, PermissionError)) and str(exc).startswith("GOOGLE_CALENDAR_COLOR_"):
        return str(exc)
    status = int(getattr(getattr(exc, "resp", None), "status", 0) or 0)
    reason = ""
    try:
        payload = json.loads(bytes(getattr(exc, "content", b"")).decode("utf-8"))
        details = payload.get("error", {}).get("errors") or []
        reason = str((details[0] if details else {}).get("reason") or "")
    except (TypeError, ValueError, UnicodeDecodeError):
        pass
    if reason == "accessNotConfigured":
        return "CALENDAR_API_DISABLED"
    if reason in {"insufficientPermissions", "forbidden"} or status == 401:
        return "GOOGLE_CALENDAR_PERMISSION_DENIED"
    if status == 404 or reason == "notFound":
        return "GOOGLE_EVENT_NOT_FOUND"
    return f"GOOGLE_CALENDAR_HTTP_ERROR:{status or 'unknown'}:{reason or type(exc).__name__}"

def _google_event_matches_eventkit(services, item: dict[str, Any], target: dict[str, Any]) -> bool:
    if str(item.get("iCalUID") or "") != str(target.get("externalIdentifier") or ""):
        return False
    if str(item.get("summary") or "") != str(target.get("title") or ""):
        return False
    google_start = dict(item.get("start") or {})
    target_start = str(target.get("start") or "")
    if bool(target.get("isAllDay")):
        return str(google_start.get("date") or "") == target_start[:10]
    google_value = str(google_start.get("dateTime") or "")
    try:
        google_timestamp = services.datetime_type.fromisoformat(google_value.replace("Z", "+00:00")).timestamp()
        target_timestamp = services.datetime_type.fromisoformat(target_start.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return False
    return abs(google_timestamp - target_timestamp) < 1

def _google_calendar_color_failure(services, exc: Exception, mutation_calls: int = 0) -> str:
    code = str(exc) if isinstance(exc, ValueError) and str(exc).startswith(("EVENTKIT_", "GOOGLE_EVENT_", "calendar_id,")) else services._google_calendar_http_error_code(exc)
    fields = {"mutation_calls": mutation_calls}
    if mutation_calls:
        fields["reflection_unknown"] = True
    if code == "GOOGLE_CALENDAR_COLOR_REAUTH_REQUIRED":
        fields["message"] = "소유자가 ~/.hermes/bin/hermes-google-calendar-color-auth로 " + services.vault.text("accounts.personal.gmail") + " 재로그인 필요"
    return services._error(code, **fields)

def _google_calendar_color_target(services, args: dict[str, Any], context: dict[str, Any]):
    calendar_id = str(args.get("calendar_id") or "primary").strip()
    requested_date = str(args.get("date") or "").strip()
    eventkit_id = str(args.get("eventkit_id") or "").strip()
    if not calendar_id or not requested_date or not eventkit_id:
        raise ValueError("calendar_id, date, and eventkit_id are required")
    eventkit_lookup = context.get("eventkit_lookup") or services._calendar_direct_lookup
    try:
        lookup = json.loads(eventkit_lookup({"date": requested_date, "timezone": "Asia/Seoul"}))
    except Exception:
        raise ValueError("EVENTKIT_TARGET_LOOKUP_FAILED")
    eventkit_matches = [
        item for item in list((lookup.get("receipt") or {}).get("results") or [])
        if str(item.get("calendarItemIdentifier") or "") == eventkit_id
    ]
    if len(eventkit_matches) != 1:
        raise ValueError("EVENTKIT_TARGET_NOT_FOUND" if not eventkit_matches else "EVENTKIT_TARGET_AMBIGUOUS")
    target = eventkit_matches[0]
    i_cal_uid = str(target.get("externalIdentifier") or "").strip()
    if not i_cal_uid:
        raise ValueError("EVENTKIT_EXTERNAL_ID_MISSING")
    service = context.get("google_calendar_service")
    service = service or services._google_calendar_color_service()
    listed = service.events().list(
        calendarId=calendar_id,
        iCalUID=i_cal_uid,
        timeMin=str((lookup.get("receipt") or {}).get("query_scope", {}).get("start_inclusive") or ""),
        timeMax=str((lookup.get("receipt") or {}).get("query_scope", {}).get("end_exclusive") or ""),
        singleEvents=True,
        showDeleted=False,
        maxResults=10,
    ).execute()
    matches = [
        item for item in list(listed.get("items") or [])
        if services._google_event_matches_eventkit(item, target)
    ]
    if not matches:
        raise ValueError("GOOGLE_EVENT_NOT_SYNCED")
    if len(matches) != 1:
        raise ValueError("GOOGLE_EVENT_AMBIGUOUS")
    before = matches[0]
    google_event_id = str(before.get("id") or "").strip()
    if not google_event_id:
        raise ValueError("GOOGLE_EVENT_ID_MISSING")
    return service, calendar_id, eventkit_id, i_cal_uid, before, google_event_id

def _google_calendar_color_get(services, args: dict[str, Any], **context: Any) -> str:
    if error := services._personal_owner_error("google_calendar_color_get"):
        return error
    try:
        _, calendar_id, eventkit_id, _, before, google_event_id = services._google_calendar_color_target(args, context)
    except Exception as exc:
        return services._google_calendar_color_failure(exc)
    color_id = str(before.get("colorId") or "")
    return json.dumps({"ok": True, "authority": "Google Calendar API", "calendar_id": calendar_id,
                       "eventkit_id": eventkit_id, "google_event_id": google_event_id,
                       "summary": str(before.get("summary") or ""), "color_id": color_id,
                       "color_name": services.GOOGLE_CALENDAR_COLOR_NAMES.get(color_id, "알 수 없음"),
                       "mutation_calls": 0}, ensure_ascii=False)

def _google_calendar_color_set(services, args: dict[str, Any], **context: Any) -> str:
    if error := services._personal_owner_error("google_calendar_color_set"):
        return json.dumps({**json.loads(error), "mutation_calls": 0}, ensure_ascii=False)
    color_id = str(args.get("color_id") or "").strip()
    if not re.fullmatch(r"(?:[1-9]|1[01])", color_id):
        return services._error("color_id must be a Google Calendar event color ID from 1 through 11", mutation_calls=0)
    try:
        service, calendar_id, eventkit_id, i_cal_uid, before, google_event_id = services._google_calendar_color_target(args, context)
    except Exception as exc:
        return services._google_calendar_color_failure(exc)
    try:
        result = service.events().patch(
            calendarId=calendar_id, eventId=google_event_id,
            body={"colorId": color_id}, sendUpdates="none",
        ).execute()
        if str(result.get("id") or "") != google_event_id or str(result.get("colorId") or "") != color_id:
            return services._error("GOOGLE_CALENDAR_COLOR_VERIFICATION_FAILED", mutation_calls=1, reflection_unknown=True)
    except Exception as exc:
        return services._google_calendar_color_failure(exc, mutation_calls=1)
    services._clear_pending_personal_owner()
    return json.dumps({
        "ok": True,
        "authority": "Google Calendar API",
        "action": "set_color",
        "calendar_id": calendar_id,
        "eventkit_id": eventkit_id,
        "google_event_id": google_event_id,
        "i_cal_uid": i_cal_uid,
        "summary": str(result.get("summary") or before.get("summary") or ""),
        "previous_color_id": str(before.get("colorId") or ""),
        "color_id": color_id,
        "color_name": services.GOOGLE_CALENDAR_COLOR_NAMES[color_id],
        "previous_color_name": services.GOOGLE_CALENDAR_COLOR_NAMES.get(str(before.get("colorId") or ""), "알 수 없음"),
        "changed_fields": ["colorId"],
        "mutation_calls": 1,
        "execution_mode": "immediate_then_report",
        "send_updates": "none",
        "fallback_used": False,
        "tool_search_calls": 0,
    }, ensure_ascii=False)
