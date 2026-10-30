"""주말·공휴일 아침 보고 11:00 (2026-10-27 사용자 결정).

On Saturdays, Sundays and Korean public holidays the morning reports go out at 11:00 instead of
their usual 08:29~10:00. Holidays come from Google's public 대한민국 공휴일 calendar read with the
root (company) Google token; only entries described as 공휴일 count (기념일 such as 국군의날 or
크리스마스 이브 do not). The list is cached in ``~/.hermes/shared/holidays.json`` for a week, the
cache is used when Google cannot be reached, and without any list only weekends count.

Two ways to use it:

  start(now, (8, 30))           reports that poll every few minutes (learning/skill reports):
                                the earliest send time today, (11, 0) on a rest day
  gate(key, now, workday=..., rest=..., always=...)
                                Hermes cron jobs and launchd jobs fired at both the usual time and
                                11:00: True once per day at the right one, within WINDOW minutes
                                after it (a late launchd/cron wake still counts)

Command line: ``rest_day.py gate KEY --workday 08:40 --rest 11:00 [--always 18:00]`` exits 0 when
the run may go ahead, 3 when it must stay quiet; ``rest_day.py today`` prints today's verdict.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import time
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

KST = ZoneInfo("Asia/Seoul")
REST_START = (11, 0)
WINDOW = 59
CACHE_DAYS = 7
HOLIDAY_CALENDAR = "ko.south_korea#holiday@group.v.calendar.google.com"
QUIET = 3


def root():
    return Path(os.environ.get("HERMES_ROOT") or Path.home() / ".hermes")


def shared():
    return root() / "shared"


# ---- holidays ----------------------------------------------------------------------------------
def fetch(years):
    """{YYYY-MM-DD: 이름} of 공휴일 for the given years from Google's public holiday calendar."""
    if os.environ.get("HERMES_REST_DAY_OFFLINE") == "1":
        raise RuntimeError("holiday lookup disabled")
    try:
        import googleapiclient  # noqa: F401
    except ImportError:
        import hermes_bootstrap  # noqa: F401  launchd's base Python -> the installed environment
    import importlib.util
    base = root()
    spec = importlib.util.spec_from_file_location(
        "rest_day_google_api", base / "hermes-agent/skills/productivity/google-workspace/scripts/google_api.py")
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    api.HERMES_HOME = base
    api.TOKEN_PATH = base / "google_token.json"
    api.CLIENT_SECRET_PATH = base / "google_client_secret.json"
    service = api.build_service("calendar", "v3")
    found, page = {}, None
    while True:
        response = service.events().list(
            calendarId=HOLIDAY_CALENDAR, singleEvents=True, orderBy="startTime", maxResults=250, pageToken=page,
            timeMin=f"{min(years)}-01-01T00:00:00+09:00", timeMax=f"{max(years) + 1}-01-01T00:00:00+09:00").execute()
        for event in response.get("items", []):
            day = (event.get("start") or {}).get("date")
            if day and str(event.get("description") or "").startswith("공휴일"):
                found[day] = event.get("summary", "")
        page = response.get("nextPageToken")
        if not page:
            return found


def holidays(today, *, fetcher=fetch, now=None):
    """(holiday dict, source) — fresh Google list, the cached list, or none."""
    now = time.time() if now is None else now
    path = shared() / "holidays.json"
    try:
        cached = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cached = {}
    years = [today.year, today.year + 1]
    fresh = (now - float(cached.get("fetched_at") or 0) < CACHE_DAYS * 86400
             and all(str(y) in (cached.get("years") or []) for y in years))
    if fresh:
        return cached.get("days") or {}, "cache"
    try:
        days = fetcher(years)
    except Exception as exc:
        print(f"rest_day: holiday fetch failed ({type(exc).__name__}); using cache", file=sys.stderr)
        return cached.get("days") or {}, "stale_cache" if cached else "none"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"fetched_at": now, "years": [str(y) for y in years], "days": days},
                              ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)
    return days, "google"


def verdict(day, *, fetcher=fetch, now=None):
    days, source = holidays(day, fetcher=fetcher, now=now)
    name = days.get(day.isoformat())
    if day.weekday() >= 5:
        return {"rest": True, "reason": "주말" + (f"·{name}" if name else ""), "source": source}
    if name:
        return {"rest": True, "reason": name, "source": source}
    return {"rest": False, "reason": "평일", "source": source}


def is_rest(day, **kw):
    return verdict(day, **kw)["rest"]


# ---- polling reports ---------------------------------------------------------------------------
def start(now, usual, **kw):
    """Earliest (hour, minute) a once-a-day report may go out today."""
    now = now.astimezone(KST)
    return max(usual, REST_START) if is_rest(now.date(), **kw) else usual


# ---- fired-twice jobs --------------------------------------------------------------------------
def _hm(value):
    hour, minute = str(value).split(":")
    return int(hour), int(minute)


@contextmanager
def _locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_suffix(".lock"), "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def gate(key, now, *, workday, rest, always=(), **kw):
    """True when this fire is today's one run for ``key``. Records it so a second fire stays quiet."""
    now = now.astimezone(KST)
    today = now.date()
    minutes = now.hour * 60 + now.minute

    def due(slots):
        for slot in slots:
            hour, minute = _hm(slot)
            if 0 <= minutes - (hour * 60 + minute) <= WINDOW:
                return slot
        return None

    slot = due(always) or due(rest if is_rest(today, **kw) else workday)
    if slot is None:
        return False
    path = shared() / "rest-day-gate.json"
    with _locked(path):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        mark = f"{today.isoformat()} {slot}"
        if data.get(key) == mark:
            return False
        data[key] = mark
        cutoff = (today - timedelta(days=7)).isoformat()
        data = {k: v for k, v in data.items() if str(v)[:10] >= cutoff}
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, path)
    return True


def wrap(key, script, *, workday, rest, always=(), inner=None, now=None, retry_state=None):
    """Body of a profile ``scripts/*_restday.py``: quiet ``{"wakeAgent": false}`` unless this fire is
    today's run, else the job's original pre-script (same argv, stdout and exit code)."""
    now = now or datetime.now(KST)
    retry = False
    if retry_state:
        # Only the receipt-aware morning outbox opts in; ordinary agent jobs are never replayed.
        path = Path(retry_state)
        if path.exists():
            pending = json.loads(path.read_text())
            threshold = start(now, tuple(map(int, workday[0].split(':'))))
            last = pending.get('last_attempt_at')
            retry = (not pending.get('complete') and bool(pending.get('parts'))
                     and (now.hour, now.minute) >= threshold
                     and pending.get('attempts', {}).get(now.date().isoformat(), 0) < 3
                     and (not last or (now - datetime.fromisoformat(last)).total_seconds() >= 300))
    if not gate(key, now, workday=workday, rest=rest, always=always) and not retry:
        print(json.dumps({"wakeAgent": False, "reason": "rest_day_schedule"}))
        return 0
    if inner:
        import runpy
        runpy.run_path(str(Path(script).resolve().with_name(inner)), run_name="__main__")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="주말·공휴일 아침 보고 시각")
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("gate")
    g.add_argument("key")
    g.add_argument("--workday", action="append", default=[])
    g.add_argument("--rest", action="append", default=[])
    g.add_argument("--always", action="append", default=[])
    sub.add_parser("today")
    args = parser.parse_args(argv)
    now = datetime.now(KST)
    if args.command == "today":
        print(json.dumps({"date": now.date().isoformat(), **verdict(now.date())}, ensure_ascii=False))
        return 0
    return 0 if gate(args.key, now, workday=args.workday, rest=args.rest, always=args.always) else QUIET


if __name__ == "__main__":
    raise SystemExit(main())
