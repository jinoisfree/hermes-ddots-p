"""Zero-model approval for the configured vault backup that the daily wiki job asks about.

The daily job (``02_etc/scripts/wiki_daily.py`` in the vault) posts a Slack message and
records it in ``PENDING_PATH``. A reply in that message's thread approves or skips the
backup; only then is the vault committed and pushed. A bare top-level ``승인``/``거절`` in
the same DM counts only while the question is still the latest thing there: any other
top-level message first marks it ``thread_only``, so an answer meant for a later approval
is never taken. Naming the backup (``백업 승인``) works at top level any time.
"""

from __future__ import annotations

import contextlib
import asyncio
import json
import logging
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Optional


# The wiki producer writes a root-owned pending record outside profile state.
PYTHON = "/usr/bin/python3"
SCRIPT_REL = Path("02_etc/scripts/wiki_daily.py")
MAX_AGE_SECONDS = 36 * 3600
BACKUP_TIMEOUT_SECONDS = 900

_APPROVE = r"(?:승인(?:한다|합니다|해|할게)?|해(?:줘)?|하자|진행(?:해|해줘)?|백업(?:해|해줘)?|ㅇㅇ|ㄱㄱ|ok|okay|yes)"
_REJECT = r"(?:(?:거절|거부)(?:한다|합니다|해)?|취소(?:해|해줘)?|건너뛰어|하지\s*마|ㄴㄴ|no)"


from pathlib import Path as _AtomicPath
import sys as _atomic_sys
if str(_AtomicPath(__file__).resolve().parents[1]) not in _atomic_sys.path:
    _atomic_sys.path.insert(0, str(_AtomicPath(__file__).resolve().parents[1]))
from hermes_facility import atomic as _atomic


def _normalized(text: str) -> str:
    value = re.sub(r"<@[^>]+>", " ", str(text or ""))
    value = re.sub(r"[.!…~]+$", "", value.strip())
    return re.sub(r"\s+", " ", value).lower()


def classify_reply(text: str, *, in_thread: bool) -> Optional[str]:
    """``"approve"`` / ``"reject"`` / None. Outside the thread the word 백업 is required.
    A question (``승인?``) is never an answer."""
    if re.search(r"[?？]", str(text or "")):
        return None
    value = _normalized(text)
    prefix = r"(?:(?:볼트\s*)?백업\s*)?" if in_thread else r"(?:볼트\s*)?백업\s*"
    if re.fullmatch(prefix + _APPROVE, value) or (not in_thread and value in {"백업", "볼트 백업"}):
        return "approve"
    if re.fullmatch(prefix + _REJECT, value):
        return "reject"
    return None


def _load_pending(path: Path, now: float) -> Optional[dict[str, Any]]:
    try:
        pending = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    try:
        if not isinstance(pending, dict) or now - float(pending.get("created_at") or 0) > MAX_AGE_SECONDS:
            return None
    except (TypeError, ValueError, OverflowError):
        return None
    return pending


def _write_pending(path: Path, pending: dict[str, Any]) -> None:
    _atomic.write_json(path, pending, indent=2, newline=False)


def _run_backup(vault: Path, run: Callable[..., Any]) -> dict[str, Any]:
    """The backup's result; OK only for exit 0 with a JSON object whose status is OK."""
    script = vault / SCRIPT_REL
    if not script.is_file():
        return {"status": "FAIL", "error": f"backup script not found: {script}"}
    completed = run(
        [PYTHON, str(script), "--backup-only", "--vault", str(vault)],
        cwd=str(vault), capture_output=True, text=True, timeout=BACKUP_TIMEOUT_SECONDS,
    )
    stdout, stderr = str(completed.stdout or ""), str(completed.stderr or "")
    start = stdout.find("{")
    try:
        result = json.loads(stdout[start:]) if start >= 0 else None
    except ValueError:
        result = None
    if not isinstance(result, dict):
        return {"status": "FAIL", "error": (stderr or stdout)[-300:] or "no result from the backup"}
    if completed.returncode != 0:
        detail = result.get("error") or stderr[-300:] or stdout[-300:]
        return {"status": "FAIL", "error": f"exit {completed.returncode}: {detail}"}
    return result


def _pid_alive(pid: Any) -> bool:
    from gateway.status import _pid_exists
    try:
        value = int(pid)
        return value > 0 and _pid_exists(value)
    except (OSError, TypeError, ValueError, OverflowError):
        return False


def _running_claim(claimed: Path, path: Path, now: float) -> Optional[dict[str, Any]]:
    """The in-flight claim while its backup can still be running, else None.

    A claim whose owner died (gateway restarted mid-backup) or outlived the backup timeout is
    turned back into an open question, so the next 승인 retries instead of vanishing."""
    try:
        claim = json.loads(claimed.read_text(encoding="utf-8-sig"))
        started = float(claim.get("running_since") or claimed.stat().st_mtime)
    except (OSError, ValueError, AttributeError):
        return None
    if _pid_alive(claim.get("running_pid")) and now - started <= BACKUP_TIMEOUT_SECONDS + 60:
        return claim
    for key in ("running_pid", "running_since"):
        claim.pop(key, None)
    _write_pending(claimed, claim)
    with contextlib.suppress(OSError):
        claimed.rename(path)
    return None


def handle_reply(
    text: str, *, platform: str, chat_id: str, thread_id: str, message_id: str = "",
    path: Path, now: float | None = None, run: Callable[..., Any] = subprocess.run,
    repaint: Optional[Callable[[str, str, str, str], Any]] = None,
) -> Optional[str]:
    """Answer a reply to the pending backup question, or None when it is not one.
    ``repaint(chat_id, question_ts, state, note)`` recolours the question (done/declined/failed);
    its failure never changes the backup's answer."""

    def paint(state: str, note: str) -> None:
        if repaint is None or not pending.get("thread_ts"):
            return
        try:
            repaint(str(pending.get("chat_id") or ""), str(pending["thread_ts"]), state, note)
        except Exception:
            pass
    now = time.time() if now is None else now
    if platform != "slack":
        return None
    claimed = path.with_suffix(".running")
    running = _running_claim(claimed, path, now) if claimed.exists() else None
    if running is not None:
        if str(running.get("chat_id") or "") == str(chat_id or "") and classify_reply(
                text, in_thread=True) == "approve":
            return "⏳ 볼트 백업이 이미 진행 중이에요. 끝나면 결과를 알려드릴게요."
        return None
    pending = _load_pending(path, now)
    if pending is None or str(pending.get("chat_id") or "") != str(chat_id or ""):
        return None
    in_thread = bool(thread_id) and thread_id == pending.get("thread_ts")
    # Slack gives a top-level message its own ts as thread id.
    top_level = not thread_id or thread_id == message_id
    if not in_thread and not top_level:
        return None
    decision = classify_reply(text, in_thread=in_thread)
    if decision is None and top_level and str(chat_id).startswith("D") and not pending.get("thread_only"):
        decision = classify_reply(text, in_thread=True)  # still the latest question in the DM
    if decision is None:
        if top_level and not pending.get("thread_only"):
            pending["thread_only"] = True
            _write_pending(path, pending)
        return None

    # Claim the question first so a double-tapped 승인 cannot run two backups.
    try:
        path.rename(claimed)
    except OSError:
        return None
    if decision == "reject":
        claimed.unlink(missing_ok=True)
        paint("declined", "백업 건너뜀")
        return "볼트 백업을 건너뛰었어요. 다음 점검 때 다시 물어볼게요."
    _write_pending(claimed, {**pending, "running_pid": os.getpid(), "running_since": now})

    try:
        result = _run_backup(Path(str(pending.get("vault") or "")), run)
    except Exception as error:  # timeout or spawn failure
        result = {"status": "FAIL", "error": str(error)[:300]}
    if result.get("status") == "OK":
        claimed.unlink(missing_ok=True)
        pushed = int(result.get("pushed") or 0)
        paint("done", f"커밋 {pushed}개 GitHub 반영" if pushed else "올릴 변경 없음")
        if not pushed:
            return "✅ 볼트는 이미 GitHub와 같은 상태라 올릴 게 없었어요."
        return f"✅ 볼트 백업 완료 — 파일 {result.get('committed', 0)}개를 커밋하고 커밋 {pushed}개를 GitHub에 올렸어요."
    for key in ("running_pid", "running_since"):
        pending.pop(key, None)
    _write_pending(claimed, pending)
    claimed.rename(path)  # keep the question open so 승인 can be retried
    paint("failed", "승인하면 다시 시도")
    # "승인하면" is what makes the ddots chat put 승인·거절·의견 buttons under this post.
    return (f"❌ 볼트 백업 실패: {str(result.get('error') or '원인 미상')[:300]}\n"
            "승인하면 다시 시도할게요. 이 스레드에 `승인`이라고 답해 주세요.")


def _reply_ids(path, pending):
    """Retry message provenance is separate from the approval claim state."""
    try:
        lines = path.with_suffix(".replies.jsonl").read_text().splitlines()
    except FileNotFoundError:
        return set()
    result = set()
    for line in lines:
        try:
            item = json.loads(line)
            if (isinstance(item, dict) and item.get("thread_ts") == pending.get("thread_ts")
                    and item.get("chat_id") == pending.get("chat_id")
                    and item.get("created_at") == pending.get("created_at") and isinstance(item.get("reply_ts"), str)):
                result.add(item["reply_ts"])
        except ValueError:
            continue
    return result


def _remember_reply(path, pending, ts):
    # Never rewrite/reopen pending after the network hop: the owner may already
    # have retried and completed the backup while this failure reply was sent.
    record = {key: pending.get(key) for key in ("thread_ts", "chat_id", "created_at")}
    record["reply_ts"] = str(ts)
    with path.with_suffix(".replies.jsonl").open("a") as out:
        out.write(json.dumps(record) + "\n")


async def dispatch(home, base, team, event=None, gateway=None, **_):
    """Run before core auth, so independently require the owner and live ingress.

    The hook owns only the configured wiki profile's pending question. In a
    shared channel a bare top-level answer belongs to no particular report.
    """
    source = getattr(event, "source", None)
    if (getattr(getattr(source, "platform", None), "value", "") != "slack"
            or getattr(event, "internal", False)
            or not getattr(event, "allow_gateway_control", False)
            or not team.home_has_role(home, "wiki")
            or (getattr(source, "profile", None) or "default") != team.profile_of_home(home)):
        return None
    authorize = getattr(gateway, "_is_user_authorized_for_source", None)
    if not callable(authorize) or not authorize(source):
        return None
    if str(getattr(source, "user_id", "")) != base.owner(home):
        return None
    path = team.root_home() / "state/vault-backup-pending.json"
    pending = _load_pending(path, time.time()) or _load_pending(path.with_suffix(".running"), time.time())
    if pending is None or str(pending.get("chat_id") or "") != str(source.chat_id or ""):
        return None
    thread = str(getattr(source, "thread_id", "") or "")
    message = str(getattr(event, "message_id", "") or "")
    if thread and thread != message and thread != str(pending.get("thread_ts") or ""):
        return None
    raw = getattr(event, "raw_message", None) or {}
    button = raw.get("_hermes_button") if isinstance(raw, dict) else None
    if button is not None and (not isinstance(button, dict)
                   or button.get("message_ts") not in {pending.get("thread_ts"), *_reply_ids(path, pending)}
                   or button.get("label") != event.text
                   or thread != pending.get("thread_ts")):
        return {"action": "skip", "reason": "vault backup button source mismatch"}
    configured = base.learning.extension("owner_vault").text("obsidian.wiki_vault_path")
    if not configured or Path(configured).expanduser().resolve() != Path(str(pending.get("vault") or "")).resolve():
        return {"action": "skip", "reason": "vault backup target differs from configured vault"}

    def repaint(chat, ts, state, note):
        base.learning.extension("report_status").mark(
            lambda method, body: base.slack(home, method, body), chat, ts, state, note)

    answer = await asyncio.to_thread(handle_reply, event.text, platform="slack", chat_id=str(source.chat_id),
                                    thread_id=thread, message_id=message, path=path, repaint=repaint)
    if answer is None:
        return None
    colour = "🔴" if answer.startswith("❌") else "🟡" if answer.startswith("⏳") else "🟢"
    body = {"channel": source.chat_id, "thread_ts": pending.get("thread_ts") or thread or message,
            "text": f"*{colour} 볼트 백업*\n{answer}"}
    if colour == "🔴":
        body["text"] += "\n[[버튼: 승인 | 거절]]"
    try:
        sent = await asyncio.to_thread(base.slack, home, "chat.postMessage", body)
        if colour == "🔴" and isinstance(sent, dict) and sent.get("ts"):
            _remember_reply(path, pending, sent["ts"])
    except Exception:
        # A failed delivery must not fall through to a model and repeat a backup
        # that already ran. The pending state still records retry vs completion.
        logging.getLogger(__name__).exception("Vault backup result delivery failed")
    return {"action": "skip", "reason": "vault backup decision handled by plugin"}
