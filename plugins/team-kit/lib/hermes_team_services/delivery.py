"""Owner delivery switch and local hejo transport; callers own retry state.

No queue lives here. A retryable post supplies its persisted occurrence key,
its state item, and a save callback which commits that item before each I/O.
"""
from __future__ import annotations

import http.client
import json
from pathlib import Path
import re
import socket
from urllib.parse import quote, urlencode
import uuid

from hermes_facility import owner_vault, team_registry
from hermes_schedule.policy import section

# hejo-local-v1 x-limits; contract parity is checked against the gate schema.
TEXT_BYTES = 65536
FRAME_BYTES = 1048576
_UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
_ROLES = {
    "reports": ("hejo.channels.reports", "hejo.report_channel"),
    "learning_reports": ("hejo.learning_report_channel",),
    **{name: ("hejo.channels." + name,) for name in
       ("customer_room", "work_room", "instagram", "instagram_digest", "naver_talk")},
    **{name: ("hejo.dms." + name,) for name in ("doctor", "personal")},
}


def root_home(home):
    home = Path(home).resolve()
    return home.parent.parent if home.parent.name == "profiles" else home


def platform(home):
    """The sole reader of delivery.platform. Absence preserves Slack behavior."""
    value = section("delivery", {}, root=root_home(home))
    if not isinstance(value, dict):
        raise ValueError("invalid delivery policy")
    name = value.get("platform", "slack")
    if name not in {"slack", "hejo"}:
        raise ValueError("invalid delivery platform")
    return name


def employee(home):
    home = Path(home).resolve()
    value = home.name if home.parent.name == "profiles" else "default"
    if value not in team_registry.roster():
        raise ValueError("unknown_employee")
    return value


def validate_target(value):
    if not isinstance(value, str) or not value:
        raise ValueError("missing delivery target")
    if value.startswith("room:"):
        if not _UUID.fullmatch(value[5:]):
            raise ValueError("invalid_room")
    elif value not in team_registry.roster():
        raise ValueError("unknown_employee")
    return value


def target(home, role, *, slack, fallback=False):
    """Slack resolution stays with the original caller; hejo never opens a Slack DM."""
    if platform(home) == "slack":
        return slack()
    if role == "owner":
        return employee(home)
    if role not in _ROLES:
        raise ValueError("unknown delivery role")
    for key in _ROLES[role]:
        value = owner_vault.get(key)
        if value is not None:
            return validate_target(value)
    if fallback:
        return employee(home)
    raise ValueError("missing hejo delivery target: " + role)


# Remove vault_backup when H-5 is resolved; slack_session when Slack is disabled.
SLACK_RETAINED_ROUTES = frozenset({"vault_backup", "slack_session"})


def require_slack(home, *, route=None, method=None):
    if route is not None:
        if route not in SLACK_RETAINED_ROUTES:
            raise ValueError("unknown retained Slack route")
        if route == "vault_backup":
            if method not in {"conversations.replies", "chat.update", "chat.postMessage"}:
                raise ValueError("operation outside vault backup route")
        else:
            from gateway.session_context import get_session_env
            from hermes_owner_chat import authenticated_owner
            from hermes_team_services import learning
            if (get_session_env("HERMES_SESSION_PLATFORM", "") != "slack"
                    or not get_session_env("HERMES_SESSION_CHAT_ID", "")
                    or not authenticated_owner(get_session_env, legacy_owner=lambda user: user in learning.owners(home))):
                raise ValueError("current owner Slack conversation required")
        return
    if platform(home) != "slack":
        raise ValueError("Slack write disabled by delivery.platform")


def _field(obj, key, default=None):
    return obj.get(key, default) if isinstance(obj, dict) else getattr(obj, key, default)


def clicked_message_id(event):
    source = _field(event, "source", {})
    name = _field(source, "platform", "")
    name = str(getattr(name, "value", name)).lower()
    button = (_field(event, "raw_message", {}) or {}).get("_hermes_button") or {}
    return str(button.get("message_id" if name == "hejo" else "message_ts") or "")


def thread_key(event):
    """A thread is never inferred from the clicked message, including its first post."""
    return str(_field(_field(event, "source", {}), "thread_id", "") or "")


class Refused(RuntimeError):
    def __init__(self, status, error):
        self.status, self.error = status, error
        super().__init__(f"hejo refused request ({status}): {error}")

    @property
    def permanent(self):
        return 400 <= self.status < 500


class _UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=20)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        try:
            self.sock.connect(self.path)
        except BaseException:
            self.sock.close()
            raise


def request(home, method, path, body):
    """Only the private Unix socket, without redirects or a TCP fallback."""
    conn = _UnixHTTP(root_home(home) / "hejo/post.sock")
    payload = None
    if method == "GET":
        path += "?" + urlencode(body)
    else:
        payload = json.dumps(body, ensure_ascii=False).encode()
        if len(payload) > FRAME_BYTES:
            raise ValueError("invalid_frame")
    try:
        conn.request(method, "/local/v1/" + path, payload,
                     {"Content-Type": "application/json"})
        response = conn.getresponse()
        value = json.loads(response.read())
        if response.status >= 400:
            raise Refused(response.status, value.get("error", "unknown_error"))
        return value
    finally:
        conn.close()


def chunks(text):
    """Split only at Unicode boundaries, preserving the exact text."""
    if not isinstance(text, str):
        raise ValueError("invalid text")
    raw = text.encode("utf-8")
    result = []
    while len(raw) > TEXT_BYTES:
        end = TEXT_BYTES
        while raw[end] & 0xC0 == 0x80:
            end -= 1
        result.append(raw[:end].decode("utf-8"))
        raw = raw[end:]
    return result + [raw.decode("utf-8")]


def presentation(body):
    """Reuse reply marker policy and map display controls to the local contract."""
    from hermes_reply import reply_buttons
    from hermes_team_services import slack_blocks
    text = slack_blocks._guarded(str(body.get("text", "")), body.get("_script_buttons"))
    text, checks = reply_buttons.extract_checklist(text)
    text, labels = slack_blocks._split_buttons(text)
    # Slack notification mentions and thread-address lines have no hejo meaning.
    text = re.sub(r"<@[A-Z0-9]+>", "", text)
    text = "\n".join(line for line in text.split("\n")
                     if not re.search(r"https://[^\s<>]*slack\.com/archives/", line))
    result = {"text": text}
    if labels:
        result["buttons"] = [{"label": label, "style": "default"} for label in labels]
    if checks:
        result["checklist"] = {"items": list(checks), "selected": [],
                               "can_skip": not bool(getattr(checks, "submits", None))}
    bars = body.get("attachments") or []
    blocks = list(body.get("blocks") or []) + [block for bar in bars for block in bar.get("blocks", [])]
    buttons = []
    for block in blocks:
        for element in block.get("elements", []) if block.get("type") == "actions" else []:
            if element.get("type") == "button":
                label = (element.get("text") or {}).get("text")
                if label:
                    buttons.append({"label": label, "style": element.get("style", "default")})
    if buttons and not labels:
        result["buttons"] = buttons
    title = re.match(r"^\*?([🔴🟡🟢🔵])", text.lstrip())
    if title and title[1] != "🔵":
        result["reply_state"] = {"🔴": "asked", "🟡": "answered", "🟢": "closed"}[title[1]]
    elif labels or checks or buttons:
        result["reply_state"] = "asked"
    elif bars:
        color = str(bars[-1].get("color", "")).upper()
        mapped = {"#E01E5A": "asked", "DANGER": "asked", "#ECB22E": "answered", "WARNING": "answered",
                  "#2EB67D": "closed", "GOOD": "closed"}.get(color)
        if mapped:
            result["reply_state"] = mapped
    for key in ("buttons", "checklist", "reply_state", "images"):
        if key in body:
            result[key] = body[key]
    return result


def reset_platform(state, name, save):
    """Only delivery-owned fields are replaced; caller content/occurrence stays put."""
    if state.get("platform", "slack") != name:
        for key in ("channel", "ts", "thread_ts", "msg_id", "head_id", "thread", "pieces",
                    "client_id", "complete", "edit", "controls", "destination"):
            state.pop(key, None)
    state["platform"] = name
    save()


def _scope(home, destination):
    validate_target(destination)
    if destination.startswith("room:"):
        return {"employee": employee(home), "room": destination[5:]}
    return {"employee": destination}


def post(home, destination, text, *, client_id=None, state=None, save=None,
         thread=None, slack=None, **controls):
    """Post one logical message; return separate head/action IDs and thread ID.

    client_id identifies the occurrence, never the content. Retry state must be
    caller-owned and durable. One-shot alerts may omit both state and key.
    """
    name = platform(home)
    if name == "hejo" and state is not None and (not isinstance(client_id, str) or not client_id):
        raise ValueError("retryable delivery requires an occurrence key")
    if state is None:
        if client_id is not None:
            raise ValueError("retryable delivery requires persisted state")
        state, save = {}, lambda: None
    if not callable(save):
        raise ValueError("delivery requires a save callback")
    switched = bool(state) and state.get("platform", "slack") != name
    reset_platform(state, name, save)
    if switched:
        thread = None
    if name == "slack":
        if slack is None:
            raise ValueError("Slack transport missing")
        body = {"channel": destination, "text": text, **controls}
        if thread:
            body["thread_ts"] = thread
        result = slack(home, "chat.postMessage", body)
        state.update(channel=destination, ts=result["ts"], thread_ts=thread or result["ts"])
        save()
        return {"platform": name, "head_id": result["ts"], "msg_id": result["ts"],
                "thread": thread or result["ts"]}
    scope = _scope(home, destination)
    text_parts = chunks(text)
    if "pieces" not in state:
        state["destination"] = destination
        state["client_id"] = client_id
        state["pieces"] = [{"text": part, **({"client_id": f"{client_id}:{index}"}
                            if client_id is not None else {})} for index, part in enumerate(text_parts)]
        state["controls"] = controls
        if thread:
            state["thread"] = thread
        save()
    elif (state["destination"] != destination or [p["text"] for p in state["pieces"]] != text_parts
          or state["controls"] != controls):
        raise ValueError("pending delivery content changed; use edit or a new occurrence")
    for index, piece in enumerate(state["pieces"]):
        payload = {**scope, "text": piece["text"]}
        if piece.get("client_id"):
            payload["client_id"] = piece["client_id"]
        if state.get("thread"):
            payload["thread"] = state["thread"]
        if index == len(state["pieces"]) - 1:
            payload.update(state["controls"])
        result = request(home, "POST", "messages", payload)
        piece["msg_id"] = result["msg_id"]
        state["thread"] = result["thread"]
        save()
    state.update(head_id=state["pieces"][0]["msg_id"], msg_id=state["pieces"][-1]["msg_id"], complete=True)
    save()
    return {key: state[key] for key in ("platform", "head_id", "msg_id", "thread")}


def delete(home, destination, message_id, *, slack=None):
    if platform(home) == "slack":
        return slack(home, "chat.delete", {"channel": destination, "ts": message_id})
    scope = _scope(home, destination)
    return request(home, "DELETE", "messages/" + quote(message_id, safe=""),
                   {"employee": scope["employee"]})


def read_thread(home, destination, thread, *, after=None, slack=None):
    if platform(home) == "slack":
        return slack(home, "conversations.replies", {"channel": destination, "ts": thread})
    scope = _scope(home, destination)
    query = {"room": scope["room"]} if "room" in scope else scope
    if after is not None:
        query["after"] = after
    return request(home, "GET", "threads/" + quote(thread, safe=""), query)


def edit_message(home, destination, message_id, text, *, buttons=None, reply_state=None, slack=None):
    if platform(home) == "slack":
        return slack(home, "chat.update", {"channel": destination, "ts": message_id, "text": text})
    scope = _scope(home, destination)
    if len(text.encode()) > TEXT_BYTES:
        raise ValueError("invalid_frame")
    body = {"employee": scope["employee"], "text": text}
    if buttons is not None:
        body["buttons"] = buttons
    if reply_state is not None:
        body["reply_state"] = reply_state
    return request(home, "PATCH", "messages/" + quote(message_id, safe=""), body)


def edit(home, destination, text, *, state, save, slack=None, **controls):
    """Resize a completed logical post, retaining its thread and durable edit intent.

    Local PATCH cannot move attachments/checklists or clear a reply state. When
    the terminal piece moves, replace that suffix with new keyed posts; earlier
    pieces retain their IDs. The replacement IDs are returned to the caller.
    """
    name = platform(home)
    if state.get("platform", "slack") != name:
        raise ValueError("delivery belongs to another platform; post a new occurrence")
    if name == "slack":
        return slack(home, "chat.update", {"channel": destination, "ts": state["ts"], "text": text})
    _scope(home, destination)
    if destination != state.get("destination") or not state.get("complete"):
        raise ValueError("cannot edit an incomplete delivery or change its destination")
    wanted = chunks(text)
    if "edit" not in state:
        old = state["pieces"]
        keep = min(len(old), len(wanted))
        if len(old) != len(wanted) or any(state["controls"].get(k) != controls.get(k)
                                         for k in ("images", "checklist")):
            keep -= 1
        # Removing a terminal state also needs replacement: PATCH null is invalid.
        if state["controls"].get("reply_state") and not controls.get("reply_state"):
            keep = min(keep, len(wanted) - 1)
        occurrence = uuid.uuid4().hex
        state["edit"] = {"text": text, "controls": controls, "keep": keep,
                         "delete": [p["msg_id"] for p in old[keep:]],
                         "pieces": [{"text": value, **({"msg_id": old[i]["msg_id"],
                            **({"client_id": old[i]["client_id"]} if old[i].get("client_id") else {})}
                            if i < keep else {"client_id": f"edit:{occurrence}:{i}"})}
                                    for i, value in enumerate(wanted)]}
        save()
    plan = state["edit"]
    if plan["text"] != text or plan["controls"] != controls:
        raise ValueError("pending edit content changed")
    # A caller may retry the same in-memory item after its first save failed.
    # Persist the existing plan as well, before any delete/edit/post can happen.
    save()
    for message_id in plan["delete"]:
        delete(home, destination, message_id)
    for index, piece in enumerate(plan["pieces"]):
        last = index == len(plan["pieces"]) - 1
        if index < plan["keep"]:
            edit_message(home, destination, piece["msg_id"], piece["text"],
                         buttons=controls.get("buttons", []) if last else [],
                         reply_state=controls.get("reply_state") if last else None)
        else:
            payload = {**_scope(home, destination), "thread": state["thread"], "text": piece["text"],
                       "client_id": piece["client_id"], **(controls if last else {})}
            result = request(home, "POST", "messages", payload)
            piece["msg_id"] = result["msg_id"]
        save()
    state.update(pieces=plan["pieces"], controls=controls,
                 head_id=plan["pieces"][0]["msg_id"], msg_id=plan["pieces"][-1]["msg_id"])
    del state["edit"]
    save()
    return {key: state[key] for key in ("platform", "head_id", "msg_id", "thread")}
