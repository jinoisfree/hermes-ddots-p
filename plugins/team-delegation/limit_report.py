"""Record one unfinished assistant request for system-doctor's silent night batch."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from typing import Any, Callable

FIELDS = {
    "undone": "What was not done, separated from what was done.",
    "reason": "Why, grounded in the error or refusal text actually seen; mark an unverified cause as a guess.",
    "user_can": "What the user can do right now to make it possible; say there is nothing when there is nothing.",
    "system_fix": "What has to change in the system to make it possible; say there is nothing when there is nothing.",
    "tools": ("The tool this needs: only names seen in your tool list or in the error/refusal text, otherwise "
              "describe the missing ability without inventing a name; say so when it is a permission, login, "
              "or setting problem rather than a missing tool."),
}
FIELD_CHARS = 1000
SCHEMA = {
    "name": "limit_report",
    "description": ("Record an unfinished request once in 진단담당 새벽 처리 대기열 with five required fields. "
                    "No Slack report is sent. Reply briefly with only what remains undone and why; "
                    "do not show the five-field form or report guidance. Never retry failed or uncertain recording."),
    "parameters": {
        "type": "object",
        "properties": {name: {"type": "string", "minLength": 1, "maxLength": FIELD_CHARS, "description": text} for name, text in FIELDS.items()},
        "required": list(FIELDS),
        "additionalProperties": False,
    },
}
NUDGE = (
    "[Unfinished work] In this request these tool calls ended in a failure: {tools}. If the request ends up "
    "not done or only partly done, use limit_report to 진단담당 새벽 처리 대기열에 한 번 기록. "
    "Reply briefly with only the unfinished scope and reason; do not post a report or repeat the five fields. "
    "If a retry or another way finished it, do not report."
)


INSTRUCTION = '답변에는 못한 범위와 이유만 짧게 말하고 다섯 항목 양식이나 보고 안내는 쓰지 않는다.'


def record(fields, **origin):
    spec = importlib.util.spec_from_file_location(
        'assistant_limit_records', Path(__file__).parents[1] / 'team-kit/diagnosis_requests.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.limit_record(fields, **origin)


def call(args: dict[str, Any], *, chat_id: str, thread_ts: str, owner: str, recorder=None) -> str:
    def failure(message: str) -> str:
        return json.dumps({'status': 'failed', 'recorded': False, 'error': message,
                           'instruction': '재시도하지 않는다. ' + INSTRUCTION}, ensure_ascii=False)

    if not isinstance(args, dict) or set(args) != set(FIELDS):
        return failure('Exactly these arguments are required: ' + ', '.join(FIELDS))
    if any(not isinstance(args[name], str) or not 1 <= len(args[name].strip()) <= FIELD_CHARS for name in FIELDS):
        return failure(f'Every field must contain 1–{FIELD_CHARS} characters')
    try:
        result = (recorder or record)({name: args[name].strip() for name in FIELDS},
                                      chat_id=chat_id, thread_ts=thread_ts, owner=owner)
        if (not isinstance(result, dict) or result.get('ok') is not True or
                result.get('status') != 'deferred' or not result.get('request_id') or result.get('error')):
            return failure('Limit recording was not confirmed')
    except Exception:
        return failure('Limit recording raised an exception')
    return json.dumps({'status': 'ok', 'recorded': True,
                       'instruction': '보고 채널에 올리지 않았다. ' + INSTRUCTION}, ensure_ascii=False)


def _failed(texts: list[str]) -> bool:
    """A tool result that says of itself that it failed: this plugin's and the core's error objects."""
    for text in texts:
        try:
            result = json.loads(text)
        except (TypeError, ValueError):
            continue
        if not isinstance(result, dict):
            continue
        if result.get("ok") is False or result.get("success") is False or result.get("status") == "failed":
            return True
        if result.get("error") and result.get("ok") is not True and result.get("success") is not True:
            return True
    return False


def nudge(messages: Any, strings: Callable[[Any], list[str]]) -> str:
    """The reminder for a request whose tools failed since the user last spoke, or "" when none applies.

    A tool counts by its last result, so a retry that worked clears it. Once limit_report was called
    in the same stretch there is nothing left to remind of. Anything unreadable ends in ""."""
    try:
        if not isinstance(messages, list):
            return ""
        start = max((index for index, message in enumerate(messages)
                     if isinstance(message, dict) and message.get("role") == "user"), default=-1)
        names: dict[str, str] = {}
        failed: dict[str, bool] = {}
        for message in messages[start + 1:]:
            if not isinstance(message, dict):
                continue
            if message.get("role") == "assistant":
                for made in message.get("tool_calls") or []:
                    function = made.get("function") if isinstance(made, dict) else None
                    if not isinstance(function, dict):
                        continue
                    name = str(function.get("name") or "")
                    if name == "limit_report":
                        return ""
                    if made.get("id"):
                        names[str(made["id"])] = name
            elif message.get("role") == "tool":
                name = names.get(str(message.get("tool_call_id") or ""), "")
                if name:
                    failed[name] = _failed(strings(message.get("content")))
        tools = sorted(name for name, bad in failed.items() if bad)
        return NUDGE.format(tools=", ".join(tools)) if tools else ""
    except Exception:
        return ""
