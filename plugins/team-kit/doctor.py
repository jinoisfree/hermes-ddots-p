"""Read-only daily deployment checks. Only our state and a confirmed report are written.

No repairs, restarts, token refreshes, model calls or network health probes. Reports use
the same learning_report.slack -> slack_blocks path as error_digest. Raw subprocess
output, credential values and exception messages never enter state or Slack.
"""
from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

KST = ZoneInfo("Asia/Seoul")
PROFILES = ("default", "sns-manager", "personal-secretary", "system-doctor", "research-assistant", "work-assistant")
CHANNEL = "REPLACE_SLACK_ID"
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:[+-]\d{2}:\d{2}|Z)?)")


def managed(label):
    return label.startswith(("ai.hermes.", "com.starter_user."))


def item(name, ok, detail, fix=None):
    result = {"id": name, "status": "ok" if ok else "broken", "detail": detail}
    if fix:
        result["fix"] = fix
    return result


def run_command(argv):
    # A fixed argv, no shell. --check commands do not repair or refresh credentials.
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True, timeout=60)


def launchd_rows(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and managed(fields[2]):
            result[fields[2]] = int(fields[1])
    return result


def launchd_files(folder):
    result = set()
    for path in Path(folder).glob("*.plist"):
        if not managed(path.stem):
            continue
        data = plistlib.loads(path.read_bytes())
        label = data.get("Label", "")
        if not managed(label):
            raise ValueError("invalid managed label")
        result.add(label)
    return result


def check_launchd(folder, runner):
    loaded = runner(["/bin/launchctl", "list"])
    if loaded.returncode:
        raise RuntimeError("launchctl unavailable")
    rows = launchd_rows(loaded.stdout)
    missing = launchd_files(folder) - rows.keys()
    failed = [label for label, code in rows.items() if code != 0]
    return item("launchd", not (missing or failed), f"미로드 {len(missing)}건 · 종료 코드 비0 {len(failed)}건")


def check_copies(root, runner):
    outcomes = [runner([root / "bin" / name, "--check"]).returncode
                for name in ("hermes-plugin-copies", "hermes-secretary-skills")]
    failed = sum(code != 0 for code in outcomes)
    return item("copies", not failed, f"플러그인 검사 종료 {outcomes[0]} · 공통 스킬 검사 종료 {outcomes[1]}",
                "~/.hermes/bin/hermes-plugin-copies; ~/.hermes/bin/hermes-secretary-skills" if failed else None)


def homes(root):
    return [root, *[root / "profiles" / p for p in PROFILES if p != "default"]]


def check_clones(root, runner):
    heads = []
    for home in homes(root):
        result = runner(["git", "-C", home / "plugins/claude-subscription-directsdk-experimental", "rev-parse", "HEAD"])
        head = result.stdout.strip()
        if result.returncode or not re.fullmatch(r"[0-9a-f]{40}", head):
            raise ValueError("clone HEAD unavailable")
        heads.append(head)
    equal = len(set(heads)) == 1
    return item("clones", equal, f"구독 플러그인 6개 클론 HEAD {'일치' if equal else '불일치'}")


def stamp(line):
    match = STAMP.match(line)
    if not match:
        return None
    value = datetime.fromisoformat(match[1].replace(",", "."))
    return value.replace(tzinfo=KST) if value.tzinfo is None else value.astimezone(KST)


def gateway_status(log, errors, now):
    connected, started = set(), False
    for line in log:
        if "Starting Hermes Gateway..." in line or "Hermes Gateway Starting..." in line:
            connected, started = set(), True
        match = re.search(r"✓ (slack|photon) connected(?: \(profile: ([\w-]+)\))?$", line.strip())
        if started and match:
            connected.add((match[1], match[2] or "default"))
        disconnected = re.search(r"✓ (slack|photon) disconnected.*?(?:\(profile: ([\w-]+)\))?$", line.strip())
        if disconnected:
            connected.discard((disconnected[1], disconnected[2] or "default"))
        if "Stopping gateway" in line:
            connected.clear()
    count, undated, current = 0, 0, None
    for line in errors:
        current = stamp(line) or current
        if current is None:
            undated += int(bool(line.strip()))
        elif now - timedelta(hours=24) <= current <= now:
            count += int(bool(line.strip()))
    expected = {("slack", p) for p in PROFILES} | {("photon", "default")}
    missing = expected - connected
    ok = started and not missing and count == 0 and undated == 0
    detail = f"최근 시작 이후 연결 {len(expected & connected)}/7 · 오류 로그 24시간 {count}줄 · 시각 불명 {undated}줄"
    return item("gateway", ok, detail)


def check_gateway(root, now):
    # Stream the complete logs: no clipped tail can silently hide the last startup or errors.
    with (root / "logs/gateway.log").open(errors="replace") as log, (root / "logs/gateway.error.log").open(errors="replace") as errors:
        return gateway_status(log, errors, now)


def credential_keys(path, required):
    # Dedicated health check may parse credentials locally; values never leave this function.
    if path.is_symlink() or not path.is_file():
        return False
    data = json.loads(path.read_text())
    return isinstance(data, dict) and required <= data.keys()


def check_credentials(root):
    google = {"token", "refresh_token", "client_id", "client_secret", "token_uri"}
    cases = [(root / "google_token.json", google),
             (root / "profiles/personal-secretary/google_token.json", google),
             (root / "auth.json", {"version", "credential_pool", "providers"})]
    valid = 0
    for path, keys in cases:
        try:
            valid += credential_keys(path, keys)
        except (ValueError, OSError):
            pass
    return item("credentials", valid == 3, f"자격 파일 JSON·필수 키 이름 확인 {valid}/3 (값·유효성·만료 여부는 출력하지 않음)")


def parse_time(value):
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.replace(tzinfo=KST) if parsed.tzinfo is None else parsed.astimezone(KST)


def overdue(job, now):
    anchor = parse_time(job.get("last_run_at") or job.get("created_at"))
    schedule = job.get("schedule") or {}
    if anchor is None:
        raise ValueError("missing cron time")
    kind = schedule.get("kind")
    if kind == "interval":
        minutes = schedule.get("minutes")
        # Hermes persists interval schedules in minutes.
        if not isinstance(minutes, (float, int)) or minutes <= 0:
            raise ValueError("invalid interval")
        return now > anchor + timedelta(minutes=3 * minutes)
    if kind == "cron":
        from croniter import croniter
        iterator = croniter(schedule["expr"], anchor)
        third = [iterator.get_next(datetime) for _ in range(3)][-1]
        return now > third
    if kind == "once":
        return False  # No repeating interval to multiply.
    raise ValueError("unknown schedule")


def check_cron(root, now):
    active, failed, late, unreadable = 0, 0, 0, 0
    for home in homes(root):
        path = home / "cron/jobs.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        for job in data["jobs"]:
            if job.get("enabled") is not True:
                continue
            active += 1
            failed += job.get("last_status") in {"failed", "failure", "error", "timeout"}
            try:
                late += overdue(job, now)
            except Exception:
                unreadable += 1
    return item("cron", not (failed or late or unreadable),
                f"활성 예약 {active}개 · 마지막 실패 {failed}개 · 3회 간격 초과 {late}개 · 판정 실패 {unreadable}개")


def check_pending(root):
    count = len(list((root / "installs").glob("*/source-completion-pending")))
    return item("pending", count == 0, f"업데이트 마무리 대기 {count}개", "hermes" if count else None)


def inventory_labels(text):
    return {m[1] for m in re.finditer(r"^\| `((?:ai\.hermes\.|com\.starter_user\.)[^`]+)` \|", text, re.M)}


def check_inventory(document, agents):
    expected, actual = inventory_labels(document.read_text()), launchd_files(agents)
    missing, stale = actual - expected, expected - actual
    return item("inventory", not (missing or stale), f"작업 목록 누락 {len(missing)}개 · 없는 작업 기재 {len(stale)}개")


def collect(root, agents, document, now, runner=run_command):
    # Diagnosis health readers return raw log kinds and broader source lists. These narrow
    # checks use the same timestamp/launchctl formats but keep only counts and fixed text.
    checks = {
        "launchd": lambda: check_launchd(agents, runner), "copies": lambda: check_copies(root, runner),
        "clones": lambda: check_clones(root, runner), "gateway": lambda: check_gateway(root, now),
        "credentials": lambda: check_credentials(root), "cron": lambda: check_cron(root, now),
        "pending": lambda: check_pending(root), "inventory": lambda: check_inventory(document, agents),
    }
    result = []
    for name, check in checks.items():
        try:
            result.append(check())
        except Exception:
            result.append(item(name, False, "점검 실패 (원문·예외 내용 생략)"))
    return result


def changes(previous, current):
    before = {x["id"]: x for x in previous or []}
    broken = [x for x in current if x["status"] == "broken" and before.get(x["id"], {}).get("status") != "broken"]
    recovered = [x for x in current if x["status"] == "ok" and before.get(x["id"], {}).get("status") == "broken"]
    return broken, recovered


def format_report(broken, recovered):
    if not broken and not recovered:
        return ""
    title = f"*🔴 매일 점검: 새 문제 {len(broken)}건*" if broken else f"*🟢 매일 점검: 회복 {len(recovered)}건*"
    lines = [title]
    for label, rows in (("새 문제", broken), ("회복", recovered)):
        if rows:
            lines.append(f"\n*{label}*")
            for row in rows:
                lines.append(f"  • {'☐' if label == '새 문제' else '✅'} `{row['id']}`: {row['detail']}")
                if row.get("fix"):
                    lines.append(f"    ↳ 확인 뒤 실행: `{row['fix']}`")
    return "\n".join(lines)


def atomic_state(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("symlink state")
    fd, temporary = tempfile.mkstemp(prefix=".doctor-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(data, stream, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def deliver(home, text):
    spec = importlib.util.spec_from_file_location("doctor_report", Path(__file__).with_name("learning_report.py"))
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    return report.slack(home, "chat.postMessage", {"channel": CHANNEL, "text": text,
                                                  "unfurl_links": False, "unfurl_media": False})


def prepare(root, home, agents, document, *, now=None, runner=run_command):
    """Read health and its last confirmed baseline without writing or sending."""
    now = now or datetime.now(KST)
    path = home / "watcher-state/doctor.json"
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("symlink state")
    previous = json.loads(path.read_text()).get("items") if path.exists() else None
    current = collect(root, agents, document, now, runner)
    broken, recovered = changes(previous, current)
    return {"state": {"ranAt": now.isoformat(), "items": current},
            "broken": broken, "recovered": recovered}


def run(root, home, agents, document, *, dry_run=False, now=None, runner=run_command):
    now = now or datetime.now(KST)
    state_path = home / "watcher-state/doctor.json"
    if state_path.is_symlink() or state_path.parent.is_symlink():
        raise ValueError("symlink state")

    def inspect_and_report():
        prepared = prepare(root, home, agents, document, now=now, runner=runner)
        text = format_report(prepared["broken"], prepared["recovered"])
        result = {**prepared["state"], "wakeAgent": bool(text)}
        if dry_run:
            return result, text
        if text:
            receipt = deliver(home, text)
            if not (isinstance(receipt, dict) and receipt.get("ok") is True and receipt.get("ts")
                    and receipt.get("channel") == CHANNEL):
                raise ValueError("report delivery unconfirmed")
        # Leave the old baseline on delivery failure so the new problem remains visible.
        atomic_state(state_path, prepared["state"])
        return result, ""

    if dry_run:
        return inspect_and_report()
    state_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(state_path.with_suffix(".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("nonregular lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        return inspect_and_report()


def main(argv=None, *, root=None, home=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="출력만 확인; Slack·상태 저장 없음")
    args = parser.parse_args(argv)
    root = Path(root) if root else Path.home() / ".hermes"
    home = Path(home) if home else root / "profiles/system-doctor"
    document = Path.home() / "workspace/Hermes-desktop-pet/백그라운드-작업-목록.md"
    try:
        result, text = run(root, home, Path.home() / "Library/LaunchAgents", document, dry_run=args.dry_run)
        if args.dry_run:
            print(json.dumps(result, ensure_ascii=False))
            if text:
                print(text)
        # Delivery already uses slack_blocks. Suppress cron's second delivery and model turn.
        print(json.dumps({"wakeAgent": False}))
        return 0
    except Exception as exc:
        print(json.dumps({"wakeAgent": False, "error": type(exc).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
