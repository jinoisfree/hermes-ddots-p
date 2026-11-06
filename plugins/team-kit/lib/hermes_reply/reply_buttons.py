"""Reply buttons for owner reports: a click is the same as typing that reply in the thread.

A message whose last line is ``[[버튼: 라벨1 | 라벨2]]`` loses that line and gets one button per label.
Clicking a button feeds the label back as a message from the clicking user in the report's thread
(``_hermes_force_process``, like reaction triggers), so user authorization, allowed_channels and
every existing approval/review path apply unchanged.

Owner decision (2026-10-23): every question or request to the owner carries buttons and moves
through three colours. Red: asked, waiting for the owner. Yellow: answered (a click or a reply typed
in its thread), the bot is working on it. Green: closed, once this bot's final reply in that thread
goes out without asking again. A follow-up label (``일부만 …``, ``… 수정``, ``보류``) keeps the other
buttons. Reports that track their own state (learning reviews, deadlines, the vault backup)
repaint themselves; a question they re-opened (buttons back, our status line gone) is left alone.
"""
import json
import logging
import os
import re
import time
from pathlib import Path
from copy import deepcopy
from typing import List, Optional, Tuple
from uuid import uuid4

_USAGE_SEPARATOR = "────────────────────"
_USAGE_MARKER = f"{_USAGE_SEPARATOR}\n⏱ "

logger = logging.getLogger(__name__)

ACTION_RE = re.compile(r"^(?:hermes_reply_button_\d+|hermes_reply_checklist_(?:toggle(?:_\d+)?|submit(?:_\d+)?|skip))$")
BLOCK_ID = "hermes_reply_buttons"
CHECKLIST_BLOCK_ID = "hermes_reply_checklist"
CHECKLIST_TOGGLE = "hermes_reply_checklist_toggle"
CHECKLIST_SUBMIT = "hermes_reply_checklist_submit"
CHECKLIST_SKIP = "hermes_reply_checklist_skip"
# Reports may quote both the controls and the usage footer. Keep the footer's
# original quoting, but consume empty quoted lines immediately before controls.
_QUOTE_BLANKS = r"(?:\n[ \t]*>[ \t]*(?=\n))*"
_CONTROL_PREFIX = _QUOTE_BLANKS + r"\n?[ \t]*(?:>[ \t]*)?"
_USAGE_START = r"\n[ \t]*(?:>[ \t]*)?".join(re.escape(line) for line in _USAGE_MARKER.split("\n"))
_FOOTER_TAIL = (r"(?P<footer>\s*(?:>[ \t]*\n\s*)*(?:>[ \t]*)?" + _USAGE_START
                + r"[\s\S]*)?\s*\Z")
_CHECKLIST_MARKER = re.compile(_CONTROL_PREFIX + r"\[\[체크:([^\]\n]*)\]\][ \t]*" + _FOOTER_TAIL)
_MARKER = re.compile(_CONTROL_PREFIX + r"\[\[버튼:([^\]\n]*)\]\][ \t]*" + _FOOTER_TAIL)
MAX_BUTTONS, MAX_LABEL = 5, 30
COLORS = {"need": "#E01E5A", "warn": "#ECB22E", "ok": "#2EB67D"}
WORKING = "⏳ 답변 받음"
STATUS_BLOCK = "hermes_report_status"
FOLLOW_UP = re.compile(r"일부만|수정|보류")
_MARK = re.compile(r"^(\*?)(?:🔴|🟡|🟢|🔵|🟠|⚪|:red_circle:|:large_yellow_circle:|:large_green_circle:|"
                   r":large_blue_circle:|:large_orange_circle:|:white_circle:)\s*")
_KEEP = ("color", "fallback", "blocks", "mrkdwn_in", "text")


# Owner decisions (2026-10-29, 2026-10-31): staff do not invent button wording, and a set of buttons is
# never swapped for another one. ``~/.hermes/shared/reply-buttons.json`` holds the policy:
#   {"policy": "strict", "standard": [...], "contexts": [{"labels": [...], "requires_text": "..."}],
#    "checklists": ["a | b", ...]}
# Strict: a set is buttons only when it is part of ``standard``, or part of a context set whose
# ``requires_text`` is in the message (and not only standard words); a checklist only when listed.
# Without "policy": "strict" the older ``labels``/``patterns`` list applies. Any other set makes no
# buttons and its words stay in the message as text. An unreadable file, or
# HERMES_REPLY_BUTTONS_POLICY=strict without a file, leaves the standard set only. With neither a file
# nor that variable nothing is filtered (the upstream behaviour).
STANDARD_LABELS = ["승인", "거절", "의견", "확인"]
_ALLOWED_CACHE: dict = {}
_REFUSED = "_버튼으로 만들지 않은 선택지: {} — 필요하면 이 스레드에 글로 답해 줘_"


def _allowed_path() -> Path:
    if os.environ.get("HERMES_REPLY_BUTTONS"):
        return Path(os.environ["HERMES_REPLY_BUTTONS"])
    from hermes_constants import get_default_hermes_root
    return get_default_hermes_root() / "shared/reply-buttons.json"


def _strict_minimum() -> dict:
    return {"strict": True, "standard": list(STANDARD_LABELS), "contexts": [], "checklists": [],
            "names": set(STANDARD_LABELS), "patterns": []}


def _allowed() -> Optional[dict]:
    """The policy in force, or None when nothing is filtered."""
    path = _allowed_path()
    forced = os.environ.get("HERMES_REPLY_BUTTONS_POLICY", "").strip().lower() == "strict"
    try:
        stamp = path.stat().st_mtime_ns
    except OSError:
        return _strict_minimum() if forced else None
    if _ALLOWED_CACHE.get("key") != (str(path), stamp, forced):
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
            standard = [str(l) for l in (data.get("standard") or STANDARD_LABELS)]
            contexts = [{"labels": [str(l) for l in c["labels"]], "requires_text": str(c["requires_text"])}
                        for c in data.get("contexts") or [] if c.get("labels") and c.get("requires_text")]
            value = {"strict": forced or data.get("policy") == "strict", "standard": standard,
                     "contexts": contexts, "checklists": [str(c) for c in data.get("checklists") or []],
                     "names": set(standard) | set(data.get("labels") or []),
                     "patterns": [re.compile(p) for p in data.get("patterns") or []]}
        except (OSError, ValueError, TypeError, KeyError, AttributeError, re.error):
            logger.warning("reply buttons: policy file unreadable; standard buttons only")
            value = _strict_minimum()
        _ALLOWED_CACHE.update(key=(str(path), stamp, forced), value=value)
    return _ALLOWED_CACHE["value"]


def allowed_labels(labels: List[str], text: str = "") -> List[str]:
    """``labels`` when the policy lets them be buttons in a message reading ``text``, else []."""
    allow = _allowed()
    if allow is None or not labels:
        return labels
    if len(set(labels)) != len(labels):
        return []
    if allow["strict"]:
        if all(label in allow["standard"] for label in labels):
            return labels
        for context in allow["contexts"]:
            if (all(label in context["labels"] for label in labels) and context["requires_text"] in (text or "")
                    and any(label not in allow["standard"] for label in labels)):
                return labels
        logger.info("reply buttons: %s is not an allowed set; no buttons", labels)
        return []
    kept = [label for label in labels if label in allow["names"] or any(p.fullmatch(label) for p in allow["patterns"])]
    if kept != labels:
        logger.info("reply buttons: unlisted labels %s, no buttons", [l for l in labels if l not in kept])
        return []
    return labels


def _refused(text: str, words: List[str]) -> str:
    return text + "\n" + _REFUSED.format(" · ".join(w for w in words if w) or "선택지 없음")


def extract(content: str) -> Tuple[str, List[str]]:
    """Strip a trailing button marker; return the remaining text and its allowed labels.

    A marker the policy refuses leaves no buttons; its words stay in the text instead."""
    match = _MARKER.search(content or "")
    if not match:
        return content, []
    raw = [label.strip() for label in match.group(1).split("|")]
    labels = list(dict.fromkeys(label for label in raw if label and len(label) <= MAX_LABEL))[:MAX_BUTTONS]
    text = content[:match.start()].rstrip()
    exact = labels == [l for l in raw if l]
    allowed = allowed_labels(labels, text) if exact or _allowed() is None else []
    if not allowed:
        text = _refused(text, raw)
    return text + (match.group("footer") or ""), allowed


class ChecklistLabels(list):
    """List-compatible choices; optional submit labels travel through the existing render paths."""
    def __init__(self, choices, submits):
        super().__init__(choices)
        self.submits = submits


def extract_checklist(content: str) -> Tuple[str, List[str]]:
    """A trailing checklist marker uses the same bounded labels as reply buttons; a strict policy
    only lets its listed checklists through."""
    match = _CHECKLIST_MARKER.search(content or "")
    if not match:
        return content, []
    allow = _allowed()
    if allow is not None and allow["strict"]:
        spaced = " | ".join(part.strip() for part in match.group(1).split("|"))
        if spaced not in allow["checklists"]:
            logger.info("reply buttons: checklist %r is not listed; no checklist", spaced)
            return _refused(content[:match.start()].rstrip(), [p.strip() for p in match.group(1).split("|")]) \
                + (match.group("footer") or ""), []
    raw, separator, submit_raw = match.group(1).partition("| 제출:")
    labels = list(dict.fromkeys(label.strip() for label in raw.split("|")
                               if label.strip() and len(label.strip()) <= MAX_LABEL))[:MAX_BUTTONS]
    if separator:
        submits = list(dict.fromkeys(label.strip() for label in submit_raw.split("|")
                                    if label.strip() and len(label.strip()) <= MAX_LABEL))[:MAX_BUTTONS]
        if not labels or not submits:
            return content, []
        labels = ChecklistLabels(labels, submits)
    return content[:match.start()].rstrip() + (match.group("footer") or ""), labels


def checklist_block(labels: List[str], selected: Optional[set] = None) -> dict:
    selected = selected or set()
    return {"type": "actions", "block_id": CHECKLIST_BLOCK_ID, "elements": [
        {"type": "button", "action_id": f"{CHECKLIST_TOGGLE}_{index}",
         "text": {"type": "plain_text", "text": ("✅ " if label in selected else "☐ ") + label},
         "value": label, **({"style": "primary"} if label in selected else {})}
        for index, label in enumerate(labels)]}


def checklist_blocks(labels: List[str]) -> list:
    submits = getattr(labels, "submits", None)
    if submits:
        return [checklist_block(labels), {"type": "actions", "block_id": CHECKLIST_BLOCK_ID + ":submit",
                "elements": [{"type": "button", "action_id": f"{CHECKLIST_SUBMIT}_{index}",
                              "text": {"type": "plain_text", "text": label}, "value": label}
                             for index, label in enumerate(submits)]}]
    return [checklist_block(labels), {"type": "actions", "block_id": CHECKLIST_BLOCK_ID + ":submit",
            "elements": [{"type": "button", "action_id": CHECKLIST_SUBMIT,
                          "text": {"type": "plain_text", "text": "작성"}, "value": "submit"},
                         {"type": "button", "action_id": CHECKLIST_SKIP,
                          "text": {"type": "plain_text", "text": "건너뛰기"}, "value": "skip"}]}]


def is_checklist(block: dict) -> bool:
    identifier = block.get("block_id") or ""
    return identifier == CHECKLIST_BLOCK_ID or identifier.startswith(CHECKLIST_BLOCK_ID + ":")


def _checklist_controls(message: dict):
    blocks = list(message.get("blocks") or []) + [
        block for attachment in message.get("attachments") or [] for block in attachment.get("blocks") or []]
    for block in blocks:
        if not is_checklist(block):
            continue
        legacy = next((e for e in block.get("elements") or [] if e.get("action_id") == CHECKLIST_TOGGLE), None)
        toggles = [e for e in block.get("elements") or []
                   if re.fullmatch(CHECKLIST_TOGGLE + r"_\d+", e.get("action_id", ""))]
        if legacy or toggles:
            yield block, legacy, toggles


def master_selection(choices: List[str], previous: set, picked: set) -> set:
    """A first '전체' option mirrors its children; compare the single Slack toggle to its baseline."""
    picked = picked.intersection(choices)
    if len(choices) < 2 or choices[0] != "전체":
        return picked
    children = set(choices[1:])
    if "전체" in picked and "전체" not in previous:
        return set(choices)
    if "전체" in previous and "전체" not in picked:
        return set()
    return picked | {"전체"} if children.issubset(picked) else picked - {"전체"}


def checklist_update(body: dict, action: dict) -> Optional[dict]:
    """Redraw the same message with new initial options and a fresh block identity for Slack's state."""
    original = body.get("message") or {}
    message = deepcopy({"text": original.get("text") or " ", "blocks": original.get("blocks") or [],
                        "attachments": [{k: v for k, v in a.items() if k in _KEEP}
                                        for a in original.get("attachments") or []]})
    for block, control, toggles in _checklist_controls(message):
        if action.get("block_id") and action["block_id"] != block["block_id"]:
            continue
        if control:
            if "selected_options" not in action:
                return None
            options = control.get("options") or []
            choices = [option["value"] for option in options]
            if len(choices) < 2 or choices[0] != "전체":
                return None  # Old independent checkboxes keep their native client-side state.
            previous = {o.get("value") for o in control.get("initial_options") or []}
            picked = {o.get("value") for o in action.get("selected_options") or []}
            selected = master_selection(choices, previous, picked)
            control["initial_options"] = [option for option in options if option["value"] in selected]
            if not selected:
                control.pop("initial_options", None)
        else:
            choices = [e["value"] for e in toggles]
            clicked = next((e for e in toggles if e['action_id'] == action.get('action_id')
                            and e['value'] == action.get('value')), None)
            if clicked is None:
                return None
            previous = {e['value'] for e in toggles if e.get('style') == 'primary'}
            picked = previous.symmetric_difference({clicked['value']})
            block['elements'] = checklist_block(choices, master_selection(choices, previous, picked))['elements']
        block["block_id"] = CHECKLIST_BLOCK_ID + ":" + uuid4().hex[:12]
        return message
    return None


def checklist_reply(body: dict, submit_label: Optional[str] = None) -> Optional[str]:
    """Use rendered order/state, including old native checkboxes, without trusting unoffered values."""
    for block, control, toggles in _checklist_controls(body.get("message") or {}):
        if control:
            choices = [option["value"] for option in control.get("options") or []]
            state = ((body.get("state") or {}).get("values") or {}).get(block["block_id"], {}).get(CHECKLIST_TOGGLE, {})
            picked = {option.get("value") for option in state.get("selected_options", control.get("initial_options")) or []}
        else:
            choices = [e['value'] for e in toggles]
            picked = {e['value'] for e in toggles if e.get('style') == 'primary'}
        selected = [label for label in choices if label in picked]
        if submit_label is not None:
            # A neutral confirm submits only the checks; with no checks it is a skip.
            selected = ([] if submit_label == "확인" else [submit_label]) + selected
            return "선택: " + ", ".join(selected) if selected else "건너뛰기"
        if selected:
            return "선택: " + ("전체" if "전체" in selected else ", ".join(selected))
    return None


def actions_block(labels: List[str]) -> dict:
    return {"type": "actions", "block_id": BLOCK_ID, "elements": [
        {"type": "button", "action_id": f"hermes_reply_button_{index}",
         "text": {"type": "plain_text", "text": label, "emoji": True}, "value": label}
        for index, label in enumerate(labels)]}


# Owner decision 2026-10-31: a report reads title, summary, what to do, the buttons, then the details.
# The marker still travels as the last line; the buttons are placed after the section headed by one of
# these words, before the next heading. A message without such a section keeps its buttons last.
ACTION_HEADINGS = re.compile(r"^(?:소유자가\s*)?(?:할\s*일|검토할\s*일|결정\s*필요)\b")


def block_heading(block: dict) -> Optional[str]:
    """The bold heading a block starts with, if it is one (a ``*name*`` line or a bold rich-text start)."""
    if not isinstance(block, dict):
        return None
    if block.get("type") == "section":
        first = str((block.get("text") or {}).get("text") or "").split("\n", 1)[0].strip()
        match = re.fullmatch(r"\*([^*\n]+)\*", first)
        return match[1].strip() if match else None
    if block.get("type") == "rich_text":
        for part in block.get("elements") or []:
            if part.get("type") != "rich_text_section":
                return None
            first = (part.get("elements") or [{}])[0]
            if first.get("type") == "text" and (first.get("style") or {}).get("bold"):
                return str(first.get("text") or "").split("\n", 1)[0].strip() or None
            return None
    return None


def place_controls(blocks: list, controls: list) -> list:
    """``blocks`` with ``controls`` after the what-to-do section, or at the end when there is none."""
    blocks = list(blocks)
    for i, block in enumerate(blocks):
        name = block_heading(block)
        if name and ACTION_HEADINGS.match(name):
            for j in range(i + 1, len(blocks)):
                if block_heading(blocks[j]):
                    return blocks[:j] + controls + blocks[j:]
            break
    return blocks + controls


def with_buttons(blocks: Optional[list], text: str, labels: List[str], *, checklist: bool = False) -> Optional[list]:
    """Add the buttons after the what-to-do section (else last); plain-text messages get a section first."""
    if not labels:
        return blocks
    base = list(blocks) if blocks else [{"type": "section", "text": {"type": "mrkdwn", "text": text[:3000]}}]
    controls = checklist_blocks(labels) if checklist else [actions_block(labels)]
    if len(base) + len(controls) > 50:
        return blocks
    return place_controls(base, controls)


def _pressed_text(message: dict) -> str:
    """The pressed post's words: Slack's ``text`` (the whole body we posted), else its Block Kit sections."""
    text = str(message.get("text") or "").strip()
    if text:
        return text
    blocks = list(message.get("blocks") or []) + [
        b for a in message.get("attachments") or [] for b in a.get("blocks") or []]
    return "\n".join(str((b.get("text") or {}).get("text") or "") for b in blocks
                     if b.get("type") == "section" and isinstance(b.get("text"), dict)).strip()


def synthetic_event(body: dict, action: dict) -> Optional[dict]:
    """Message-shaped event for a click: the clicking user 'types' the label in the report thread."""
    user = (body.get("user") or {}).get("id")
    channel = (body.get("channel") or {}).get("id") or (body.get("container") or {}).get("channel_id")
    message = body.get("message") or {}
    root = message.get("thread_ts") or message.get("ts") or (body.get("container") or {}).get("message_ts")
    custom_submit = re.fullmatch(CHECKLIST_SUBMIT + r"_\d+", action.get("action_id", ""))
    if custom_submit:
        blocks = list(message.get("blocks") or []) + [
            b for a in message.get("attachments") or [] for b in a.get("blocks") or []]
        offered = any(is_checklist(b) and b.get("block_id") == CHECKLIST_BLOCK_ID + ":submit"
                      and any(e.get("action_id") == action["action_id"] and e.get("value") == action.get("value")
                              for e in b.get("elements") or []) for b in blocks)
        if not offered:
            return None
    label = ("건너뛰기" if action.get("action_id") == CHECKLIST_SKIP else
             checklist_reply(body, action.get("value")) if custom_submit else
             checklist_reply(body) if action.get("action_id") == CHECKLIST_SUBMIT else action.get("value") or "")
    if not (user and channel and root and label):
        return None
    event = {"type": "message", "user": user, "text": label, "channel": channel,
             "channel_type": "im" if channel.startswith("D") else "channel",
             "ts": str(action.get("action_ts") or body.get("action_ts") or f"button-{root}-{label}"),
             "thread_ts": root, "_hermes_force_process": True,
             "_hermes_button": {"label": label, "message_ts": message.get("ts"),
                                "message_text": _pressed_text(message)}}
    team = (body.get("team") or {}).get("id") or (body.get("user") or {}).get("team_id")
    if team:
        event["team"] = team
    return event


_CLICKED_HEAD = 2500
_CLICKED_TAIL = 1500


def clicked_context(button) -> str:
    """The turn's leading context for a click: which message the owner pressed, so the agent handles that
    item only. Same ``[Thread context …]`` shape the gateway uses for thread history, so every reader of
    a turn's first lines (mail legend, current-message split on ``[New message]``) treats it the same way.
    A long post keeps its start and its end (the mail legend sits at the end)."""
    text = str((button or {}).get("message_text") or "").strip()
    ts = (button or {}).get("message_ts")
    if not (text and ts):
        return ""
    if len(text) > _CLICKED_HEAD + _CLICKED_TAIL:
        text = text[:_CLICKED_HEAD].rstrip() + "\n…(중략)…\n" + text[-_CLICKED_TAIL:].lstrip()
    return ("[Thread context — the message the owner just pressed a button on (Slack ts " + str(ts) + "). "
            "The click answers only this message's item; other messages in the thread are other items:]\n"
            "[pressed message] " + text + "\n[End of thread context]\n\n")


def _section(text: str) -> dict:
    return {"type": "section", "text": {"type": "mrkdwn", "text": (text or " ")[:3000]}}


def question_layout(blocks: Optional[list], attachments: Optional[list], text: str,
                    labels: List[str], *, checklist: bool = False) -> Tuple[Optional[list], Optional[list]]:
    """A message with buttons is a question: its body sits under a red bar, buttons last."""
    if not labels:
        return blocks, attachments
    if attachments:
        bars = [{**a, "color": COLORS["need"]} for a in attachments]
        bars[-1] = {**bars[-1], "blocks": with_buttons(bars[-1].get("blocks"), text, labels, checklist=checklist)}
        return blocks, bars
    base = list(blocks) if blocks else [_section(text)]
    # Slack prints ``text`` when there are no top-level blocks, so one block stays above the bar.
    head, body = base[:1], base[1:]
    return head, [{"color": COLORS["need"], "blocks": with_buttons(body, text, labels, checklist=checklist) if body
                   else checklist_blocks(labels) if checklist else [actions_block(labels)]}]


def has_buttons(message: dict) -> bool:
    blocks = list(message.get("blocks") or []) + [
        b for a in message.get("attachments") or [] for b in a.get("blocks") or []]
    return any(b.get("block_id") == BLOCK_ID or is_checklist(b) for b in blocks)


def _restage(message: dict, colour: str, mark: str, line: str, *, keep: Optional[str] = None) -> dict:
    """chat.update fields: one bar in ``colour``, title mark, one status line. Buttons go, except
    the others beside ``keep`` (the clicked follow-up button's action id)."""
    def clean(blocks):
        out = []
        for block in blocks or []:
            if block.get("block_id") == STATUS_BLOCK:
                continue
            if is_checklist(block):
                continue
            if block.get("block_id") == BLOCK_ID:
                elements = [e for e in block.get("elements", []) if e.get("action_id") != keep]
                if keep and elements:
                    out.append({**block, "elements": elements})
                continue
            if block.get("type") == "context" and "👆" in str(block.get("elements")):
                continue
            out.append(block)
        return out

    status = {"type": "context", "block_id": STATUS_BLOCK, "elements": [{"type": "mrkdwn", "text": line}]}
    blocks = clean(message.get("blocks"))
    for i, block in enumerate(blocks):
        heading = (block.get("text") or {}).get("text") if block.get("type") == "header" else None
        if isinstance(heading, str) and _MARK.match(heading):
            blocks[i] = {**block, "text": {**block["text"], "text": _MARK.sub(mark + " ", heading, count=1)}}
    text = _MARK.sub(lambda m: m[1] + mark + " ", message.get("text") or " ", count=1)
    bars = [{k: v for k, v in a.items() if k in _KEEP} for a in message.get("attachments") or []]
    if not bars:
        blocks, bars = blocks[:1], [{"blocks": blocks[1:]}]
    for bar in bars:
        bar["color"] = colour
        bar["blocks"] = clean(bar.get("blocks"))
    bars[-1]["blocks"] = bars[-1]["blocks"][:49] + [status]
    return {"text": text, "blocks": blocks, "attachments": bars}


def _clock(now: Optional[float]) -> str:
    return time.strftime("%H:%M", time.localtime(time.time() if now is None else now)) + " KST"


def answered_message(message: dict, user: str, label: Optional[str] = None,
                     action_id: Optional[str] = None, now: Optional[float] = None) -> dict:
    """The owner answered: yellow, buttons gone (a follow-up label keeps the other buttons)."""
    follow = bool(label and FOLLOW_UP.search(label))
    said = f" `{label}`" if label else ""
    line = f"{WORKING} · <@{user}>{said} · {_clock(now)} · 처리 중"
    return _restage(message, COLORS["warn"], "🟡", line, keep=action_id if follow else None)


def is_working(message: dict) -> bool:
    """Still in our yellow 'answered, working' state: our status line and no buttons."""
    blocks = list(message.get("blocks") or []) + [
        b for a in message.get("attachments") or [] for b in a.get("blocks") or []]
    return not has_buttons(message) and any(
        b.get("block_id") == STATUS_BLOCK and any(
            "답변 받음" in e.get("text", "") for e in b.get("elements") or []) for b in blocks)


def closed_message(message: dict, now: Optional[float] = None) -> dict:
    return _restage(message, COLORS["ok"], "🟢", f"✅ 처리 완료 · 종결 · {_clock(now)}")


_CHECKED_MAX = 2000


def _message_state(adapter, channel_id, ts):
    import asyncio
    from collections import OrderedDict

    states = getattr(adapter, "_hermes_reply_states", None)
    if states is None:
        states = adapter._hermes_reply_states = OrderedDict()
    key = (channel_id, ts)
    state = states.setdefault(key, {"lock": asyncio.Lock(), "answered": False})
    states.move_to_end(key)
    while len(states) > _CHECKED_MAX:
        states.popitem(last=False)
    return state


async def preserve_answered_edit(adapter, call, payload):
    """Serialize final/stream edits with clicks; an answered message is no longer a draft."""
    state = _message_state(adapter, payload["channel"], payload["ts"])
    async with state["lock"]:
        if state["answered"]:
            return {"ok": True, "ts": payload["ts"], "_hermes_answered": True}
        return await call(payload)


_SHORT_FALLBACK = 300


def _short_fallback(text: str) -> str:
    """Notification fallback only: the blocks still carry the whole question."""
    line = next((l for l in (text or "").splitlines() if l.strip()), " ")
    return line[:_SHORT_FALLBACK]


async def _update_status(adapter, client, channel_id, ts, fields):
    """chat.update is idempotent; retry once without logging message bodies or tokens.
    chat.update refuses long Korean ``text`` that postMessage accepted (msg_too_long), so that
    retry sends a short fallback instead of the same payload."""
    import asyncio

    state = _message_state(adapter, channel_id, ts)
    async with state["lock"]:
        # Reserve the answered state even if Slack is temporarily unavailable: a late
        # final edit must not restore the old question while the answer is processed.
        state["answered"] = True
        for attempt in range(2):
            try:
                return await client.chat_update(channel=channel_id, ts=ts, **fields)
            except Exception as exc:
                response = getattr(exc, "response", None)
                code = response.get("error") if response is not None else None
                code = code if isinstance(code, str) and re.fullmatch(r"[a-z_]+", code) else "unknown"
                logger.warning("[Slack] question %s update failed (%s, api_error=%s, attempt=%s/2)",
                               ts, type(exc).__name__, code, attempt + 1)
                if attempt:
                    raise
                if code == "msg_too_long":
                    fields = {**fields, "text": _short_fallback(fields.get("text", ""))}
                else:
                    await asyncio.sleep(0.2)


def remember_question(adapter, channel_id: str, team_id: str, thread_ts: str, ts: str) -> None:
    """A question this bot asked inside a thread; a typed answer there turns it yellow."""
    from collections import OrderedDict

    open_ = getattr(adapter, "_hermes_open_questions", None)
    if open_ is None:
        open_ = adapter._hermes_open_questions = OrderedDict()
    open_.setdefault((team_id, channel_id, thread_ts), []).append(ts)
    while len(open_) > _CHECKED_MAX:
        open_.popitem(last=False)


def remember_working(adapter, team_id: str, channel_id: str, thread_ts: str, ts: str) -> None:
    """An answered question (yellow) this bot will close when its final reply in the thread goes out."""
    from collections import OrderedDict

    working = getattr(adapter, "_hermes_working", None)
    if working is None:
        working = adapter._hermes_working = OrderedDict()
    held = working.setdefault((channel_id, thread_ts), [])  # team ids differ by path; channels do not
    if ts not in held:
        held.append(ts)
    while len(working) > _CHECKED_MAX:
        working.popitem(last=False)


def close_working(adapter, *, channel_id: str, team_id: str, thread_ts: Optional[str]) -> None:
    """This bot's final reply in a thread: its answered questions there turn green (background)."""
    import asyncio

    working = getattr(adapter, "_hermes_working", None)
    targets = working.pop((channel_id, thread_ts), []) if working and thread_ts else []
    if not targets:
        return

    async def repaint():
        client = adapter._get_client(channel_id, team_id=team_id)
        for ts in targets:
            try:
                data = await client.conversations_replies(channel=channel_id, ts=thread_ts, oldest=ts,
                                                          inclusive=True, limit=2)
                message = next((m for m in data.get("messages") or [] if m.get("ts") == ts), None)
                # A report that re-drew itself (buttons back, its own status) keeps its own colour.
                if not message or not is_working(message):
                    continue
                await _update_status(adapter, client, channel_id, ts, closed_message(message))
                logger.info("[Slack] question %s in %s closed after the reply; marked green", ts, channel_id)
            except Exception as exc:
                logger.warning("[Slack] could not close question %s (%s)", ts, type(exc).__name__)

    try:
        asyncio.get_running_loop().create_task(repaint())
    except RuntimeError:
        pass


def note_typed_answer(adapter, *, channel_id: str, team_id: str, root_ts: str, user_id: str,
                      bot_uid: Optional[str]) -> None:
    """A human reply in a thread turns this bot's open questions there yellow: the thread's first
    post (checked once) and any question it asked inside the thread. Runs in the background."""
    import asyncio
    from collections import OrderedDict

    if not (root_ts and bot_uid):
        return
    checked = getattr(adapter, "_hermes_answered_roots", None)
    if checked is None:
        checked = adapter._hermes_answered_roots = OrderedDict()
    key = (team_id, channel_id, root_ts)
    targets = list((getattr(adapter, "_hermes_open_questions", None) or {}).pop(key, []))
    if key not in checked:
        checked[key] = True
        targets.insert(0, root_ts)
        while len(checked) > _CHECKED_MAX:
            checked.popitem(last=False)
    if not targets:
        return

    async def repaint():
        client = adapter._get_client(channel_id, team_id=team_id)
        for ts in targets:
            try:
                data = await client.conversations_replies(channel=channel_id, ts=root_ts, oldest=ts,
                                                          inclusive=True, limit=2)
                message = next((m for m in data.get("messages") or [] if m.get("ts") == ts), None)
                if not message or message.get("user") != bot_uid or not has_buttons(message):
                    continue
                await _update_status(adapter, client, channel_id, ts, answered_message(message, user_id))
                remember_working(adapter, team_id, channel_id, root_ts, ts)
                logger.info("[Slack] question %s in %s answered by %s; marked yellow", ts, channel_id, user_id)
            except Exception as exc:
                if ts == root_ts:
                    checked.pop(key, None)
                logger.warning("[Slack] could not mark question %s answered (%s)", ts, type(exc).__name__)

    try:
        asyncio.get_running_loop().create_task(repaint())
    except RuntimeError:
        checked.pop(key, None)


# ddots answers a button post by sending the owner's label with this block id (``hermes_click:<ts>`` of the
# post it pressed); the block shows as the label and is invisible otherwise. A Slack click carries the
# pressed message in its payload; this is the same click arriving as an ordinary message event.
CLICK_BLOCK_PREFIX = "hermes_click:"


def click_target(event: dict) -> Optional[str]:
    for block in (event or {}).get("blocks") or []:
        block_id = str(block.get("block_id") or "") if isinstance(block, dict) else ""
        if block_id.startswith(CLICK_BLOCK_PREFIX) and block_id[len(CLICK_BLOCK_PREFIX):]:
            return block_id[len(CLICK_BLOCK_PREFIX):]
    return None


def _buttons_of(message: dict) -> List[dict]:
    blocks = list(message.get("blocks") or []) + [
        b for a in message.get("attachments") or [] for b in a.get("blocks") or []]
    return [e for b in blocks if b.get("block_id") == BLOCK_ID for e in b.get("elements") or []
            if e.get("type") == "button" and ACTION_RE.fullmatch(e.get("action_id", ""))]


def _sender_allowed(adapter, user: str, channel: str) -> bool:
    """True only when the adapter's own authorization chain says yes (injected profile check, then the
    runner's). No answer is not a yes: an unknown sender's message stays an ordinary message."""
    chat_type = "dm" if channel.startswith("D") else "group"
    decision = None
    if getattr(adapter, "_authorization_check", None) is not None:
        decision = adapter._is_sender_authorized(user, chat_type, channel)
    auth_fn = adapter._runner_auth_fn()
    if decision is None and callable(auth_fn):
        source = adapter.build_source(chat_id=channel, chat_name="", chat_type=chat_type, user_id=user, user_name="")
        decision = bool(auth_fn(source))
    return decision is True


async def adopt_click(adapter, event: dict) -> dict:
    """An owner message that names a button post and says one of that post's labels is a click on it:
    the event becomes the same synthetic click ``synthetic_event`` builds (label as text, pressed message
    in ``_hermes_button``), and the pressed post turns yellow. Anything else (a stale click, a sender not
    confirmed as allowed, an unknown bot id) comes back unchanged and is an ordinary message."""
    ts = click_target(event)
    user, channel, root = event.get("user"), event.get("channel"), event.get("thread_ts")
    label = str(event.get("text") or "").strip()
    if not (ts and user and channel and root and root != event.get("ts") and label):
        return event
    team = str(event.get("team") or event.get("team_id") or "")
    try:
        if not _sender_allowed(adapter, user, channel):
            return event
        bot = adapter._team_bot_user_ids.get(team, adapter._bot_user_id)
        if not bot:
            return event
        client = adapter._get_client(channel, team_id=team)
        data = await client.conversations_replies(channel=channel, ts=root, oldest=ts, inclusive=True, limit=2)
        message = next((m for m in data.get("messages") or [] if m.get("ts") == ts), None)
        pressed = next((e for e in _buttons_of(message or {}) if e.get("value") == label), None)
        if not message or not pressed or message.get("user") != bot:
            return event
        await _update_status(adapter, client, channel, ts, answered_message(message, user, label, pressed["action_id"]))
        remember_working(adapter, team, channel, root, ts)
        logger.info("[Slack] question %s in %s answered from ddots; marked yellow", ts, channel)
    except Exception as exc:
        logger.warning("[Slack] ddots click not adopted (%s)", type(exc).__name__)
        return event
    clicked = {k: v for k, v in event.items() if k != "blocks"}
    clicked.update(text=label, _hermes_force_process=True,
                   _hermes_button={"label": label, "message_ts": ts, "message_text": _pressed_text(message)})
    return clicked


def register(adapter, app) -> None:
    """Wire the click handler once per ``AsyncApp`` (a second listener would run each click twice)."""
    if getattr(app, "_hermes_reply_buttons", False):
        return
    app._hermes_reply_buttons = True

    async def handle(ack, body, action):
        await ack()
        try:
            if re.fullmatch(CHECKLIST_TOGGLE + r"(?:_\d+)?", (action or {}).get("action_id", "")):
                event = synthetic_event(body or {}, {"value": "checklist-toggle"})
                if not event or adapter._early_reject_unauthorized(event["user"], event["channel"], event["channel"].startswith("D")):
                    return
                fields = checklist_update(body or {}, action)
                message = (body or {}).get("message") or {}
                if fields and message.get("ts"):
                    client = adapter._get_client(event["channel"], team_id=event.get("team", ""))
                    await client.chat_update(channel=event["channel"], ts=message["ts"], **fields)
                return
            event = synthetic_event(body or {}, action or {})
            if event is None:
                logger.warning("[Slack] reply button: click without user/channel/message/label ignored")
                return
            logger.info("[Slack] reply button %r clicked by %s in %s (thread %s)",
                        event["text"], event["user"], event["channel"], event["thread_ts"])
            if adapter._early_reject_unauthorized(event["user"], event["channel"], event["channel"].startswith("D")):
                return
            message = (body or {}).get("message") or {}
            if message.get("ts"):
                try:
                    client = adapter._get_client(event["channel"], team_id=event.get("team", ""))
                    await _update_status(adapter, client, event["channel"], message["ts"],
                                         answered_message(message, event["user"], event["text"],
                                                          action.get("action_id")))
                    remember_working(adapter, event.get("team", ""), event["channel"], event["thread_ts"],
                                     message["ts"])
                    logger.info("[Slack] question %s in %s answered by click; marked yellow",
                                message["ts"], event["channel"])
                except Exception as exc:
                    logger.warning("[Slack] reply button: could not mark the click (%s)", type(exc).__name__)
            await adapter._handle_slack_message(event)
        except Exception:
            logger.warning("[Slack] reply button handling failed", exc_info=True)

    app.action(ACTION_RE)(handle)
    logger.info("[Slack] reply buttons wired")
