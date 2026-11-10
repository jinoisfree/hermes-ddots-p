"""Mail execution with injected account, scope and approval services."""
from __future__ import annotations
import json
import hashlib
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any
from dataclasses import dataclass

@dataclass(frozen=True)
class Services:
    """One call's dependencies. No profile or gateway modules are imported here."""
    GMAIL_LABEL_FILTER_ACTIONS: Any
    GMAIL_LABEL_FILTER_WRITES: Any
    GMAIL_WRITE_FIELDS: Any
    MAIL_BODY: Any
    MAIL_FILE_BYTES: Any
    MAIL_FILE_LIMIT: Any
    MAIL_SEND_BYTES: Any
    MAIL_THREAD_BODY: Any
    MAIL_THREAD_MESSAGES: Any
    _GMAIL_NOT_SENT: Any
    _PLUGIN_CONTEXT: Any
    _attachment_root: Any
    _clear_pending_personal_owner: Any
    _company_mail_cron_read: Any
    _error: Any
    _gmail_account: Any
    _gmail_direct: Any
    _gmail_extra: Any
    _gmail_local_execute: Any
    _gmail_lookup_body: Any
    _gmail_outage_test: Any
    _gmail_python: Any
    _gmail_root: Any
    _gmail_scope_preflight: Any
    _gmail_success_receipt: Any
    _inside: Any
    _lead_folders: Any
    _lookup_bodies: Any
    _mail_account_read: Any
    _mail_app_accounts: Any
    _mail_app_execute: Any
    _mail_download: Any
    _mail_download_name: Any
    _mail_send_files: Any
    _mail_thread: Any
    _personal_actor: Any
    _personal_owner_error: Any
    _personal_role_problem: Any
    _unquoted: Any
    full_mail_tools: Any
    get_session_env: Any
    gmail_extra: Any
    gmail_rules: Any
    gmail_watch: Any
    google_reauth: Any
    host: Any
    mail_app: Any
    personal_roles: Any
    personal_scopes: Any
    team: Any


def _gmail_success_receipt(services, operation: str, entry: dict[str, Any], gmail_error: str = "") -> str:
    mutation = operation == "send" or operation in services.GMAIL_LABEL_FILTER_WRITES
    payload=entry.get('response',entry.get('data'))
    success=not isinstance(payload,dict) or payload.get('ok') is not False
    if mutation and success:
        services._clear_pending_personal_owner()
    return json.dumps({
        "ok": success,
        "work_type": "gmail_" + operation,
        "action": operation,
        "owner_profile": services._personal_actor(),
        "authority": "Mac Mail app (Gmail unavailable)" if gmail_error else "Gmail API via Hermes local OAuth",
        "response": entry.get("response", entry.get("data")),
        "fallback_used": bool(gmail_error),
        **({"gmail_error": gmail_error} if gmail_error else {}),
        "tool_search_calls": 0,
        "mutation_calls": 1 if mutation else 0,
        "approved": mutation,
    }, ensure_ascii=False)

def _gmail_account(services) -> str:
    if (scopes := services.personal_scopes) is not None and scopes.MAIL_ACCOUNT.get():
        return scopes.MAIL_ACCOUNT.get()
    settings = services._PLUGIN_CONTEXT.get_config("gmail", {}) if services._PLUGIN_CONTEXT else {}
    return str(settings.get("account", "") or "") if isinstance(settings, dict) else ""

def _gmail_python(services, hermes_home: Path) -> Path:
    # Managed Hermes moved its dependencies out of the old checkout venv. Resolve the same
    # selected dependency interpreter cron uses; do not pin an install generation.
    from pm.environments import project_python
    return project_python(hermes_home / "hermes-agent")

def _gmail_local_execute(services,
    operation: str,
    values: dict[str, Any],
    *,
    runner: Any = None,
) -> str:
    hermes_home = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
    if hermes_home.parent.name == "profiles":
        hermes_home = hermes_home.parent.parent
    token_home = services.personal_scopes.token_home(services.host, hermes_home)
    token_path = token_home / "google_token.json"
    if services._gmail_outage_test():
        return services._error("GMAIL_NOT_CONNECTED")
    try:
        python_path = services._gmail_python(hermes_home)
    except (OSError, ValueError, RuntimeError):
        return services._error("GMAIL_LOCAL_API_UNAVAILABLE")
    script_path = (
        hermes_home / "hermes-agent" / "skills" / "productivity"
        / "google-workspace" / "scripts" / "google_api.py"
    )
    if not token_path.is_file():
        return services._error("GMAIL_NOT_CONNECTED")
    if not python_path.is_file() or not script_path.is_file():
        return services._error("GMAIL_LOCAL_API_UNAVAILABLE")

    if operation == "send":
        command = [
            str(python_path), str(script_path), "gmail", "send",
            "--to", str(values["to"]),
            "--subject", str(values["subject"]),
            "--body", str(values["body"]),
        ]
    elif operation == "read":
        command = [str(python_path), str(script_path), "gmail", "get", values["message_id"]]
    else:
        command = [
            str(python_path), str(script_path), "gmail", "search",
            str(values["query"]), "--max", str(values["limit"]),
        ]

    execute = runner or subprocess.run
    try:
        proc = execute(command, capture_output=True, text=True, timeout=60, check=False,
                       env={**os.environ, "HERMES_HOME": str(token_home)})
    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"GMAIL_LOCAL_API_UNAVAILABLE:{type(exc).__name__}")
    if proc.returncode != 0:
        stderr = str(proc.stderr or "").lower()
        if "no google authentication" in stderr or "re-run setup" in stderr:
            return services._error("GMAIL_NOT_CONNECTED")
        return services._error(f"GMAIL_LOCAL_API_FAILED:{proc.returncode}")

    output = str(proc.stdout or "").strip()
    if operation == "lookup" and output == "No messages found.":
        response: Any = []
    else:
        try:
            response = json.loads(output)
        except json.JSONDecodeError:
            return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
    if operation == "lookup" and not isinstance(response, list):
        return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
    try:
        if operation == "lookup":
            if not all(isinstance(item, dict) for item in response):
                return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
            response = [services.gmail_watch.with_link(item, services._gmail_account()) for item in response]
        elif operation == "read":
            if (not isinstance(response, dict) or response.get("id") != values["message_id"]
                    or not isinstance(response.get("body"), str)):
                return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
            response = services.gmail_watch.with_link(response, services._gmail_account())
            body = response["body"]
            response.update(body=body[:services.MAIL_BODY], body_truncated=len(body) > services.MAIL_BODY, body_length=len(body))
    except services.gmail_watch.WatchError as exc:
        return services._error(str(exc))
    if operation == "send" and (
        not isinstance(response, dict)
        or str(response.get("status") or "").lower() != "sent"
        or not response.get("id")
    ):
        return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
    return services._gmail_success_receipt(operation, {"response": response})

def _unquoted(services, body: str) -> str:
    """A reply without the earlier mail it quotes, which the thread already lists on its own."""
    kept = []
    for line in str(body).splitlines():
        if re.match(r"\s*(On .{5,120} wrote:|-{2,}\s*Original Message\s*-{2,}|.{5,80}님이 작성:|From: .+)\s*$", line):
            break
        if not line.lstrip().startswith(">"):
            kept.append(line)
    return "\n".join(kept).strip()

def _mail_thread(services, message_id: str, runner: Any = None) -> str:
    if services.mail_app.valid_id(message_id):
        return services._error("MAIL_APP_THREAD_UNAVAILABLE")
    listed, error = services._gmail_extra({"op": "thread", "message_id": message_id, "limit": services.MAIL_THREAD_MESSAGES}, runner)
    if error or not isinstance(listed, list) or not listed or not all(isinstance(item, dict) for item in listed):
        return services._error(error or "GMAIL_LOCAL_API_INVALID_RESPONSE")
    try:
        messages = []
        for item in listed[1:]:
            if not services.gmail_watch.valid_id(item.get("id")) or not isinstance(item.get("body"), str):
                return services._error("GMAIL_LOCAL_API_INVALID_RESPONSE")
            body = services._unquoted(item["body"])
            entry = services.gmail_watch.with_link({**item, "body": body[:services.MAIL_THREAD_BODY]}, services._gmail_account())
            entry.update(body_truncated=len(body) > services.MAIL_THREAD_BODY, is_requested_message=item["id"] == message_id)
            messages.append(entry)
    except services.gmail_watch.WatchError as exc:
        return services._error(str(exc))
    return services._gmail_success_receipt("thread", {"response": {
        "messages": messages, "earlier_messages_omitted": int(listed[0].get("earlier_messages_omitted") or 0)}})

def _gmail_root(services) -> Path:
    hermes_home = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
    return hermes_home.parent.parent if hermes_home.parent.name == "profiles" else hermes_home

def _gmail_outage_test(services) -> bool:
    """True while a deliberate outage test is on: <profile home>/state/gmail-outage-test holds the
    time (epoch seconds, at most an hour ahead) until which Gmail is treated as disconnected."""
    try:
        from hermes_constants import get_hermes_home
        until = int((Path(get_hermes_home()) / "state" / "gmail-outage-test").read_text().strip())
    except (OSError, ValueError):
        return False
    return 0 < until - time.time() <= 3600

def _gmail_extra(services, request: dict[str, Any], runner: Any = None, *, on_progress=None) -> tuple[Any, str]:
    """(answer, "") from gmail_extra.py, or (None, error code)."""
    if services._gmail_outage_test():
        return None, "GMAIL_NOT_CONNECTED"
    root = services._gmail_root()
    token_home = services.personal_scopes.token_home(services.host, root)
    if not (token_home / "google_token.json").is_file():
        return None, "GMAIL_NOT_CONNECTED"
    try:
        python_path = services._gmail_python(root)
    except (OSError, ValueError, RuntimeError):
        return None, "GMAIL_LOCAL_API_UNAVAILABLE"
    def frames(output):
        if isinstance(output,bytes):output=output.decode('utf-8',errors='replace')
        result=None;malformed=False
        for line in str(output or '').splitlines():
            try:row=json.loads(line)
            except ValueError:
                malformed=True;continue  # A truncated line cannot attest a new ID.
            if isinstance(row,dict) and row.get('_event')=='gmail_effect':
                if on_progress is not None:on_progress(row)
            else:
                if result is not None:malformed=True
                result=row
        return None if malformed else result
    execute = runner or subprocess.run
    try:
        proc = execute([str(python_path), str(Path(__file__).with_name("gmail_extra.py"))],
                       input=json.dumps({**request, "root": str(root), "token_home": str(token_home)}), capture_output=True, text=True,
                       timeout=120, check=False, env={**os.environ, "HERMES_HOME": str(root)})
    except (OSError, subprocess.TimeoutExpired) as exc:
        if isinstance(exc,subprocess.TimeoutExpired):frames(exc.stdout)
        return None, f"GMAIL_LOCAL_API_UNAVAILABLE:{type(exc).__name__}"
    if proc.returncode != 0:
        frames(getattr(proc,'stdout',''))
        code = str(proc.stderr or "").strip().rpartition("GMAIL_EXTRA_FAILED:")[2].split()[0:1]
        code = code[0] if code else "unknown"
        if code in {"RefreshError", "DefaultCredentialsError", "FileNotFoundError"}:
            return None, "GMAIL_NOT_CONNECTED"
        if request.get("op") in services.GMAIL_LABEL_FILTER_ACTIONS | {"organize", "full_preview", "full_write", "full_restore"} and re.fullmatch(r"(?:GMAIL|MAIL)_[A-Z_]+(?::gmail\.[a-z.]+)?", code):
            return None, code
        # HttpError: Gmail answered and refused, so nothing was sent. Anything else may have gone out.
        return None, ("GMAIL_LOCAL_API_FAILED:" if code == "HttpError" else "GMAIL_RESULT_UNKNOWN:") + code[:60]
    try:
        result=frames(proc.stdout)
        if result is None:raise ValueError('invalid response')
        return result, ""
    except ValueError:
        return None, "GMAIL_LOCAL_API_INVALID_RESPONSE"

def _mail_send_files(services, raw: Any) -> tuple[list[Path], str]:
    """The files a send may attach, or an error code. Only files the lead profile may already read."""
    if raw in (None, []):
        return [], ""
    if not isinstance(raw, list) or len(raw) > services.MAIL_FILE_LIMIT:
        return [], "GMAIL_ATTACHMENTS_INVALID"
    files, total = [], 0
    for item in raw:
        target = services._inside(item, [*services._lead_folders(), services._attachment_root()])
        if target is None or not target.is_file():
            return [], "GMAIL_ATTACHMENT_NOT_READABLE"
        total += target.stat().st_size
        files.append(target)
    if len(set(files)) != len(files) or total > services.MAIL_SEND_BYTES:
        return [], "GMAIL_ATTACHMENTS_TOO_LARGE" if total > services.MAIL_SEND_BYTES else "GMAIL_ATTACHMENTS_INVALID"
    return files, ""

def _mail_download_name(services, name: str, taken: set[str]) -> str:
    """A flat, harmless file name for something a stranger named."""
    name = re.sub(r"[\x00-\x1f/\\:]", "_", str(name)).strip().lstrip(".") or "attachment"
    stem, dot, suffix = name.rpartition(".")
    if not dot or len(suffix) > 10:
        stem, suffix = name, ""
    stem = stem[:80]
    candidate, count = stem + ("." + suffix if suffix else ""), 1
    while candidate.casefold() in taken:
        count += 1
        candidate = f"{stem} ({count})" + ("." + suffix if suffix else "")
    taken.add(candidate.casefold())
    return candidate

def _mail_download(services, message_id: str, runner: Any = None, mail_runner: Any = None, *, account: str = "") -> str:
    from_mail_app = services.mail_app.valid_id(message_id)
    try:
        if from_mail_app:
            listed, error = services.mail_app.attachments(account, message_id, mail_runner, all_mailboxes=True) if account else services.mail_app.attachments(services._gmail_account(), message_id, mail_runner), ""
        else:
            listed, error = services._gmail_extra({"op": "attachments", "message_id": message_id}, runner)
    except services.mail_app.MailAppError as exc:
        listed, error = None, str(exc)
    if error or not isinstance(listed, list):
        return services._error(error or "GMAIL_LOCAL_API_INVALID_RESPONSE")
    folder = services._attachment_root() / "mail"
    if account:
        folder = folder / hashlib.sha256(account.encode()).hexdigest()[:16]
    folder = folder / message_id
    taken: set[str] = set()
    files, targets = [], []
    for item in listed:
        name = services._mail_download_name(item.get("filename") if isinstance(item, dict) else "", taken)
        size = item.get("size") if isinstance(item, dict) and type(item.get("size")) is int else 0
        entry = {"filename": name, "size": size}
        if len([t for t in targets if t]) >= services.MAIL_FILE_LIMIT or size > services.MAIL_FILE_BYTES:
            entry.update(saved=False, reason="too many files" if size <= services.MAIL_FILE_BYTES else "larger than 25 MB")
            targets.append(None)
        else:
            entry["path"] = str(folder / name)
            targets.append(entry["path"])
        files.append(entry)
    if any(targets):
        try:
            folder.mkdir(parents=True, exist_ok=True)
            if from_mail_app:
                if account:
                    services.mail_app.download(account, message_id, targets, mail_runner, all_mailboxes=True)
                else:
                    services.mail_app.download(services._gmail_account(), message_id, targets, mail_runner)
            else:
                _, error = services._gmail_extra({"op": "download", "message_id": message_id, "targets": targets}, runner)
        except (OSError, services.mail_app.MailAppError) as exc:
            error = str(exc) if isinstance(exc, services.mail_app.MailAppError) else "MAIL_ATTACHMENT_FOLDER_UNAVAILABLE"
        if error:
            return services._error(error)
    for entry in files:
        if "path" in entry:
            saved = services._inside(entry["path"], [folder.resolve()])
            entry["saved"] = bool(saved and saved.is_file() and saved.stat().st_size <= services.MAIL_FILE_BYTES)
            if not entry["saved"]:
                entry.pop("path")
    return services._gmail_success_receipt("download", {"response": {"message_id": message_id, "files": files}},
                                  "GMAIL_NOT_USED_FOR_MAIL_APP_ID" if from_mail_app else "")

def _mail_app_execute(services, operation: str, values: dict[str, Any], gmail_error: str, runner: Any = None) -> str | None:
    """Do a lookup, read or approved send through the Mail app; None when it cannot, so the Gmail error stands."""
    try:
        account = services._gmail_account()
        if operation == "send":
            response = services.mail_app.send(account, values["to"], values["subject"], values["body"], runner,
                                     cc=values.get("cc", ""), attachments=values.get("files") or [])
        elif operation == "read":
            response = services.gmail_watch.with_link(services.mail_app.read(account, values["message_id"], runner), account)
            body = response["body"]
            response.update(body=body[:services.MAIL_BODY], body_truncated=len(body) > services.MAIL_BODY, body_length=len(body))
        else:
            searched = services.mail_app.search(account, values["query"], values["limit"], runner)
            response = [services.gmail_watch.with_link(item, account) for item in searched]
            if values.get("include_body") is True:
                services._lookup_bodies(response, lambda mid: services.mail_app.read(account, mid, runner))
    except (services.mail_app.MailAppError, services.gmail_watch.WatchError):
        return None
    receipt = json.loads(services._gmail_success_receipt(operation, {"response": response}, gmail_error))
    if operation == 'lookup':
        receipt['search'] = searched.coverage
    return json.dumps(receipt, ensure_ascii=False)

def _mail_app_accounts(services, runner):
    configured = services._gmail_account().strip().casefold()
    return [{**row, "routes": {a: "gmail" if a == configured else "mail_app" for a in row["addresses"]}}
            for row in services.mail_app.accounts(runner)]

def _company_mail_cron_read(services, action, account):
    """Only the transferred company mailbox watch; keep the scope and background guards above."""
    env = lambda key: services.get_session_env(key, "") or os.environ.get(key, "")
    cfg = services.personal_scopes.config(services.host)
    return (services.team.has_role(services.personal_roles.profile(services.host), 'work')
            and bool(env("HERMES_CRON_SESSION"))
            and not any(env(f) for f in ("HERMES_SINGLE_QUERY_SESSION", "HERMES_KANBAN_TASK"))
            and action in {"lookup", "read", "thread"}
            and isinstance(cfg, dict) and not cfg.get("invalid")
            and account in {str(a).strip().casefold() for a in cfg.get("company", {}).get("mail_accounts", [])})

def _lookup_bodies(services, rows, read):
    """Enrich at most three results using read-only readers; failures stay per message."""
    for item in rows[:3]:
        try:
            detail = read(item["id"])
            if not isinstance(detail, dict) or not isinstance(detail.get("body"), str):
                raise ValueError("MAIL_BODY_UNAVAILABLE")
            body = detail["body"]
            item.update(body=body[:services.MAIL_BODY],
                        body_length=detail.get("body_length", len(body)),
                        body_truncated=bool(detail.get("body_truncated") or len(body) > services.MAIL_BODY),
                        attachment_names=[str(a.get("filename")) if isinstance(a, dict) else str(a)
                                          for a in detail.get("attachments", [])])
            if detail.get("attachments_unknown"):
                item["attachments_unknown"] = True
        except (ValueError, OSError, KeyError, TypeError) as exc:
            item["body_error"] = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
    return rows

def _gmail_lookup_body(services, mid, runner, mail_runner):
    # Reuse the bounded read + nested MIME/attachment extraction, including scope guards.
    result = json.loads(services._gmail_direct({"action": "read", "message_id": mid}, runner=runner, mail_runner=mail_runner))
    if not result.get("ok"):
        raise ValueError(result.get("error") or "GMAIL_BODY_UNAVAILABLE")
    return result["response"]

def _mail_account_read(services, args, account, runner):
    action = args.get("action")
    search_coverage = None
    try:
        rows = services._mail_app_accounts(runner)
        found = next((x for x in rows if account in x["addresses"]), None)
        if found is None:
            return json.dumps({"ok":False,"error":"MAIL_APP_ACCOUNT_NOT_REGISTERED", "accounts":rows},ensure_ascii=False)
        if not found["enabled"]:
            return services._error("MAIL_APP_ACCOUNT_DISABLED")
        if action == "lookup":
            limit = min(20, max(1, int(args.get("limit") or 5)))
            cache_root = None
            if services.team.has_role(services.personal_roles.profile(services.host), 'work') and not services.personal_scopes.background(services.host):
                cache_root = services.team.home_of_role('work', services._gmail_root()) / 'cache/mail-search'
            response = services.mail_app.search(account, str(args.get("query") or ""), limit, runner,
                                       all_mailboxes=True, cache_root=cache_root)
            search_coverage = response.coverage
            response = [{**x, "account":account} for x in response]
            if args.get("include_body") is True:
                services._lookup_bodies(response, lambda mid: services.mail_app.read(account, mid, runner))
        else:
            mid = args.get("message_id")
            if not services.mail_app.valid_id(mid):
                return services._error("MAIL_APP_INVALID_ID: pass an m-prefixed id with its lookup account")
            if action == "download":
                payload = json.loads(services._mail_download(mid, mail_runner=runner, account=account))
                payload.update(account=account, authority="Mac Mail app", fallback_used=False)
                payload.pop("gmail_error", None)
                return json.dumps(payload,ensure_ascii=False)
            item = services.mail_app.read(account, mid, runner, all_mailboxes=True)
            body = item["body"]
            item.update(account=account,body=body[:services.MAIL_BODY],body_length=len(body),body_truncated=len(body)>services.MAIL_BODY)
            response = item
            if action == "thread":
                # Mail exposes no reliable conversation identifier; do not invent thread membership.
                response = {"messages":[item],"thread_complete":False,
                            "limitation":"MAIL_APP_THREAD_UNAVAILABLE: only the requested message; use lookup for related mail"}
        return json.dumps({"ok":True,"action":action,"authority":"Mac Mail app","account":account,
                           "response":response,"fallback_used":False,"mutation_calls":0,"tool_search_calls":0,
                           **({'search': search_coverage} if search_coverage is not None else {})},ensure_ascii=False)
    except (services.mail_app.MailAppError, ValueError) as exc:
        return services._error(str(exc) if isinstance(exc, services.mail_app.MailAppError) else "MAIL_APP_INVALID_LIMIT")

def _gmail_scope_preflight(services, args, runner=None):
    action = str(args.get('action') or '').strip().lower()
    if action not in {'filter_create', 'mail_organize'} or (action == 'mail_organize' and not args.get('rules')):
        return None
    root = services._gmail_root()
    cfg = services.personal_scopes.config(services.host)
    if cfg and not cfg.get('invalid'):
        account = services.personal_scopes.mailbox(services.host, args, cfg)
        home = services.team.home_of_role('personal', root) if account == cfg['personal']['gmail'].casefold() else root
    else:
        home = services.personal_scopes.token_home(services.host, root)
    request = {'root': str(root), 'token_home': str(home), 'action': action,
               **{k: args[k] for k in services.GMAIL_WRITE_FIELDS[action] if k in args}}
    try:
        if services.gmail_extra.FILTER_SCOPE in services.gmail_extra.token_scopes(request):
            return None
    except services.gmail_extra.ExtraError as exc:
        return services.gmail_extra.scope_failure(request, str(exc))
    if action == 'filter_create':
        return services.gmail_extra.scope_failure(request)
    # Organize can reuse existing filters even without filter creation permission.
    selected = services.personal_scopes.MAIL_ACCOUNT.set(account) if cfg and not cfg.get('invalid') else None
    try:
        response, error = services._gmail_extra({'op': 'scope_preflight', **request}, runner)
    finally:
        if selected is not None:
            services.personal_scopes.MAIL_ACCOUNT.reset(selected)
    if error:
        return services.gmail_extra.scope_failure(request, error)
    if not isinstance(response, dict) or response.get('ok') is not True:
        return response if isinstance(response, dict) and response.get('ok') is False else services.gmail_extra.scope_failure(request, 'GMAIL_LOCAL_API_INVALID_RESPONSE')
    return None

def _google_reauth(services, args, **_):
    try:
        return json.dumps(services.google_reauth.run(services.host, args), ensure_ascii=False)
    except (OSError, ValueError) as exc:
        return services._error('GOOGLE_REAUTH_' + type(exc).__name__, mutation_calls=0)

def _gmail_direct(services, args: dict[str, Any], runner: Any = None, mail_runner: Any = None, **_: Any) -> str:
    if problem := services._personal_role_problem('gmail_direct', args):
        return services._error(problem)
    if error := services._personal_owner_error("gmail_direct"):
        return error
    from hermes_constants import get_hermes_home
    from hermes_facility import app_scope, app_registry
    home = get_hermes_home()
    if app_registry.explicit(app_registry.root_of(home), app_registry.profile_of(home)):
        chosen = str(args.get('account') or '').casefold()
        saved = app_registry.values(app_registry.root_of(home), app_registry.profile_of(home))
        mail_entries = [v for b, v in saved.items() if app_registry.load_catalog().get(b, {}).get('service') == 'apple_mail']
        known_mail = {str(a).casefold() for v in mail_entries for a in v.get('scope', [])}
        mail_action = args.get('action') in services.full_mail_tools.MAIL_READS | services.full_mail_tools.MAIL_WRITES
        if mail_action or chosen in known_mail:
            if not services.full_mail_tools.app_grant(services.host): return services._error('APP_NOT_CONNECTED')
            if app_scope.mail_allowed(home, args) is not True: return services._error('APP_ACCOUNT_OUT_OF_SCOPE')
    if services.full_mail_tools.handles(services.host, args):
        return services.full_mail_tools.run(services.host, args, runner, mail_runner)
    action = str(args.get("action") or "").strip().lower()
    account = services.personal_scopes.normalize_mail_account(services.host, args.get('account'), runner=mail_runner)
    other = bool(account and account != services._gmail_account().strip().casefold())
    if other and action not in {"lookup", "read", "thread", "download"}:
        return services._error("MAIL_APP_ACCOUNT_READ_ONLY: other accounts allow lookup/read/thread/download only")
    if other or action == "accounts":
        if not services._company_mail_cron_read(action, account) and (
            services.get_session_env("HERMES_SESSION_PLATFORM", "").strip().lower() not in {"slack", "photon"}
            or not services.get_session_env("HERMES_SESSION_CHAT_ID", "").strip()
            or services.personal_scopes.background(services.host)):
            return services._error("MAIL_APP_OWNER_CHAT_REQUIRED")
        settings = services._PLUGIN_CONTEXT.get_config("gmail", {}) if services._PLUGIN_CONTEXT else {}
        if isinstance(settings, dict) and settings.get("mail_app_accounts_enabled") is False:
            return services._error("MAIL_APP_ACCOUNTS_DISABLED")
        if action == "accounts":
            try:
                return json.dumps({"ok":True,"action":"accounts","accounts":services._mail_app_accounts(mail_runner),
                                   "mutation_calls":0,"fallback_used":False},ensure_ascii=False)
            except services.mail_app.MailAppError as exc:
                return services._error(str(exc))
        return services._mail_account_read(args, account, mail_runner)
    if action in services.GMAIL_LABEL_FILTER_ACTIONS - services.full_mail_tools.BASIC:
        # Enforce this even when personal_scopes is not configured; never use Mail app fallback.
        if services.personal_scopes.background(services.host):
            return services._error("PERSONAL_SCOPE_BACKGROUND_REFUSED: 예약·배경에서 라벨·필터 호출은 허용되지 않는다.", mutation_calls=0)
        if (services.get_session_env("HERMES_SESSION_PLATFORM", "") not in {"slack", "photon"}
                or not services.get_session_env("HERMES_SESSION_CHAT_ID", "")
                or not services.get_session_env("HERMES_SESSION_USER_ID", "")):
            return services._error("PERSONAL_SCOPE_OWNER_CHAT_REQUIRED: 라벨·필터는 인증된 소유자 대화에서만 가능하다.", mutation_calls=0)
        response,error=services._gmail_extra({'op':action},runner)
        if error:return services._error(error)
        if not isinstance(response,dict):return services._error('GMAIL_LOCAL_API_INVALID_RESPONSE')
        return services._gmail_success_receipt(action,{'response':response})
    send_files: list[Path] = []
    if action == "send":
        send_files, problem = services._mail_send_files(args.get("attachments"))
        if not problem and (str(args.get("cc") or "").strip() or send_files):
            try:  # The plain Gmail path takes any header text; the others need clean addresses.
                services.mail_app.recipients(args.get("to"))
                if str(args.get("cc") or "").strip():
                    services.mail_app.recipients(args.get("cc"))
            except services.mail_app.MailAppError:
                problem = "GMAIL_INVALID_RECIPIENT"
        if problem:
            return services._error(problem)
    if action == "send" and not all(str(args.get(key) or "").strip() for key in ("to", "subject", "body")):
        return services._error("GMAIL_SEND_FIELDS_REQUIRED")
    if action == "ack":
        from hermes_constants import get_hermes_home
        try:
            ids = services.gmail_watch.acknowledge(Path(get_hermes_home()), args.get("ids"))
        except (services.gmail_watch.WatchError, OSError) as exc:
            return services._error(str(exc) if isinstance(exc, services.gmail_watch.WatchError) else "MAIL_WATCH_STATE_UNAVAILABLE")
        return services._gmail_success_receipt(action, {"response": {"acknowledged_ids": ids, "count": len(ids)}})
    if action in {"read", "thread", "download"} and not services.gmail_watch.valid_id(args.get("message_id")):
        return services._error("GMAIL_INVALID_MESSAGE_ID")
    if action == "thread":
        return services._mail_thread(args["message_id"], runner)
    if action == "download":
        return services._mail_download(args["message_id"], runner, mail_runner)
    if action not in {"lookup", "read", "send"}:
        return services._error("invalid Gmail action")
    query = str(args.get("query") or "").strip() or "recent Gmail messages needing attention"
    try:
        limit = min(20, max(1, int(args.get("limit") or 5)))
    except (TypeError, ValueError):
        return services._error("invalid Gmail limit")
    values = {
        "message_id": args.get("message_id"),
        "query": query,
        "include_body": args.get("include_body") is True,
        "limit": limit,
        "to": str(args.get("to") or "").strip(),
        "cc": str(args.get("cc") or "").strip(),
        "files": [str(f) for f in send_files],
        "subject": str(args.get("subject") or "").strip(),
        "body": str(args.get("body") or ""),
    }
    if action == "read" and services.mail_app.valid_id(values["message_id"]):
        return (services._mail_app_execute(action, values, "GMAIL_NOT_USED_FOR_MAIL_APP_ID", mail_runner)
                or services._error("MAIL_APP_UNAVAILABLE"))
    if action == "send" and (values["cc"] or values["files"]):
        sent, error = services._gmail_extra({"op": "send", "to": services.mail_app.recipients(values["to"]),
                                    "cc": services.mail_app.recipients(values["cc"]) if values["cc"] else [],
                                    "subject": values["subject"], "body": values["body"],
                                    "attachments": values["files"]}, runner)
        if not error and not (isinstance(sent, dict) and sent.get("status") == "sent" and sent.get("id")):
            error = "GMAIL_LOCAL_API_INVALID_RESPONSE"
        result = services._error(error) if error else services._gmail_success_receipt("send", {"response": sent})
    else:
        result = services._gmail_local_execute(action, values, runner=runner)
    if action == "lookup" and args.get("include_body") is True:
        done = json.loads(result)
        if done.get("ok") and isinstance(done.get("response"), list):
            services._lookup_bodies(done["response"], lambda mid: services._gmail_lookup_body(mid, runner, mail_runner))
            result = json.dumps(done, ensure_ascii=False)
    if action == "read":
        try:
            done = json.loads(result)
        except ValueError:
            done = {}
        if isinstance(done, dict) and done.get("ok") and isinstance(done.get("response"), dict):
            details, error = services._gmail_extra({"op": "details", "message_id": values["message_id"]}, runner)
            listed = details.get("attachments") if isinstance(details, dict) else None
            if error or not isinstance(listed, list):
                done["response"]["attachments_unknown"] = True
            else:
                done["response"]["attachments"] = [
                    {"filename": str(f.get("filename")), "size": f.get("size")} for f in listed if isinstance(f, dict)]
                # The bundled reader misses a body nested beside attachments; this one finds it.
                body = details.get("body")
                if not str(done["response"].get("body") or "").strip() and isinstance(body, str) and body.strip():
                    done["response"].update(body=body[:services.MAIL_BODY], body_truncated=len(body) > services.MAIL_BODY, body_length=len(body))
            result = json.dumps(done, ensure_ascii=False)
    if action in {"lookup", "read"}:
        try:
            failed = json.loads(result)
        except ValueError:
            failed = {}
        if isinstance(failed, dict) and failed.get("ok") is False:
            code = str(failed.get("error") or "GMAIL_FAILED")
            if not code.startswith("GMAIL_LOCAL_API_INVALID") and action == "lookup":
                return services._mail_app_execute(action, values, code, mail_runner) or result
    if action == "send":
        try:
            failed = json.loads(result)
        except ValueError:
            failed = {}
        code = str(failed.get("error") or "") if isinstance(failed, dict) and failed.get("ok") is False else ""
        if code.startswith(services._GMAIL_NOT_SENT) and not code.endswith("TimeoutExpired"):
            return services._mail_app_execute(action, values, code, mail_runner) or result
    return result
