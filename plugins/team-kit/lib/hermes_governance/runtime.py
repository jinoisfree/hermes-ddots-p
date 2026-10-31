"""Unchanged runtime policy."""
from __future__ import annotations
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo


def _settings(services) -> dict[str, Any]:
    if services._PLUGIN_CONTEXT is None:
        return {}
    return {"enforcement": services._PLUGIN_CONTEXT.get_config("enforcement", {})}

def enforcement_decision(services, contract: dict[str, Any] | None, settings: dict[str, Any] | None = None) -> dict[str, Any]:
    contract = contract or {}
    enforcement = ((settings or {}).get("enforcement") or {})
    if enforcement.get("rollback"):
        return {"hard": False, "reason_code": "TE_ROLLBACK_ACTIVE"}
    if not enforcement.get("enabled"):
        return {"hard": False, "reason_code": "TE_HARD_DISABLED"}
    if str(enforcement.get("mode") or "warn-only") != "hard":
        return {"hard": False, "reason_code": "TE_WARN_ONLY"}
    allowed = enforcement.get("allowed_work_classes") or ["direct_lookup"]
    if contract.get("work_class") not in allowed:
        return {"hard": False, "reason_code": "TE_WORK_CLASS_OUT_OF_SCOPE"}
    canaries = {str(value) for value in (enforcement.get("canary_idempotency_keys") or [])}
    if canaries and str(contract.get("idempotency_key") or "") not in canaries:
        return {"hard": False, "reason_code": "TE_CANARY_SCOPE_MISS"}
    return {"hard": True, "reason_code": "TE_HARD_CANARY_ENABLED"}

def _task_contract(services, task_id: str | None, board: str | None = None) -> dict[str, Any]:
    if not task_id:
        return {}
    try:
        from hermes_cli import kanban_db as kb
        from hermes_cli import kanban_db_connect as kbc
        conn = kbc.connect(board=board)
        try:
            task = kb.get_task(conn, str(task_id))
        finally:
            conn.close()
        payload = json.loads(task.body or "{}") if task else {}
        return payload.get("team_delegate_contract", {}) if isinstance(payload, dict) else {}
    except Exception:
        return {}

def _active_contract(services, task_id: str | None = None, board: str | None = None) -> dict[str, Any]:
    return services._task_contract(task_id or os.environ.get("HERMES_KANBAN_TASK"), board)

def _governed_task_id(services, context: dict[str, Any]) -> str:
    """The turn's task_id is a fresh UUID; a Kanban worker has a durable card ID."""
    return str(os.environ.get("HERMES_KANBAN_TASK") or context.get("task_id") or "")

def _runtime(services, task_id: str) -> dict[str, Any]:
    return services._RUNTIME.setdefault(str(task_id), {
        "model_calls": 0, "tool_calls": 0, "input_tokens": 0, "output_tokens": 0,
        "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0,
        "reasoning_tokens": 0, "cache_read_complete": True, "cache_write_complete": True,
        "processing_seconds": 0.0, "external_wait_seconds": 0.0,
        "retry_count": 0, "mutation_calls": 0, "approval_calls": 0,
        "error_fingerprints": {}, "reason_codes": [], "trusted_fields": set(),
        "measurement_errors": [], "model_routes": [], "model_attempt_ids": [],
    })

def _hard_stop(services, code: str, detail: str, state: dict[str, Any] | None = None) -> None:
    if state is not None:
        state.setdefault("reason_codes", []).append(code)
    raise services.TokenEfficiencyHardStop(f"{code}: {detail}")

def _usage(services, result: Any) -> dict[str, Any]:
    """Use Hermes' provider adapter when available; never parse a rendered footer."""
    usage = result.get("usage", {}) if isinstance(result, dict) else getattr(result, "usage", {})
    if usage:
        try:
            from agent.usage_pricing import normalize_usage
            cache_read_usage_observed = services.usage_observed.cache_read_usage_observed
            cache_write_usage_observed = services.usage_observed.cache_write_usage_observed

            provider = (
                result.get("provider") if isinstance(result, dict)
                else getattr(result, "provider", None)
            )
            api_mode = (
                result.get("api_mode") if isinstance(result, dict)
                else getattr(result, "api_mode", None)
            )
            normalized = normalize_usage(usage, provider=provider, api_mode=api_mode)
            return {
                "input_tokens": normalized.prompt_tokens,
                "output_tokens": normalized.output_tokens,
                "total_tokens": normalized.total_tokens,
                "cache_read_tokens": normalized.cache_read_tokens,
                "cache_write_tokens": normalized.cache_write_tokens,
                "reasoning_tokens": normalized.reasoning_tokens,
                "cache_read_observed": cache_read_usage_observed(
                    usage, provider=provider, api_mode=api_mode,
                ),
                "cache_write_observed": cache_write_usage_observed(
                    usage, provider=provider, api_mode=api_mode,
                ),
            }
        except (ImportError, AttributeError, TypeError, ValueError):
            pass
    if not isinstance(usage, dict):
        usage = {
            "input_tokens": getattr(usage, "input_tokens", getattr(usage, "prompt_tokens", 0)),
            "output_tokens": getattr(usage, "output_tokens", getattr(usage, "completion_tokens", 0)),
            "total_tokens": getattr(usage, "total_tokens", 0),
        }
    input_tokens = int(usage.get("input_tokens", usage.get("prompt_tokens", 0)) or 0)
    output_tokens = int(usage.get("output_tokens", usage.get("completion_tokens", 0)) or 0)
    total_tokens = int(usage.get("total_tokens", input_tokens + output_tokens) or 0)
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
        "cache_read_tokens": None,
        "cache_write_tokens": None,
        "reasoning_tokens": None,
        "cache_read_observed": False,
        "cache_write_observed": False,
    }

def _safe_endpoint(services, value: Any) -> str | None:
    """Keep route identity while dropping credentials, query strings, and fragments."""
    if not value:
        return None
    try:
        parsed = urlsplit(str(value))
        host = parsed.hostname or ""
        if not parsed.scheme or not host:
            return None
        if parsed.port:
            host = f"{host}:{parsed.port}"
        return urlunsplit((parsed.scheme, host, parsed.path, "", ""))
    except (TypeError, ValueError):
        return None

def _check_budgets(services, contract: dict[str, Any], state: dict[str, Any], *, before_model: bool = False) -> None:
    checks = (
        ("model_calls", "model_call_budget", "TE_MODEL_CALL_BUDGET"),
        ("total_tokens", "token_budget", "TE_TOKEN_BUDGET"),
        ("processing_seconds", "processing_time_budget_seconds", "TE_PROCESSING_BUDGET"),
        ("retry_count", "retry_budget", "TE_RETRY_BUDGET"),
    )
    for actual_key, budget_key, code in checks:
        budget = contract.get(budget_key)
        actual = state.get(actual_key, 0)
        if not isinstance(budget, (int, float)) or isinstance(budget, bool):
            continue
        exceeded = actual >= budget if before_model and actual_key == "model_calls" else actual > budget
        if exceeded:
            services._hard_stop(code, f"{actual_key}={actual} budget={budget}", state)

def _llm_execution_guard(services, request: dict[str, Any], next_call, **context: Any) -> Any:
    task_id = services._governed_task_id(context)
    contract = services._active_contract(task_id, context.get("board"))
    decision = services.enforcement_decision(contract, services._settings())
    if not task_id or contract.get("work_class") not in {
        "direct_lookup", "single_owner", "parallel",
    }:
        return next_call(request)
    state = services._runtime(task_id)
    state["retry_count"] = max(int(context.get("retry_count") or 0), int(state["retry_count"]))
    state["trusted_fields"].update({"model_calls", "retry_count"})
    if decision["hard"]:
        services._check_budgets(contract, state, before_model=True)
    state["model_calls"] += 1
    route = {
        "attempt_number": int(state["model_calls"]),
        "provider": request.get("provider"),
        "model": request.get("model"),
        "api_mode": request.get("api_mode"),
        "endpoint": services._safe_endpoint(request.get("base_url") or request.get("endpoint")),
        "authentication_path": request.get("authentication_path") or request.get("auth_mode"),
        "reasoning_setting": request.get("reasoning_effort") or request.get("reasoning"),
    }
    # Keep only safe routing metadata; credentials and prompt content are never copied.
    state["model_routes"].append(route)
    state["trusted_fields"].add("model_routes")
    started = time.monotonic()
    try:
        result = next_call(request)
    finally:
        state["processing_seconds"] += max(0.0, time.monotonic() - started)
        state["trusted_fields"].add("processing_seconds")
    usage_fields = services._usage(result)
    raw_usage = result.get("usage") if isinstance(result, dict) else getattr(result, "usage", None)
    if raw_usage is not None:
        state["input_tokens"] += int(usage_fields["input_tokens"] or 0)
        state["output_tokens"] += int(usage_fields["output_tokens"] or 0)
        state["total_tokens"] += int(usage_fields["total_tokens"] or 0)
        state["trusted_fields"].update({"input_tokens", "output_tokens", "total_tokens"})
        for field in ("cache_read_tokens", "cache_write_tokens", "reasoning_tokens"):
            value = usage_fields.get(field)
            if value is not None:
                state[field] += int(value)
                state["trusted_fields"].add(field)
        if not usage_fields.get("cache_read_observed"):
            state["cache_read_complete"] = False
        else:
            state["trusted_fields"].add("cache_read_complete")
        if not usage_fields.get("cache_write_observed"):
            state["cache_write_complete"] = False
        else:
            state["trusted_fields"].add("cache_write_complete")
        response_id = (
            result.get("id") if isinstance(result, dict) else getattr(result, "id", None)
        )
        if response_id:
            state["model_attempt_ids"].append(str(response_id))
            state["trusted_fields"].add("model_attempt_ids")
    if decision["hard"]:
        services._check_budgets(contract, state)
    return result

def _on_claim(services, *, task_id: str, board: str | None = None, run_id: int | None = None, **_: Any) -> None:
    contract = services._task_contract(task_id, board)
    if not services.enforcement_decision(contract, services._settings())["hard"]:
        return
    key = str(contract.get("idempotency_key") or "")
    if not key:
        return
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    conn = kbc.connect(board=board)
    try:
        rows = conn.execute(
            "SELECT id, created_at, status FROM tasks WHERE idempotency_key = ? "
            "AND status IN ('todo','ready','running','blocked','review','triage','scheduled') "
            "ORDER BY created_at ASC, id ASC",
            (key,),
        ).fetchall()
        if len(rows) <= 1 or str(rows[0]["id"]) == str(task_id):
            return
        canonical_id = str(rows[0]["id"])
        kb.block_task(
            conn, str(task_id),
            reason=f"TE_DUPLICATE_OWNER: canonical_task_id={canonical_id}",
            kind="capability", expected_run_id=run_id,
        )
    finally:
        conn.close()
