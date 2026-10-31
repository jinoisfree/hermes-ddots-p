"""Per-turn response usage ledger and display-only usage footer, as a plugin (공항 설계 5b-2, 2026-10-31).

This replaces the starter_user core patch (``agent/turn_metrics.py``, ``gateway/runtime_footer.py`` response-usage
parts and their call sites). What it keeps, byte for byte:

* ``<home>/logs/response_usage.jsonl`` rows (``schema hermes.response_usage.v1``): ``stage "agent"`` at turn end,
  ``stage "delivery:<platform>"`` with ``platform``/``chat_id``/``thread_id``/``origin_message_id``/``profile_id``
  at delivery (the only rows ``request_usage_lookup`` reads) and ``stage "delivery:<platform>:zero-call"``.
* The four-line footer (separator, time/calls/tools, input, output, optional warning line), display only:
  it is appended to the text the gateway handler returns, after the answer is persisted, so history and the
  DB never contain it. Replies that never entered the model loop (commands, button replies) get the zero-call
  footer as before.

How it hooks in (all public plugin surfaces):

* turn boundaries ``pre_llm_call`` / ``post_llm_call``; model attempts ``pre_api_request`` / ``post_api_request``;
  auxiliary model calls ``pre_auxiliary_call`` / ``post_auxiliary_call``; tools ``post_tool_call``.
* delivery: ``register_platform_handler`` wraps each adapter's ``_message_handler`` (slack, photon).

``raw_usage``: the hook usage summary drops the provider's raw usage dict, which is the only way to tell an
explicit zero from a missing field ("observed"). The core keeps ``raw_usage`` in the summary (one deleted
line in ``agent/api_request_hooks.py`` and ``agent/auxiliary_hooks.py``); without it this module falls back to
"observed when non-zero".

Settings (``plugins.entries.team-kit.settings.usage_ledger``): ``enabled`` (default False),
``shadow`` (default False: collect and write ``response_usage.shadow.jsonl`` only; no footer, no official rows).
"""
from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Optional

logger = logging.getLogger(__name__)

_USAGE_SEPARATOR = "────────────────────"
_USAGE_MARKER = f"{_USAGE_SEPARATOR}\n⏱ "

# --- provider usage shapes: the "observed" rules live in usage_observed.py (shared with team-delegation) ----
def _load_observed():
    import importlib.util
    import sys
    module = sys.modules.get("hermes_usage_observed")
    if module is None:
        spec = importlib.util.spec_from_file_location("hermes_usage_observed", Path(__file__).with_name("usage_observed.py"))
        module = sys.modules["hermes_usage_observed"] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


_obs = _load_observed()
_INPUT, _OUTPUT, _CACHE_READ, _CACHE_WRITE = _obs.INPUT, _obs.OUTPUT, _obs.CACHE_READ, _obs.CACHE_WRITE
observed = _obs.observed


# --- per-turn ledger ---------------------------------------------------------------------------------------
class _UsageRow:
    __slots__ = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens",
                 "input_observed", "output_observed", "cache_read_observed", "cache_write_observed")

    def __init__(self, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
                 input_observed, output_observed, cache_read_observed, cache_write_observed) -> None:
        self.input_tokens, self.output_tokens = input_tokens, output_tokens
        self.cache_read_tokens, self.cache_write_tokens = cache_read_tokens, cache_write_tokens
        self.reasoning_tokens = reasoning_tokens
        self.input_observed, self.output_observed = input_observed, output_observed
        self.cache_read_observed, self.cache_write_observed = cache_read_observed, cache_write_observed


class TurnMetrics:
    """One user turn's counters; plain class on purpose (the plugin loader does not register the module,
    so ``@dataclass`` with postponed annotations would fail)."""

    def __init__(self, task_id: str) -> None:
        self.task_id = task_id
        self.started_monotonic = time.monotonic()
        self._lock = threading.RLock()
        self._attempts: dict = {}
        self._attempt_sources: dict = {}
        self._usage: dict = {}
        self._tools: set = set()
        self.participants = 0
        self.finalized = False
        self.late_events = 0

    def _late(self) -> None:
        if self.finalized:
            self.late_events += 1

    def add_attempt(self, attempt_id: str, logical_call_id: str, *, source: str = "") -> None:
        if not attempt_id:
            return
        with self._lock:
            self._late()
            self._attempts.setdefault(attempt_id, logical_call_id or attempt_id)
            if source and not self._attempt_sources.get(attempt_id):
                self._attempt_sources[attempt_id] = source

    def add_usage(self, attempt_id: str, usage: Any, *, cache_read_observed: bool, cache_write_observed: bool = False,
                  input_observed: bool = True, output_observed: bool = True, source: str = "") -> None:
        if not attempt_id:
            return
        with self._lock:
            self._attempts.setdefault(attempt_id, attempt_id)
            if source and not self._attempt_sources.get(attempt_id):
                self._attempt_sources[attempt_id] = source
            incoming = _UsageRow(
                input_tokens=max(0, int(getattr(usage, "prompt_tokens", 0) or 0)),
                output_tokens=max(0, int(getattr(usage, "output_tokens", 0) or 0)),
                cache_read_tokens=max(0, int(getattr(usage, "cache_read_tokens", 0) or 0)),
                cache_write_tokens=max(0, int(getattr(usage, "cache_write_tokens", 0) or 0)),
                reasoning_tokens=max(0, int(getattr(usage, "reasoning_tokens", 0) or 0)),
                input_observed=bool(input_observed), output_observed=bool(output_observed),
                cache_read_observed=bool(cache_read_observed), cache_write_observed=bool(cache_write_observed),
            )
            current = self._usage.get(attempt_id)
            if current is None:
                self._late()
                self._usage[attempt_id] = incoming
                return
            changed = False
            for value_field, observed_field in (
                ("input_tokens", "input_observed"), ("output_tokens", "output_observed"),
                ("cache_read_tokens", "cache_read_observed"), ("cache_write_tokens", "cache_write_observed"),
            ):
                if not getattr(current, observed_field) and getattr(incoming, observed_field):
                    setattr(current, value_field, getattr(incoming, value_field))
                    setattr(current, observed_field, True)
                    changed = True
            if current.reasoning_tokens == 0 and incoming.reasoning_tokens:
                current.reasoning_tokens = incoming.reasoning_tokens
                changed = True
            if changed:
                self._late()

    def add_tool(self, tool_call_id: str) -> None:
        if not tool_call_id:
            return
        with self._lock:
            self._late()
            self._tools.add(tool_call_id)

    def snapshot(self, *, elapsed_seconds: Optional[float] = None) -> dict:
        with self._lock:
            rows = list(self._usage.values())
            attempts = len(self._attempts)
            logical_calls = len(set(self._attempts.values()))
            usage_received = len(rows)
            input_tokens = sum(r.input_tokens for r in rows if r.input_observed)
            output_tokens = sum(r.output_tokens for r in rows if r.output_observed)
            cache_read_tokens = sum(r.cache_read_tokens for r in rows if r.cache_read_observed)
            cache_write_tokens = sum(r.cache_write_tokens for r in rows if r.cache_write_observed)
            reasoning_tokens = sum(r.reasoning_tokens for r in rows if r.output_observed)
            input_observed_count = sum(r.input_observed for r in rows)
            output_observed_count = sum(r.output_observed for r in rows)
            cache_read_observed_count = sum(r.cache_read_observed for r in rows)
            cache_write_observed_count = sum(r.cache_write_observed for r in rows)
            cache_read_missing_sources = list(dict.fromkeys(
                self._attempt_sources.get(a, "") for a in self._attempts
                if (a not in self._usage or not self._usage[a].cache_read_observed) and self._attempt_sources.get(a, "")
            ))
            pending = max(0, self.participants)
            partial = attempts != usage_received or pending > 0 or self.late_events > 0
            return {
                "task_id": self.task_id,
                "elapsed_seconds": max(0.0, float(elapsed_seconds) if elapsed_seconds is not None
                                       else time.monotonic() - self.started_monotonic),
                "model_calls": attempts,
                "logical_model_calls": logical_calls,
                "retry_count": max(0, attempts - logical_calls),
                "tool_calls": len(self._tools),
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "total_tokens": input_tokens + output_tokens,
                "cache_read_tokens": cache_read_tokens,
                "cache_write_tokens": cache_write_tokens,
                "reasoning_tokens": reasoning_tokens,
                "usage_received": usage_received,
                "usage_expected": attempts,
                "input_observed_count": input_observed_count,
                "output_observed_count": output_observed_count,
                "cache_read_observed_count": cache_read_observed_count,
                "cache_write_observed_count": cache_write_observed_count,
                "input_complete": input_observed_count == attempts,
                "output_complete": output_observed_count == attempts,
                "cache_read_complete": cache_read_observed_count == attempts,
                "cache_write_complete": cache_write_observed_count == attempts,
                "cache_read_missing_sources": cache_read_missing_sources,
                "partial": partial,
                "pending_participants": pending,
                "late_events": self.late_events,
            }


# --- ledger file -------------------------------------------------------------------------------------------
def ledger_path(home: Path, *, shadow: bool = False) -> Path:
    return Path(home) / "logs" / ("response_usage.shadow.jsonl" if shadow else "response_usage.jsonl")


def write_ledger(home: Path, snapshot: dict, *, stage: str = "agent", shadow: bool = False) -> bool:
    """Append a prompt-free JSONL record. Logging failure must never block a reply."""
    try:
        path = ledger_path(home, shadow=shadow)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"schema": "hermes.response_usage.v1", "stage": stage, **snapshot}
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        return True
    except Exception:
        logger.warning("response usage ledger write failed", exc_info=True)
        return False


# --- footer (display only) ---------------------------------------------------------------------------------
def resolve_response_usage_config(user_config: Optional[dict], platform_key: Optional[str] = None) -> dict:
    """One fail-open switch, enabled by default for every profile and user surface."""
    display = (user_config or {}).get("display") or {}
    resolved = {"enabled": True}
    sections = [display.get("response_usage_footer")]
    platform = (display.get("platforms") or {}).get(platform_key) if platform_key else None
    if isinstance(platform, dict):
        sections.append(platform.get("response_usage_footer"))
    for section in sections:
        if isinstance(section, dict) and "enabled" in section:
            resolved["enabled"] = bool(section.get("enabled"))
    return resolved


def _compact_tokens(value: int) -> str:
    value = max(0, int(value))
    if value < 1_000:
        return str(value)
    text = f"{value / 1_000:.1f}".rstrip("0").rstrip(".")
    return f"{text}K"


def _one_decimal(value: float) -> str:
    return f"{max(0.0, float(value)):.1f}".rstrip("0").rstrip(".")


def format_response_usage_footer(metrics: Optional[dict], *, elapsed_seconds: Optional[float] = None) -> str:
    """Render the deterministic four-line footer, plus a warning only when warranted."""
    missing_metrics = not isinstance(metrics, dict) or "model_calls" not in metrics
    values = metrics if isinstance(metrics, dict) else {}
    attempts = max(0, int(values.get("model_calls", 0) or 0))
    tools = max(0, int(values.get("tool_calls", 0) or 0))
    received = max(0, int(values.get("usage_received", 0) or 0))
    expected = max(0, int(values.get("usage_expected", attempts) or 0))
    input_observed = max(0, int(values.get("input_observed_count", received) or 0))
    output_observed = max(0, int(values.get("output_observed_count", received) or 0))
    cache_read_observed = max(0, int(values.get(
        "cache_read_observed_count", expected if values.get("cache_read_complete") else 0) or 0))
    input_complete = bool(values.get("input_complete", bool(expected) and input_observed == expected))
    output_complete = bool(values.get("output_complete", bool(expected) and output_observed == expected))
    cache_read_complete = bool(values.get("cache_read_complete"))
    elapsed = values.get("elapsed_seconds") if elapsed_seconds is None else elapsed_seconds
    elapsed_label = "미계측" if elapsed is None else f"{_one_decimal(float(elapsed))}초"

    if missing_metrics:
        input_line = "📥 입력 미계측 = 비캐시 미계측 + 캐시 미계측(미계측)"
        output_line = "📤 출력 미계측 · 총 미계측"
    elif attempts == 0:
        input_line = "📥 입력 0 = 비캐시 0 + 캐시 0(—)"
        output_line = "📤 출력 0 · 총 0"
    elif received == 0:
        input_line = "📥 입력 미계측 = 비캐시 미계측 + 캐시 미계측(미계측)"
        output_line = "📤 출력 미계측 · 총 미계측"
    else:
        input_tokens = max(0, int(values.get("input_tokens", 0) or 0))
        output_tokens = max(0, int(values.get("output_tokens", 0) or 0))
        total_tokens = input_tokens + output_tokens
        if input_complete and cache_read_complete:
            cache = max(0, int(values.get("cache_read_tokens", 0) or 0))
            noncache = max(0, input_tokens - cache)
            rate = "—" if input_tokens == 0 else f"{_one_decimal(cache / input_tokens * 100)}%"
            input_line = (f"📥 입력 {_compact_tokens(input_tokens)} = "
                          f"비캐시 {_compact_tokens(noncache)} + 캐시 {_compact_tokens(cache)}({rate})")
        else:
            input_label = (_compact_tokens(input_tokens) if input_complete
                           else f"확인분 {_compact_tokens(input_tokens)}" if input_observed else "미계측")
            cache_label = (f"{_compact_tokens(max(0, int(values.get('cache_read_tokens', 0) or 0)))}"
                           f"{'(확인분)' if not cache_read_complete else ''}" if cache_read_observed else "미계측")
            input_line = f"📥 입력 {input_label} · 캐시 {cache_label} · 비캐시 미확정"
        output_label = (_compact_tokens(output_tokens) if output_complete
                        else f"확인분 {_compact_tokens(output_tokens)}" if output_observed else "미계측")
        total_label = (_compact_tokens(total_tokens) if input_complete and output_complete
                       else f"확인분 {_compact_tokens(total_tokens)}" if input_observed or output_observed else "미계측")
        output_line = f"📤 출력 {output_label} · 총 {total_label}"

    lines = [
        _USAGE_SEPARATOR,
        (f"⏱ {elapsed_label} · 모델 미계측 · 도구 미계측" if missing_metrics
         else f"⏱ {elapsed_label} · 모델 {attempts}회 · 도구 {tools}회"),
        input_line,
        output_line,
    ]
    warnings = ["부분 계측(작업 usage 미수신)"] if missing_metrics else []
    retries = max(0, int(values.get("retry_count", 0) or 0))
    if retries:
        warnings.append(f"재시도 {retries}회")
    if attempts and received < expected:
        warnings.append(f"부분 계측(usage {received}/{expected} 수신)")
    if attempts and received:
        if input_observed < expected:
            warnings.append(f"입력 {input_observed}/{expected} 계측")
        if output_observed < expected:
            warnings.append(f"출력 {output_observed}/{expected} 계측")
        if cache_read_observed < expected:
            warnings.append(f"캐시 읽기 {cache_read_observed}/{expected} 계측")
            source_labels = {"title_generation": "제목 생성", "main": "본 호출"}
            for source in values.get("cache_read_missing_sources") or []:
                label = source_labels.get(str(source), str(source).replace("_", " ").strip())
                if label:
                    warnings.append(f"{label} 미수신")
    pending = max(0, int(values.get("pending_participants", 0) or 0))
    if pending:
        warnings.append(f"미완료 위임 {pending}개")
    if values.get("late_events"):
        warnings.append(f"지연 usage {int(values['late_events'])}건")
    if warnings:
        lines.append("⚠ " + " · ".join(warnings))
    return "\n".join(lines)


def append_response_usage_footer(text: str, footer: str) -> str:
    """Append once without regex-removing arbitrary user or model prose."""
    if not footer or _USAGE_MARKER in (text or ""):
        return text or ""
    return f"{text.rstrip()}\n\n{footer}" if text else footer


def zero_call_response_metrics(*, elapsed_seconds: Optional[float] = None) -> dict:
    """A confirmed no-model response, distinct from a missing measurement object."""
    return {
        "task_id": str(uuid.uuid4()), "elapsed_seconds": elapsed_seconds, "model_calls": 0, "logical_model_calls": 0,
        "retry_count": 0, "tool_calls": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0,
        "cache_read_tokens": 0, "cache_write_tokens": 0, "reasoning_tokens": 0, "usage_received": 0,
        "usage_expected": 0, "input_observed_count": 0, "output_observed_count": 0, "cache_read_observed_count": 0,
        "cache_write_observed_count": 0, "input_complete": True, "output_complete": True, "cache_read_complete": True,
        "cache_write_complete": True, "cache_read_missing_sources": [], "partial": False, "pending_participants": 0,
        "late_events": 0,
    }


# --- collector ----------------------------------------------------------------------------------------------
def _session_env(name: str) -> str:
    try:
        from gateway.session_context import get_session_env
        return str(get_session_env(name, "") or "")
    except Exception:
        return ""


class Collector:
    """Turn registry shared by the hook handlers and the delivery wrapper (one per plugin load)."""

    def __init__(self, home: Path, *, shadow: bool = False) -> None:
        self.home = Path(home)
        self.shadow = shadow
        self._lock = threading.RLock()
        self._active: dict = {}
        self._finished: dict = {}
        self._by_owner: dict = {}

    # turn boundaries ----------------------------------------------------------------------------------
    def begin(self, **kw: Any) -> None:
        turn_id = str(kw.get("turn_id") or "")
        if not turn_id:
            return None
        metrics = TurnMetrics(task_id=str(uuid.uuid4()))
        metrics.participants = 1
        identity = (
            _session_env("HERMES_SESSION_PLATFORM").lower(),
            _session_env("HERMES_SESSION_CHAT_ID"),
            _session_env("HERMES_SESSION_THREAD_ID"),
        )
        with self._lock:
            cutoff = time.monotonic() - 6 * 3600
            for key in [k for k, (m, _) in self._active.items() if m.started_monotonic < cutoff]:
                self._active.pop(key, None)
            self._active[turn_id] = (metrics, identity)
            for key in (kw.get("task_id"), kw.get("session_id")):
                if key:
                    self._by_owner[str(key)] = turn_id
        return None

    def end(self, **kw: Any) -> None:
        turn_id = str(kw.get("turn_id") or "")
        with self._lock:
            entry = self._active.pop(turn_id, None)
        if entry is None:
            return None
        metrics, identity = entry
        with self._lock:
            for key in [k for k, v in self._by_owner.items() if v == turn_id]:
                self._by_owner.pop(key, None)
        with metrics._lock:
            metrics.participants = 0
            metrics.finalized = True
        snapshot = metrics.snapshot()
        write_ledger(self.home, snapshot, stage="agent", shadow=self.shadow)
        now = time.monotonic()
        with self._lock:
            queue = self._finished.setdefault(identity, deque(maxlen=8))
            queue.append((now, snapshot))
            for key in [k for k, q in self._finished.items() if q and now - q[-1][0] > 3600]:
                self._finished.pop(key, None)
        return None

    def take(self, identity: tuple, since: float) -> Optional[dict]:
        """The newest finished turn snapshot for this conversation since ``since``; older ones are dropped."""
        with self._lock:
            queue = self._finished.get(identity)
            if not queue:
                return None
            fresh = [item for item in queue if item[0] >= since]
            queue.clear()
            return fresh[-1][1] if fresh else None

    def _metrics(self, turn_id: Any) -> Optional[TurnMetrics]:
        entry = self._active.get(str(turn_id or ""))
        return entry[0] if entry else None

    # model attempts -----------------------------------------------------------------------------------
    def pre_api(self, **kw: Any) -> None:
        metrics = self._metrics(kw.get("turn_id"))
        if metrics is not None:
            request_id = str(kw.get("api_request_id") or "")
            retry = int(kw.get("retry_count") or 0)
            attempt = f"{request_id}:attempt:{retry}"
            metrics.add_attempt(attempt, request_id or attempt)
        return None

    def post_api(self, **kw: Any) -> None:
        metrics = self._metrics(kw.get("turn_id"))
        if metrics is None or not kw.get("usage"):
            return None
        request_id = str(kw.get("api_request_id") or "")
        retry = int(kw.get("retry_count") or 0)
        self._record_usage(metrics, f"{request_id}:attempt:{retry}", kw)
        return None

    def post_tool(self, **kw: Any) -> None:
        # post_tool_call carries task/session ids but no turn_id: resolve the running turn through them.
        metrics = self._metrics(kw.get("turn_id"))
        if metrics is None:
            for key in (kw.get("task_id"), kw.get("session_id")):
                turn_id = self._by_owner.get(str(key or ""))
                metrics = self._metrics(turn_id) if turn_id else None
                if metrics is not None:
                    break
        if metrics is not None:
            call_id = str(kw.get("tool_call_id") or f"{kw.get('task_id')}:{kw.get('tool_name')}:{id(kw.get('args'))}")
            metrics.add_tool(call_id)
        return None

    # auxiliary calls ----------------------------------------------------------------------------------
    def pre_aux(self, **kw: Any) -> None:
        metrics = self._metrics(kw.get("turn_id"))
        task = str(kw.get("aux_task") or "")
        if metrics is not None and task != "moa_aggregator":
            request_id = str(kw.get("api_request_id") or "")
            retry = int(kw.get("retry_count") or 0)
            attempt = f"{request_id}:attempt:{retry}"
            metrics.add_attempt(attempt, request_id or attempt, source=task or "auxiliary")
        return None

    def post_aux(self, **kw: Any) -> None:
        metrics = self._metrics(kw.get("turn_id"))
        task = str(kw.get("aux_task") or "")
        if metrics is None or task == "moa_aggregator" or not kw.get("usage"):
            return None
        request_id = str(kw.get("api_request_id") or "")
        retry = int(kw.get("retry_count") or 0)
        self._record_usage(metrics, f"{request_id}:attempt:{retry}", kw, source=task or "auxiliary")
        return None

    @staticmethod
    def _record_usage(metrics: TurnMetrics, attempt: str, kw: dict, *, source: str = "main") -> None:
        summary = kw.get("usage") or {}
        raw = summary.get("raw_usage") if isinstance(summary, dict) else None
        provider, api_mode = kw.get("provider"), kw.get("api_mode")
        usage = SimpleNamespace(**{k: summary.get(k, 0) for k in
                                   ("prompt_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens")})
        if raw is not None:
            flags = {
                "cache_read_observed": observed(raw, _CACHE_READ, provider=provider, api_mode=api_mode),
                "cache_write_observed": observed(raw, _CACHE_WRITE, provider=provider, api_mode=api_mode),
                "input_observed": observed(raw, _INPUT, provider=provider, api_mode=api_mode),
                "output_observed": observed(raw, _OUTPUT, provider=provider, api_mode=api_mode),
            }
        else:  # raw usage not exposed by this core: only non-zero values count as reported
            flags = {
                "cache_read_observed": bool(usage.cache_read_tokens), "cache_write_observed": bool(usage.cache_write_tokens),
                "input_observed": True, "output_observed": True,
            }
        metrics.add_usage(attempt, usage, source=source, **flags)


# --- delivery wrapper ----------------------------------------------------------------------------------------
def _platform_key(source: Any) -> str:
    platform = getattr(source, "platform", "")
    return str(getattr(platform, "value", platform) or "").lower()


def _gateway_config() -> dict:
    try:
        from gateway.run import _load_gateway_config
        return _load_gateway_config() or {}
    except Exception:
        return {}


def wrap_adapter(adapter: Any, collector: Collector) -> None:
    """Append the footer to what ``adapter._message_handler`` returns; idempotent per adapter."""
    if getattr(adapter, "_team_kit_usage_wrapped", False):
        return
    adapter._team_kit_usage_wrapped = True

    def wrap(handler):
        if handler is None or getattr(handler, "_team_kit_usage_footer", False):
            return handler

        async def with_footer(event, *args, **kwargs):
            entered = time.monotonic()
            response = await handler(event, *args, **kwargs)
            try:
                return _decorate(collector, event, response, entered)
            except Exception:
                logger.debug("usage footer failed; delivering the reply unchanged", exc_info=True)
                return response

        with_footer._team_kit_usage_footer = True
        return with_footer

    original_setter = adapter.set_message_handler

    def set_message_handler(handler):
        original_setter(wrap(handler))

    adapter.set_message_handler = set_message_handler
    current = getattr(adapter, "_message_handler", None)
    if current is not None:
        adapter._message_handler = wrap(current)


def _decorate(collector: Collector, event: Any, response: Any, entered: float) -> Any:
    source = getattr(event, "source", None)
    if source is None or getattr(event, "internal", False):
        return response
    platform_key = _platform_key(source)
    identity = (platform_key, str(getattr(source, "chat_id", "") or ""), str(getattr(source, "thread_id", "") or ""))
    snapshot = collector.take(identity, entered)
    config = _gateway_config()
    enabled = resolve_response_usage_config(config, platform_key).get("enabled")
    if snapshot is None:
        # No model turn ran for this reply: a confirmed zero-call response (command, button reply, notice).
        if not response or not enabled or _USAGE_MARKER in str(response):
            return response
        started = getattr(event, "_response_usage_started_monotonic", None)  # set by the core only while it keeps this patch
        elapsed = max(0.0, time.monotonic() - float(entered if started is None else started))
        metrics = zero_call_response_metrics(elapsed_seconds=elapsed)
        footer = format_response_usage_footer(metrics, elapsed_seconds=elapsed)
        write_ledger(collector.home, metrics, stage=f"delivery:{platform_key or 'unknown'}:zero-call")
        return _with_text(response, append_response_usage_footer(str(response), footer))
    turn_seconds = snapshot.get("elapsed_seconds")
    if enabled:
        origin_message_id = str(getattr(event, "ledger_message_id", None) or getattr(event, "message_id", None) or "")
        write_ledger(collector.home, {
            **snapshot, "elapsed_seconds": turn_seconds, "platform": platform_key,
            "chat_id": str(getattr(source, "chat_id", None) or ""),
            "thread_id": str(getattr(source, "thread_id", None) or origin_message_id),
            "origin_message_id": origin_message_id,
            "profile_id": str(getattr(source, "profile", None) or ""),
        }, stage=f"delivery:{platform_key}")
    if not response or not enabled:
        return response
    footer = format_response_usage_footer(snapshot, elapsed_seconds=turn_seconds)
    return _with_text(response, append_response_usage_footer(str(response), footer))


def _with_text(original: Any, text: str) -> Any:
    """Keep the reply's type (EphemeralReply carries a TTL) while swapping the text."""
    if type(original) is str or text == original:
        return text
    try:
        return type(original)(text, getattr(original, "ttl_seconds", None))
    except Exception:
        return text


# --- registration ---------------------------------------------------------------------------------------------
def register(ctx, home) -> None:
    settings = ctx.get_config("usage_ledger", {}) or {}
    if settings.get("enabled", False) is not True:
        return
    shadow = settings.get("shadow", False) is True
    collector = Collector(Path(home), shadow=shadow)
    ctx.register_hook("pre_llm_call", collector.begin)
    ctx.register_hook("post_llm_call", collector.end)
    ctx.register_hook("pre_api_request", collector.pre_api)
    ctx.register_hook("post_api_request", collector.post_api)
    ctx.register_hook("pre_auxiliary_call", collector.pre_aux)
    ctx.register_hook("post_auxiliary_call", collector.post_aux)
    ctx.register_hook("post_tool_call", collector.post_tool)
    if shadow:
        return
    for platform in ("slack", "photon"):
        ctx.register_platform_handler(platform, lambda native, adapter, _c=collector: wrap_adapter(adapter, _c))
