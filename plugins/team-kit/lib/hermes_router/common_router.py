"""Deterministic, model-free inbound routing with an atomic delivery claim."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping


_CLAIM_STORE_INIT_LOCK = threading.Lock()


@dataclass(frozen=True)
class RouteDecision:
    profile: str
    reason: str
    persist_thread: bool = True


_FENCED_CODE_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`]*`")
_TEMPORARY_REVIEW_RE = re.compile(
    r"(?:잠깐|이번\s*(?:답변|작업)만|방금\s*작업만)"
)
_APPROVAL_POSITIVE_EXACT = {
    "approve", "confirm", "yes", "y", "ok", "okay", "👍",
    "승인", "전송", "삭제 승인", "응", "응응", "ㅇㅇ", "네", "예", "넥", "넥넥",
    "좋아", "좋습니다", "오케이", "그래", "그대로", "진행", "고고",
}
_APPROVAL_NEGATIVE_EXACT = {
    "deny", "reject", "cancel", "no", "n", "👎",
    "거부", "거절", "취소", "아니", "아니요", "안돼", "안 돼", "보류", "멈춰",
}
_APPROVAL_NEGATIVE_RE = re.compile(
    r"^(?:아니(?:요)?\s*)?(?:승인|진행|실행|그대로\s*진행)?\s*"
    r"(?:하지\s*마|하지\s*말아|하면\s*안\s*돼|취소해|거부해|거절해|보류해)"
    r"(?:요)?[.!~\s]*$"
)
_APPROVAL_POSITIVE_RE = re.compile(
    r"^(?:(?:ㅇ+|응(?:응)?|네|예|넥(?:넥)?|좋아|좋습니다|오케이|그래|알겠어|확인)\s*)?"
    r"(?:"
    r"승인(?:해|해줘|해\s*주세요|합니다|하고\s*(?:진행|실행)(?:해|해줘|해\s*주세요)?)?"
    r"|(?:그대로|이대로|그걸로)\s*(?:(?:진행|실행)(?:해|해줘|해\s*주세요)?|해|해줘|해\s*주세요)"
    r"|(?:진행|실행)(?:해|해줘|해\s*주세요|하자|하세요)?"
    r"|해줘|해\s*주세요|하자|하세요"
    r")[.!~\s]*$"
)


def _direct_text(text: str) -> str:
    """Return user-authored prose, excluding fenced/inline code and quoted lines."""
    without_fences = _FENCED_CODE_RE.sub("", str(text or ""))
    direct_lines = [
        _INLINE_CODE_RE.sub("", line)
        for line in without_fences.splitlines()
        if line.strip() and not line.lstrip().startswith(">")
    ]
    return "\n".join(direct_lines).strip()


def direct_text_contains(text: str, token: str) -> bool:
    """True when a token appears in direct prose, not quoted or code material."""
    return bool(token) and str(token) in _direct_text(text)


def approval_response_choice(text: str) -> str | None:
    """Classify a short, direct response to an already-pending approval.

    This function never checks whether an approval is pending. Callers must gate it on
    their own pending-approval state before acting on the returned choice.
    """
    direct = re.sub(r"\s+", " ", _direct_text(text)).strip().casefold()
    from hermes_router.project_threads import approval_selection
    project_choice = approval_selection(direct)
    if project_choice:
        return "approve" if project_choice[0] == "승인" else "deny"
    normalized = direct.strip(" \t\r\n.,!~")
    if not normalized or len(normalized) > 80 or "?" in direct:
        return None
    if normalized in _APPROVAL_NEGATIVE_EXACT or _APPROVAL_NEGATIVE_RE.fullmatch(direct):
        return "deny"
    if normalized in _APPROVAL_POSITIVE_EXACT or _APPROVAL_POSITIVE_RE.fullmatch(direct):
        return "approve"
    return None


def _matches(patterns: Mapping[str, Any], name: str, text: str) -> bool:
    pattern = str(patterns.get(name) or "")
    return bool(pattern and re.search(pattern, text, re.IGNORECASE))


_RECENT_OWNER_APPROVAL_SECONDS = 600


def select_profile(
    text: str,
    contract: Mapping[str, Any],
    *,
    explicit_profile: str | None = None,
    pending_profile: str | None = None,
    thread_profile: str | None = None,
    thread_locked: bool = False,
) -> RouteDecision:
    """Return exactly one profile using the policy's fixed precedence.

    A mention (``explicit_profile``) wins, then a reply to a pending approval, then the profile
    that already owns the thread. A new conversation goes to ``profiles.fallback``; its content is
    never classified. ``thread_locked`` is accepted for callers that still pass it."""
    normalized = str(text or "").strip()
    if contract.get('hub_request_routing'):
        from hermes_router.project_requests import direct_request
        normalized = direct_request(normalized)
    if explicit_profile:
        return RouteDecision(
            str(explicit_profile),
            "explicit_profile",
            persist_thread=not bool(_TEMPORARY_REVIEW_RE.search(_direct_text(normalized))),
        )

    if pending_profile and approval_response_choice(normalized) in {"approve", "deny"}:
        return RouteDecision(str(pending_profile), "pending_approval")

    if thread_profile:
        return RouteDecision(str(thread_profile), "thread_continuation")
    return RouteDecision(str(contract["profiles"]["fallback"]), "fallback")


def thread_route_key(
    *, platform: str, scope_id: str | None, chat_id: str, thread_id: str
) -> str:
    """Stable owner key for one conversation thread, isolated by workspace and channel."""
    if not str(platform or "").strip():
        raise ValueError("platform is required for a thread route")
    if not str(chat_id or "").strip():
        raise ValueError("chat_id is required for a thread route")
    if not str(thread_id or "").strip():
        raise ValueError("thread_id is required for a thread route")
    payload = [
        str(platform).strip().casefold(),
        str(scope_id or "").strip(),
        str(chat_id).strip(),
        str(thread_id).strip(),
    ]
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def pending_route_key(
    *, platform: str, scope_id: str | None, chat_id: str, thread_id: str | None
) -> str:
    """Stable pending-approval key, including non-threaded chat surfaces."""
    if not str(platform or "").strip():
        raise ValueError("platform is required for a pending approval route")
    if not str(chat_id or "").strip():
        raise ValueError("chat_id is required for a pending approval route")
    payload = [
        str(platform).strip().casefold(),
        str(scope_id or "").strip(),
        str(chat_id).strip(),
        str(thread_id or "").strip(),
    ]
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def claim_key(
    *,
    platform: str,
    scope_id: str | None,
    chat_id: str,
    thread_id: str | None,
    message_id: str,
) -> str:
    """Build the stable claim key defined by the routing contract."""
    if not str(platform or "").strip():
        raise ValueError("platform is required for a common-router claim")
    if not str(chat_id or "").strip():
        raise ValueError("chat_id is required for a common-router claim")
    if not str(message_id or "").strip():
        raise ValueError("message_id is required for a common-router claim")
    payload = [
        str(platform).strip().casefold(),
        str(scope_id or "").strip(),
        str(chat_id).strip(),
        str(thread_id or "").strip(),
        str(message_id).strip(),
    ]
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


class ClaimStore:
    """SQLite-backed exactly-once admission shared by every served profile."""

    def __init__(self, path: str | Path, *, retention_seconds: int = 604800) -> None:
        self.path = Path(path)
        self.retention_seconds = max(int(retention_seconds), 3600)
        with _CLAIM_STORE_INIT_LOCK:
            conn = self._connect()
            try:
                conn.execute("PRAGMA journal_mode = WAL")
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS inbound_claims (
                        claim_key TEXT PRIMARY KEY,
                        selected_profile TEXT NOT NULL,
                        reason TEXT NOT NULL,
                        platform TEXT NOT NULL,
                        scope_id TEXT NOT NULL,
                        chat_id TEXT NOT NULL,
                        thread_id TEXT NOT NULL,
                        message_id TEXT NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """
                )
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS thread_routes (
                        route_key TEXT PRIMARY KEY,
                        selected_profile TEXT NOT NULL,
                        platform TEXT NOT NULL,
                        scope_id TEXT NOT NULL,
                        chat_id TEXT NOT NULL,
                        thread_id TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS pending_approval_routes (
                        route_key TEXT PRIMARY KEY,
                        selected_profile TEXT NOT NULL,
                        operation TEXT NOT NULL,
                        preview_digest TEXT NOT NULL,
                        platform TEXT NOT NULL,
                        scope_id TEXT NOT NULL,
                        chat_id TEXT NOT NULL,
                        thread_id TEXT NOT NULL,
                        expires_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                conn.commit()
            finally:
                conn.close()

    def _connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.parent.chmod(0o700)
        conn = sqlite3.connect(self.path, timeout=5.0)
        self.path.chmod(0o600)
        conn.execute("PRAGMA busy_timeout = 5000")
        return conn

    def resolve_thread(
        self,
        *,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str,
        valid_profiles: set[str],
        retention_seconds: int,
    ) -> tuple[str | None, str | None]:
        key = thread_route_key(
            platform=platform,
            scope_id=scope_id,
            chat_id=chat_id,
            thread_id=thread_id,
        )
        with self._connect() as conn:
            row = conn.execute(
                "SELECT selected_profile, updated_at FROM thread_routes WHERE route_key = ?",
                (key,),
            ).fetchone()
            if row is None:
                return None, None
            profile, updated_at = str(row[0] or "").strip(), float(row[1] or 0)
            if updated_at < time.time() - max(int(retention_seconds), 3600):
                conn.execute("DELETE FROM thread_routes WHERE route_key = ?", (key,))
                return None, "expired"
            if not profile or profile not in valid_profiles:
                conn.execute("DELETE FROM thread_routes WHERE route_key = ?", (key,))
                return None, "invalid_profile"
            return profile, None

    def save_thread(
        self,
        *,
        decision: RouteDecision,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str,
    ) -> None:
        with self._connect() as conn:
            self._save_thread_with_connection(
                conn,
                decision=decision,
                platform=platform,
                scope_id=scope_id,
                chat_id=chat_id,
                thread_id=thread_id,
            )

    def save_pending_owner(
        self,
        *,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str | None,
        selected_profile: str,
        operation: str,
        preview_digest: str,
        retention_seconds: int = 3600,
    ) -> None:
        key = pending_route_key(
            platform=platform,
            scope_id=scope_id,
            chat_id=chat_id,
            thread_id=thread_id,
        )
        now = time.time()
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO pending_approval_routes (
                    route_key, selected_profile, operation, preview_digest,
                    platform, scope_id, chat_id, thread_id, expires_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(route_key) DO UPDATE SET
                    selected_profile = excluded.selected_profile,
                    operation = excluded.operation,
                    preview_digest = excluded.preview_digest,
                    expires_at = excluded.expires_at,
                    updated_at = excluded.updated_at
                """,
                (
                    key,
                    str(selected_profile),
                    str(operation),
                    str(preview_digest),
                    str(platform),
                    str(scope_id or ""),
                    str(chat_id),
                    str(thread_id or ""),
                    now + max(60, int(retention_seconds)),
                    now,
                ),
            )

    @staticmethod
    def _recent_owner(
        conn: sqlite3.Connection, *, platform: str, scope_id: str | None, chat_id: str,
        thread_id: str | None, within_seconds: float = _RECENT_OWNER_APPROVAL_SECONDS,
    ) -> str:
        row = conn.execute(
            "SELECT selected_profile FROM inbound_claims WHERE platform = ? AND scope_id = ? "
            "AND chat_id = ? AND thread_id = ? AND created_at >= ? "
            "ORDER BY created_at DESC LIMIT 1",
            (
                str(platform).strip().casefold(), str(scope_id or "").strip(),
                str(chat_id).strip(), str(thread_id or "").strip(), time.time() - within_seconds,
            ),
        ).fetchone()
        return str(row[0] or "").strip() if row else ""

    def recent_conversation_owner(
        self, *, platform: str, scope_id: str | None, chat_id: str, valid_profiles: set[str],
        within_seconds: float = _RECENT_OWNER_APPROVAL_SECONDS,
    ) -> str | None:
        """Owner of the latest routed message in a thread-less chat (e.g. an iMessage DM), used
        as that chat's "thread" so keyword-less follow-ups stay with whoever is mid-conversation."""
        with self._connect() as conn:
            profile = self._recent_owner(
                conn, platform=platform, scope_id=scope_id, chat_id=chat_id, thread_id=None,
                within_seconds=within_seconds,
            )
        return profile if profile in valid_profiles else None

    def resolve_pending_owner(
        self,
        text: str,
        *,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str | None,
        valid_profiles: set[str],
    ) -> tuple[str | None, str | None]:
        if approval_response_choice(text) not in {"approve", "deny"}:
            return None, None
        key = pending_route_key(
            platform=platform,
            scope_id=scope_id,
            chat_id=chat_id,
            thread_id=thread_id,
        )
        with self._connect() as conn:
            row = conn.execute(
                "SELECT selected_profile, expires_at FROM pending_approval_routes WHERE route_key = ?",
                (key,),
            ).fetchone()
            if row is None:
                # A staff member may ask "승인이라고 답해" in prose without opening a formal
                # approval; a short yes/no right after that still belongs to whoever just answered
                # in this same conversation (same thread when there is one), not to the fallback.
                recent_profile = self._recent_owner(
                    conn, platform=platform, scope_id=scope_id, chat_id=chat_id, thread_id=thread_id,
                )
                if recent_profile in valid_profiles:
                    return recent_profile, None
                return None, None
            profile, expires_at = str(row[0] or "").strip(), float(row[1] or 0)
            if expires_at < time.time():
                conn.execute("DELETE FROM pending_approval_routes WHERE route_key = ?", (key,))
                return None, "expired"
            if not profile or profile not in valid_profiles:
                conn.execute("DELETE FROM pending_approval_routes WHERE route_key = ?", (key,))
                return None, "invalid_profile"
            return profile, None

    def clear_pending_owner(
        self,
        *,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str | None,
    ) -> None:
        key = pending_route_key(
            platform=platform,
            scope_id=scope_id,
            chat_id=chat_id,
            thread_id=thread_id,
        )
        with self._connect() as conn:
            conn.execute("DELETE FROM pending_approval_routes WHERE route_key = ?", (key,))

    @staticmethod
    def _save_thread_with_connection(
        conn: sqlite3.Connection,
        *,
        decision: RouteDecision,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str,
    ) -> None:
        key = thread_route_key(
            platform=platform,
            scope_id=scope_id,
            chat_id=chat_id,
            thread_id=thread_id,
        )
        conn.execute(
            """
            INSERT INTO thread_routes (
                route_key, selected_profile, platform, scope_id,
                chat_id, thread_id, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(route_key) DO UPDATE SET
                selected_profile = excluded.selected_profile,
                updated_at = excluded.updated_at
            """,
            (
                key,
                decision.profile,
                str(platform),
                str(scope_id or ""),
                str(chat_id),
                str(thread_id),
                time.time(),
            ),
        )

    def claim(
        self,
        *,
        key: str,
        decision: RouteDecision,
        platform: str,
        scope_id: str | None,
        chat_id: str,
        thread_id: str | None,
        message_id: str,
    ) -> bool:
        now = time.time()
        with self._connect() as conn:
            conn.execute(
                "DELETE FROM inbound_claims WHERE created_at < ?",
                (now - self.retention_seconds,),
            )
            cursor = conn.execute(
                """
                INSERT OR IGNORE INTO inbound_claims (
                    claim_key, selected_profile, reason, platform, scope_id,
                    chat_id, thread_id, message_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    key,
                    decision.profile,
                    decision.reason,
                    str(platform),
                    str(scope_id or ""),
                    str(chat_id),
                    str(thread_id or ""),
                    str(message_id),
                    now,
                ),
            )
            if cursor.rowcount == 1 and decision.persist_thread and str(thread_id or "").strip():
                self._save_thread_with_connection(
                    conn,
                    decision=decision,
                    platform=platform,
                    scope_id=scope_id,
                    chat_id=chat_id,
                    thread_id=str(thread_id),
                )
            return cursor.rowcount == 1
