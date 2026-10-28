#!/usr/bin/env python3
"""Gmail calls the bundled google_api.py does not offer: attachments in and out, and cc.

Run as a subprocess with the interpreter that has the Google client. One JSON request on stdin,
one JSON answer on stdout; errors are a safe code on stderr with exit 1.
"""
from __future__ import annotations

import base64
import html
import json
import mimetypes
import os
import re
import sys
from email.message import EmailMessage
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

try:
    from . import gmail_rules
except ImportError:
    import gmail_rules


ExtraError = gmail_rules.RuleError


FILTER_SCOPE = "https://www.googleapis.com/auth/gmail.settings.basic"


def token_scopes(request):
    home = Path(request.get("token_home") or request.get("root") or
                os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
    try:
        stored = json.loads((home / "google_token.json").read_text())
        return set(stored.get("scopes") or [])
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        raise ExtraError("GMAIL_TOKEN_SCOPES_UNREADABLE") from exc


def scope_failure(request, code="GMAIL_SCOPE_MISSING:gmail.settings.basic"):
    personal = Path(request.get("token_home") or "").name == "personal-secretary"
    account = "personal" if personal else "company"
    action = ("소유자가 ~/.hermes/bin/hermes-personal-google-auth --account personal --login 실행"
              if personal else "google_reauth(action=start)로 재인증 링크 받기")
    return {"ok": False, "status": "failed", "stage": "scope_preflight",
            "failed_stage": "scope_preflight", "mutation_calls": 0, "error": code,
            "owner_action": action + "; Mac mini 브라우저에서 소유자가 동의한 뒤 " +
                ("--check" if personal else "google_reauth(action=status)") +
                "로 확인하고 원래 작업을 다시 묻는다. 터미널: " +
                "~/.hermes/bin/hermes-personal-google-auth --account " + account + " --login. " +
                "기존 메일 label_apply는 필터 권한 없이 가능하다."}


def require_filter_scope(request, rules, names, known_filters):
    for rule in rules:
        label_id = names.get(rule["label_name"].strip().casefold())
        if label_id is None or _filter_key(rule["criteria"], filter_action(label_id, rule)) not in known_filters:
            if FILTER_SCOPE not in token_scopes(request):
                raise ExtraError("GMAIL_SCOPE_MISSING:gmail.settings.basic")
            break


def scope_preflight(service, request):
    """Read-only check used before the approval button; never creates resources."""
    try:
        if request.get("action") == "filter_create":
            if FILTER_SCOPE not in token_scopes(request):
                raise ExtraError("GMAIL_SCOPE_MISSING:gmail.settings.basic")
        else:
            rules = request.get("rules") or []
            if rules:
                names = {r["name"].casefold(): r["id"] for r in labels(service)["user_labels"]}
                deleted = set(request.get("delete_filter_ids") or [])
                filters = service.users().settings().filters().list(userId="me").execute().get("filter") or []
                known = {_filter_key(f.get("criteria") or {}, f.get("action") or {}): f["id"]
                         for f in filters if f["id"] not in deleted}
                require_filter_scope(request, rules, names, known)
        return {"ok": True, "mutation_calls": 0}
    except Exception as exc:
        return scope_failure(request, safe_error(exc, "filter_create"))


def _parts(part: dict):
    yield part
    for child in part.get("parts") or []:
        yield from _parts(child)


def files(payload: dict) -> list[dict]:
    """Attached files of a message payload, in order. Inline images without a name are skipped."""
    found = []
    for part in _parts(payload):
        name = part.get("filename")
        body = part.get("body") or {}
        if name and (body.get("attachmentId") or body.get("data")):
            found.append({"filename": str(name), "size": int(body.get("size") or 0),
                          "mime": str(part.get("mimeType") or ""), "_body": body})
    return found


def listing(service, message_id: str) -> list[dict]:
    message = service.users().messages().get(userId="me", id=message_id, format="full").execute()
    return files(message.get("payload") or {})


def public(found: list[dict]) -> list[dict]:
    return [{key: value for key, value in item.items() if key != "_body"} for item in found]


def download(service, message_id: str, targets: list) -> list[dict]:
    """Save the i-th attachment to targets[i] (None skips it). The caller chose and checked the paths."""
    found = listing(service, message_id)
    if len(targets) != len(found):
        raise ExtraError("GMAIL_ATTACHMENTS_CHANGED")
    for item, target in zip(found, targets):
        if not target:
            continue
        data = item["_body"].get("data")
        if not data:
            data = service.users().messages().attachments().get(
                userId="me", messageId=message_id, id=item["_body"]["attachmentId"]).execute().get("data")
        if not isinstance(data, str):
            raise ExtraError("GMAIL_ATTACHMENT_UNREADABLE")
        try:
            Path(target).write_bytes(base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)))
        except OSError as exc:
            raise ExtraError("MAIL_ATTACHMENT_FOLDER_UNAVAILABLE") from exc
    return public(found)


def _decoded(part: dict) -> str:
    data = (part.get("body") or {}).get("data")
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", errors="replace") if data else ""


def text(payload: dict) -> str:
    """The readable body: the plain part wherever it is nested, else the HTML part without its tags."""
    parts = [part for part in _parts(payload) if not part.get("filename")]
    for part in parts:
        if part.get("mimeType") == "text/plain" and (body := _decoded(part)).strip():
            return body
    for part in parts:
        if part.get("mimeType") == "text/html" and (body := _decoded(part)).strip():
            body = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", " ", body)
            body = re.sub(r"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6])>", "\n", body)
            body = html.unescape(re.sub(r"<[^>]+>", " ", body))
            return re.sub(r"[ \t\xa0]+", " ", re.sub(r"\n\s*\n+", "\n\n", body)).strip()
    return ""


def thread(api, service, message_id: str, limit: int) -> list[dict]:
    """The conversation a message belongs to, oldest first: what came in and what was answered."""
    thread_id = service.users().messages().get(userId="me", id=message_id, format="minimal").execute()["threadId"]
    messages = service.users().threads().get(userId="me", id=thread_id, format="full").execute().get("messages") or []
    result = []
    for message in messages[-limit:]:
        headers = api._headers_dict(message)
        result.append({
            "id": message["id"], "threadId": message["threadId"],
            "from": headers.get("from", ""), "to": headers.get("to", ""),
            "subject": headers.get("subject", ""), "date": headers.get("date", ""),
            "sent_by_owner": "SENT" in (message.get("labelIds") or []),
            "body": text(message.get("payload") or {}),
            "attachments": [item["filename"] for item in files(message.get("payload") or {})],
        })
    return [{"earlier_messages_omitted": len(messages) - len(result)}, *result]


def build(request: dict) -> EmailMessage:
    message = EmailMessage()
    message["To"] = ", ".join(request["to"])
    if request.get("cc"):
        message["Cc"] = ", ".join(request["cc"])
    message["Subject"] = request["subject"]
    message.set_content(request["body"])
    for path in request.get("attachments") or []:
        file = Path(path)
        kind = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
        main, _, sub = kind.partition("/")
        try:
            content = file.read_bytes()
        except OSError as exc:
            raise ExtraError("GMAIL_ATTACHMENT_NOT_READABLE") from exc
        message.add_attachment(content, maintype=main, subtype=sub, filename=file.name)
    return message


def send(service, request: dict) -> dict:
    raw = base64.urlsafe_b64encode(build(request).as_bytes()).decode()
    result = service.users().messages().send(userId="me", body={"raw": raw}).execute()
    if not result.get("id"):
        raise ExtraError("GMAIL_SEND_NOT_CONFIRMED")
    return {"status": "sent", "id": result["id"], "threadId": result.get("threadId", "")}


def labels(service) -> dict:
    rows = service.users().labels().list(userId="me").execute().get("labels") or []
    return {"user_labels": [{"id": row["id"], "name": row["name"]}
                            for row in rows if row.get("type") == "user"],
            "system_labels": [row["name"] for row in rows if row.get("type") == "system"]}


def user_label(service, label_id) -> str:
    # Accept only a current user label, never TRASH/SPAM or any other system label.
    if not isinstance(label_id, str) or not label_id.strip():
        raise ExtraError("GMAIL_USER_LABEL_REQUIRED")
    if not any(row["id"] == label_id for row in labels(service)["user_labels"]):
        raise ExtraError("GMAIL_USER_LABEL_REQUIRED")
    return label_id


def label_create(service, name) -> dict:
    if not isinstance(name, str) or not name.strip():
        raise ExtraError("GMAIL_LABEL_NAME_REQUIRED")
    name = name.strip()
    existing = labels(service)
    for row in existing["user_labels"]:
        if row["name"].casefold() == name.casefold():
            return {**row, "created": False}
    if name.casefold() in {n.casefold() for n in existing["system_labels"]}:
        raise ExtraError("GMAIL_USER_LABEL_REQUIRED")
    result = service.users().labels().create(userId="me", body={"name": name}).execute()
    return {"id": result["id"], "name": result["name"], "created": True}


def _flag(request: dict, name: str) -> bool:
    value = request.get(name, False)
    if not isinstance(value, bool):
        raise ExtraError("GMAIL_INVALID_BOOLEAN")
    return value


def message_ids(service, query: str) -> list[str]:
    """Read the bounded snapshot before any writes. The estimate is not an exact count."""
    ids, seen_pages, page = set(), set(), None
    while True:
        options = {"userId": "me", "q": query, "maxResults": 500}
        if page:
            options["pageToken"] = page
        result = service.users().messages().list(**options).execute()
        ids.update(row["id"] for row in result.get("messages") or [])
        if len(ids) > 500:
            raise ExtraError("GMAIL_LABEL_APPLY_LIMIT_EXCEEDED")
        page = result.get("nextPageToken")
        if not page:
            break
        if page in seen_pages:
            raise ExtraError("GMAIL_LABEL_QUERY_PAGINATION_FAILED")
        seen_pages.add(page)
    return sorted(ids)


def apply_ids(service, ids, label_id, skip_inbox):
    if ids:
        body = {"ids": ids, "addLabelIds": [label_id]}
        if skip_inbox:
            body["removeLabelIds"] = ["INBOX"]
        service.users().messages().batchModify(userId="me", body=body).execute()


def label_apply(service, request: dict) -> dict:
    gmail_rules.validate_operation("label_apply", request)
    label_id = user_label(service, request.get("label_id"))
    skip_inbox = _flag(request, "skip_inbox")
    ids = message_ids(service, request["query"])
    apply_ids(service, ids, label_id, skip_inbox)
    # Gmail batchModify acknowledges the batch, without a per-message changed count.
    return {"label_id": label_id, "matched_count": len(ids), "modified_count": len(ids),
            "count_basis": "batchModify accepted message IDs", "skip_inbox": skip_inbox}


def inbox_restore(service, request: dict) -> dict:
    gmail_rules.validate_operation("inbox_restore", request)
    # Group the caller's OR expressions so the exclusions apply to every match.
    query = "-in:trash -in:spam (" + request["query"] + ")"
    ids = message_ids(service, query)
    if ids:
        service.users().messages().batchModify(userId="me", body={"ids": ids, "addLabelIds": ["INBOX"]}).execute()
    return {"matched_count": len(ids), "modified_count": len(ids),
            "count_basis": "batchModify accepted message IDs"}


def filter_create(service, request: dict) -> dict:
    # Build the action ourselves. Reject hidden/raw action fields even outside schema validation.
    if set(request) - {"op", "root", "token_home", "criteria", "label_id", "skip_inbox", "mark_read"}:
        raise ExtraError("GMAIL_FILTER_ACTION_REFUSED")
    gmail_rules.validate_operation("filter_create", request)
    if FILTER_SCOPE not in token_scopes(request):
        raise ExtraError("GMAIL_SCOPE_MISSING:gmail.settings.basic")
    criteria = request["criteria"]
    action = filter_action(user_label(service, request.get("label_id")), request)
    result = service.users().settings().filters().create(
        userId="me", body={"criteria": criteria, "action": action}).execute()
    return {"id": result["id"], "criteria": criteria, "action": action, "created": True}


def filter_action(label_id, request):
    action = {"addLabelIds": [label_id]}
    remove = []
    if _flag(request, "skip_inbox"):
        remove.append("INBOX")
    if _flag(request, "mark_read"):
        remove.append("UNREAD")
    if remove:
        action["removeLabelIds"] = remove
    return action


def _filter_key(criteria, action):
    # Gmail may omit empty/default fields and reorder label ID lists on reads.
    criteria = {k: v for k, v in criteria.items() if v not in (None, "", False)}
    action = {k: sorted(v) if k in {"addLabelIds", "removeLabelIds"} else v
              for k, v in action.items() if v not in (None, "", [])}
    return json.dumps([criteria, action], sort_keys=True, separators=(",", ":"))


def organize(service, request: dict) -> dict:
    """Preflight everything, then delete filters, classify and restore, with partial receipts."""
    results, mutation_calls, index, stage, error_op = [], 0, None, "validation", "organize"
    deleted_filters, restored, failed_filter_id, failed_restore = [], [], None, None
    try:
        if set(request) - {"op", "root", "token_home", "rules", "delete_filter_ids", "restore_inbox_queries"}:
            raise ExtraError("GMAIL_FILTER_ACTION_REFUSED")
        gmail_rules.validate_operation("mail_organize", request)
        rules = request.get("rules", [])
        delete_ids = list(dict.fromkeys(request.get("delete_filter_ids", [])))
        restore_queries = list(dict.fromkeys(request.get("restore_inbox_queries", [])))
        stage, error_op = "labels_preflight", "labels"
        existing = labels(service) if rules else {"user_labels": [], "system_labels": []}
        names = {row["name"].casefold(): row["id"] for row in existing["user_labels"]}
        systems = {name.casefold() for name in existing["system_labels"]}
        snapshots = []
        for index, rule in enumerate(rules, 1):
            stage, error_op = "labels_preflight", "labels"
            if rule["label_name"].strip().casefold() in systems:
                raise ExtraError("GMAIL_USER_LABEL_REQUIRED")
            stage, error_op = "messages_preflight", "label_apply"
            query = gmail_rules.criteria_query(rule["criteria"])
            snapshots.append(message_ids(service, query) if rule.get("apply_existing", True) else [])
        index, stage, error_op = None, "filters_preflight", "filter_list"
        filters = (service.users().settings().filters().list(userId="me").execute().get("filter") or []) if rules or delete_ids else []
        current_filter_ids = {f["id"] for f in filters}
        for failed_filter_id in delete_ids:
            if failed_filter_id not in current_filter_ids:
                raise ExtraError("GMAIL_FILTER_NOT_FOUND")
        failed_filter_id = None
        restore_snapshots = []
        stage, error_op = "restore_preflight", "inbox_restore"
        for failed_restore, query in enumerate(restore_queries, 1):
            restore_snapshots.append(message_ids(service, "-in:trash -in:spam (" + query + ")"))
        failed_restore = None
        # A deleted matching filter must be recreated, not reported as reused.
        known_filters = {_filter_key(f.get("criteria") or {}, f.get("action") or {}): f["id"]
                         for f in filters if f["id"] not in delete_ids}
        stage, error_op = "scope_preflight", "filter_create"
        require_filter_scope(request, rules, names, known_filters)
        stage, error_op = "filter_delete", "filter_delete"
        for failed_filter_id in delete_ids:
            row = {"id": failed_filter_id, "deleted": None}
            deleted_filters.append(row)
            mutation_calls += 1
            row.update(filter_delete(service, failed_filter_id))
        failed_filter_id = None
        for index, (rule, ids) in enumerate(zip(rules, snapshots), 1):
            name = rule["label_name"].strip()
            row = {"rule_index": index, "label_name": name, "label_id": names.get(name.casefold()),
                   "label_created": False, "filter_id": None, "filter_created": False,
                   "matched_count": len(ids), "modified_count": 0}
            results.append(row)
            stage, error_op = "label_create", "label_create"
            if row["label_id"] is None:
                mutation_calls += 1
                row["label_created"] = None  # A failed request may still have reached Gmail.
                made = service.users().labels().create(userId="me", body={"name": name}).execute()
                row.update(label_id=made["id"], label_created=True)
                names[name.casefold()] = made["id"]
            stage, error_op = "filter_create", "filter_create"
            action = filter_action(row["label_id"], rule)
            key = _filter_key(rule["criteria"], action)
            if key in known_filters:
                row["filter_id"] = known_filters[key]
            else:
                mutation_calls += 1
                row["filter_created"] = None
                made = service.users().settings().filters().create(
                    userId="me", body={"criteria": rule["criteria"], "action": action}).execute()
                row.update(filter_id=made["id"], filter_created=True)
                known_filters[key] = made["id"]
            stage, error_op = "label_apply", "label_apply"
            if ids:
                mutation_calls += 1
                row["modified_count"] = None
                apply_ids(service, ids, row["label_id"], rule.get("skip_inbox", False))
                row["modified_count"] = len(ids)
            row["status"] = "completed"
        index, stage, error_op = None, "inbox_restore", "inbox_restore"
        for failed_restore, (query, ids) in enumerate(zip(restore_queries, restore_snapshots), 1):
            row = {"query": query, "matched_count": len(ids), "modified_count": 0}
            restored.append(row)
            if ids:
                mutation_calls += 1
                row["modified_count"] = None
                service.users().messages().batchModify(userId="me", body={"ids": ids, "addLabelIds": ["INBOX"]}).execute()
                row["modified_count"] = len(ids)
            row["status"] = "completed"
        return {"ok": True, "status": "completed", "results": results, "mutation_calls": mutation_calls,
                "deleted_filters": deleted_filters, "restored": restored,
                "count_basis": "batchModify accepted message IDs"}
    except Exception as exc:
        code = safe_error(exc, error_op)
        if code.startswith("GMAIL_SCOPE_MISSING:"):
            # A structured 403 refused this request; earlier successful calls still count.
            if stage == "filter_delete" and deleted_filters and deleted_filters[-1]["deleted"] is None:
                deleted_filters[-1]["deleted"] = False
                mutation_calls -= 1
            elif results and stage in {"label_create", "filter_create", "label_apply"}:
                field = {"label_create": "label_created", "filter_create": "filter_created",
                         "label_apply": "modified_count"}[stage]
                if results[-1][field] is None:
                    results[-1][field] = 0 if field == "modified_count" else False
                    mutation_calls -= 1
            elif stage == "inbox_restore" and restored and restored[-1]["modified_count"] is None:
                restored[-1]["modified_count"] = 0
                mutation_calls -= 1
        return {**({"owner_action": scope_failure(request, code)["owner_action"]}
                   if code.startswith("GMAIL_SCOPE_MISSING:") else {}),
                "ok": False, "status": "partial" if mutation_calls else "failed",
                "results": results, "deleted_filters": deleted_filters, "restored": restored,
                "error": code, "stage": stage, "failed_filter_id": failed_filter_id,
                "failed_restore": failed_restore,
                "failed_rule": getattr(exc, "rule_index", None) or index,
                "failed_stage": stage, "mutation_calls": mutation_calls}


def filter_delete(service, filter_id) -> dict:
    if not isinstance(filter_id, str) or not filter_id.strip():
        raise ExtraError("GMAIL_FILTER_ID_REQUIRED")
    service.users().settings().filters().delete(userId="me", id=filter_id).execute()
    return {"id": filter_id, "deleted": True}


def safe_error(exc: Exception, operation: str) -> str:
    if isinstance(exc, (ExtraError, gmail_rules.RuleError)):
        return str(exc)
    # Inspect structured error reasons only; never print URLs, tokens or response text.
    if getattr(getattr(exc, "resp", None), "status", None) == 403:
        try:
            error = json.loads(exc.content).get("error") or {}
            reasons = {row.get("reason") for row in [*(error.get("errors") or []),
                                                     *(error.get("details") or [])]}
        except (ValueError, TypeError, AttributeError):
            reasons = set()
        if reasons & {"insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
                      "insufficientAuthenticationScopes"}:
            scope = "gmail.settings.basic" if operation.startswith("filter_") else "gmail.modify"
            return "GMAIL_SCOPE_MISSING:" + scope
    return type(exc).__name__


def full_scope_check(request):
    """Check stored consent before even preparing the new company-mail operations."""
    scopes = token_scopes(request)
    if scopes & {'https://mail.google.com/', 'https://www.googleapis.com/auth/gmail.modify'}:
        return
    action = request['action']
    suffixes = {'label_delete': {'gmail.labels'}, 'label_rename': {'gmail.labels'},
                'draft_create': {'gmail.compose'}, 'reply': {'gmail.send', 'gmail.compose'},
                'forward': {'gmail.send', 'gmail.compose'}}.get(action, {'gmail.modify'})
    if not any('https://www.googleapis.com/auth/' + s in scopes for s in suffixes):
        raise ExtraError('GMAIL_SCOPE_MISSING:' + sorted(suffixes)[0])
    if action in {'reply', 'forward'} and 'https://www.googleapis.com/auth/gmail.readonly' not in scopes:
        raise ExtraError('GMAIL_SCOPE_MISSING:gmail.readonly')


def full_changes(service, request):
    """Only the advertised status fields and current user labels, never arbitrary system labels."""
    add, remove = set(), set()
    for key, label, invert in [('read', 'UNREAD', True), ('starred', 'STARRED', False),
                                ('archive', 'INBOX', True), ('spam', 'SPAM', False)]:
        if key in request:
            (remove if request[key] == invert else add).add(label)
    if request.get('spam') is True:
        remove.add('INBOX')
    for key, target in [('add_label_ids', add), ('remove_label_ids', remove)]:
        for label in request.get(key, []):
            target.add(user_label(service, label))
    if add & remove:
        raise ExtraError('GMAIL_CONFLICTING_LABEL_CHANGES')
    return {'addLabelIds': sorted(add), 'removeLabelIds': sorted(remove)}


def full_outgoing(service, request):
    action = request['action']
    result = {k: request.get(k, '') for k in ('to', 'cc', 'subject', 'body')}
    result['threadId'] = ''
    if action in {'reply', 'forward'}:
        source = service.users().messages().get(userId='me', id=request['message_id'], format='full').execute()
        headers = {h['name'].casefold(): h['value'] for h in source.get('payload', {}).get('headers', [])}
        mid = headers.get('message-id', '')
        if not re.fullmatch(r'<[^<>\r\n\s]+>', mid) or not source.get('threadId'):
            raise ExtraError('GMAIL_REPLY_HEADERS_UNVERIFIED')
        result['threadId'] = source['threadId']
        result['In-Reply-To'] = mid
        references = re.findall(r'<[^<>\r\n\s]+>', headers.get('references', ''))
        result['References'] = ' '.join(dict.fromkeys([*references[-49:], mid]))
        # Gmail requires the original subject for membership in the original thread.
        result['subject'] = request.get('subject') or headers.get('subject', '')
        if action == 'reply' and not request.get('to'):
            from email.utils import getaddresses
            recipients = getaddresses([headers.get('reply-to') or headers.get('from', '')])
            if len(recipients) != 1 or not recipients[0][1]:
                raise ExtraError('GMAIL_REPLY_RECIPIENT_UNVERIFIED')
            result['to'] = recipients[0][1]
        if action == 'forward':
            # Include the entire readable source in the approved text. Attachments require explicit paths.
            result['body'] += '\n\n--- Forwarded message ---\nFrom: ' + headers.get('from', '') + \
                '\nDate: ' + headers.get('date', '') + '\nSubject: ' + headers.get('subject', '') + '\n\n' + text(source.get('payload') or {})
            result['original_attachments_not_included'] = public(files(source.get('payload') or {}))
    from mail_app import recipients
    recipients(result['to'])
    if result['cc']:
        recipients(result['cc'])
    return result


def full_preview(service, request):
    """Read-only, bounded snapshot used by the native approval screen."""
    import full_mail_tools
    full_mail_tools.validate({k: v for k, v in request.items() if k not in {'root', 'token_home', 'op'}}, False)
    try:
        full_scope_check(request)
    except ExtraError as exc:
        return scope_failure(request, str(exc))
    action = request['action']
    result = {'ok': True, 'mutation_calls': 0, 'ids': [], 'matched_count': 0}
    if action in {'trash', 'untrash', 'modify'}:
        ids = sorted(set(request['ids'])) if request.get('ids') else message_ids(service, request['query'])
        if len(ids) > 500:
            raise ExtraError('GMAIL_MESSAGE_LIMIT_EXCEEDED')
        result.update(ids=ids, matched_count=len(ids))
        if action == 'modify':
            result['changes'] = full_changes(service, request)
        samples = []
        for mid in ids[:10]:
            m = service.users().messages().get(userId='me', id=mid, format='metadata',
                    metadataHeaders=['From', 'Subject']).execute()
            samples.append({'id': mid, 'headers': m.get('payload', {}).get('headers', [])})
        result['sample'] = samples
    elif action in {'label_delete', 'label_rename'}:
        label = user_label(service, request['label_id'])
        result['label'] = service.users().labels().get(userId='me', id=label).execute()
        if action == 'label_rename':
            known = labels(service)
            name = request['label_name'].strip()
            if any(r['id'] != label and r['name'].casefold() == name.casefold() for r in known['user_labels']) or name.casefold() in {x.casefold() for x in known['system_labels']}:
                raise ExtraError('GMAIL_LABEL_NAME_CONFLICT')
    else:
        result['outgoing'] = full_outgoing(service, request)
    return result


def full_write(service, request):
    """Execute the approved snapshot once; an uncertain write is never retried."""
    import full_mail_tools
    full_mail_tools.validate({k: v for k, v in request.items() if k not in {'root', 'token_home', 'op', '_snapshot'}}, False)
    try:
        full_scope_check(request)
    except ExtraError as exc:
        return scope_failure(request, str(exc))
    action, snapshot = request['action'], request['_snapshot']
    ids, calls, done, verified, stage = snapshot.get('ids', []), 0, 0, None, 'preflight'
    try:
        if len(ids) > 500:
            raise ExtraError('GMAIL_MESSAGE_LIMIT_EXCEEDED')
        messages = service.users().messages()
        selected_count = len(ids)
        if action in {'trash', 'untrash', 'modify'}:
            # Skip messages already in the requested state; report changed mail, not accepted no-ops.
            desired = full_changes(service, request) if action == 'modify' else None
            effective = []
            for mid in ids:
                labels_now = set(messages.get(userId='me', id=mid, format='minimal').execute().get('labelIds', []))
                needed = ('TRASH' not in labels_now if action == 'trash' else 'TRASH' in labels_now) if action != 'modify' else (
                    not set(desired['addLabelIds']) <= labels_now or bool(set(desired['removeLabelIds']) & labels_now))
                if needed:
                    effective.append(mid)
            ids = effective
        if action in {'trash', 'untrash'}:
            for mid in ids:
                stage = action
                calls += 1
                getattr(messages, action)(userId='me', id=mid).execute()
                done += 1
        elif action == 'modify':
            changes = full_changes(service, request)
            if changes != snapshot['changes']:
                raise ExtraError('GMAIL_APPROVED_PLAN_CHANGED')
            if ids:
                stage = 'modify'
                calls += 1
                messages.batchModify(userId='me', body={'ids': ids, **changes}).execute()
                done = len(ids)
        elif action in {'label_delete', 'label_rename'}:
            label = user_label(service, request['label_id'])
            if service.users().labels().get(userId='me', id=label).execute().get('name') != snapshot['label']['name']:
                raise ExtraError('GMAIL_APPROVED_LABEL_CHANGED')
            stage = action
            calls += 1
            if action == 'label_delete':
                service.users().labels().delete(userId='me', id=label).execute()
            else:
                service.users().labels().update(userId='me', id=label, body={'name': request['label_name'].strip()}).execute()
            done = 1
            stage = 'verify'
            rows = labels(service)['user_labels']
            verified = (not any(r['id'] == label for r in rows) if action == 'label_delete' else
                        any(r['id'] == label and r['name'] == request['label_name'].strip() for r in rows))
        else:
            outgoing = snapshot['outgoing']
            from mail_app import recipients
            msg = build({**request, **outgoing, 'to': recipients(outgoing['to']),
                         'cc': recipients(outgoing['cc']) if outgoing.get('cc') else []})
            msg['From'] = request['account']
            for h in ('In-Reply-To', 'References'):
                if outgoing.get(h):
                    msg[h] = outgoing[h]
            body = {'raw': base64.urlsafe_b64encode(msg.as_bytes()).decode()}
            if outgoing.get('threadId'):
                body['threadId'] = outgoing['threadId']
            stage = action
            calls += 1
            if action == 'draft_create':
                result = service.users().drafts().create(userId='me', body={'message': body}).execute()
            else:
                result = messages.send(userId='me', body=body).execute()
            done = 1 if result.get('id') else None
            stage = 'verify'
            verified = None
            if result.get('id'):
                if action == 'draft_create':
                    check = service.users().drafts().get(userId='me', id=result['id'], format='minimal').execute()
                    verified = check.get('id') == result['id']
                else:
                    check = messages.get(userId='me', id=result['id'], format='minimal').execute()
                    verified = 'SENT' in check.get('labelIds', [])
            return {'ok': bool(done) and verified is True, 'status': 'completed' if verified is True else 'unknown',
                    'mutation_calls': calls, 'modified_count': done, 'verified': verified,
                    'id': result.get('id'), 'threadId': outgoing.get('threadId')}
        if action in {'trash', 'untrash', 'modify'}:
            stage = 'verify'
            checks = []
            for mid in ids:
                current = set(messages.get(userId='me', id=mid, format='minimal').execute().get('labelIds', []))
                checks.append(('TRASH' in current if action == 'trash' else 'TRASH' not in current) if action != 'modify'
                              else set(changes['addLabelIds']) <= current and not set(changes['removeLabelIds']) & current)
            verified = all(checks)
        return {'ok': verified is True, 'status': 'completed' if verified is True else 'unknown',
                'mutation_calls': calls, 'modified_count': done, 'verified': verified, 'matched_count': selected_count,
                'unchanged_count': selected_count - len(ids)}
    except Exception as exc:
        return {'ok': False, 'status': 'partial' if calls else 'failed', 'stage': stage,
                'mutation_calls': calls, 'confirmed_before_failure': done,
                'modified_count': done if stage == 'verify' else (None if calls else 0), 'verified': None,
                'error': safe_error(exc, action), 'automatic_retry': False}


def main() -> int:
    operation = ""
    try:
        request = json.loads(sys.stdin.read())
        root = Path(request["root"])
        sys.path.insert(0, str(root / "hermes-agent"))
        import gmail_watch
        api, service = gmail_watch.gmail_client(root, token_home=Path(request["token_home"])) if request.get("token_home") else gmail_watch.gmail_client(root)
        operation = request["op"]
        if operation == 'full_preview':
            answer = full_preview(service, request)
        elif operation == 'full_write':
            answer = full_write(service, request)
        elif operation == "details":
            message = service.users().messages().get(userId="me", id=request["message_id"], format="full").execute()
            payload = message.get("payload") or {}
            answer = {"attachments": public(files(payload)), "body": text(payload)}
        elif operation == "thread":
            answer = thread(api, service, request["message_id"], int(request["limit"]))
        elif operation == "attachments":
            answer = public(listing(service, request["message_id"]))
        elif operation == "download":
            answer = download(service, request["message_id"], request["targets"])
        elif operation == "send":
            answer = send(service, request)
        elif operation == "labels":
            answer = labels(service)
        elif operation == "label_create":
            answer = label_create(service, request.get("label_name"))
        elif operation == "label_apply":
            answer = label_apply(service, request)
        elif operation == "filter_list":
            answer = {"filters": service.users().settings().filters().list(userId="me").execute().get("filter") or []}
        elif operation == "scope_preflight":
            answer = scope_preflight(service, request)
        elif operation == "filter_create":
            answer = filter_create(service, request)
        elif operation == "filter_delete":
            answer = filter_delete(service, request.get("filter_id"))
        elif operation == "organize":
            answer = organize(service, request)
        elif operation == "inbox_restore":
            answer = inbox_restore(service, request)
        else:
            raise ExtraError("GMAIL_EXTRA_BAD_OPERATION")
        print(json.dumps(answer, ensure_ascii=False))
        return 0
    except Exception as exc:
        # Client exceptions can carry credentials or mail data. Print a safe code only.
        code = safe_error(exc, operation)
        if operation == "filter_create" and code.startswith("GMAIL_SCOPE_MISSING:"):
            print(json.dumps(scope_failure(request, code), ensure_ascii=False))
            return 0
        print("GMAIL_EXTRA_FAILED:" + code, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
