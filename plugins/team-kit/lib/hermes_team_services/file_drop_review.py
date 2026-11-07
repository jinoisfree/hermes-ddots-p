"""Local-only nightly drop statistics and consolidation into existing learned rules.

No model, network, owner document, fact store or conversation digest writes. The
source is explicitly statistics, never a fabricated Slack message or session.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hermes_team_services import learning
from hermes_team_services.file_drop_suggest import profiles_for, secret

LABELS = {"reveal": "Finder에서 보기", "copy_text": "글자 복사", "summarize": "세 줄 요약", "extract_todos": "할 일 뽑아 정리", "add_schedule": "날짜를 일정에", "attach_work": "업무에 붙이기", "file_away": "업무 폴더에 정리", "compare": "비교해서 정리", "explain": "무슨 내용인지 설명"}


def normalized(text):
    return re.sub(r"[\W_]", "", text, flags=re.UNICODE).casefold()


def rows(doc, prefix, now):
    cutoff = doc["entries"].get("clear", {}).get("at", 0)
    for key, entry in doc["entries"].items():
        if key.startswith(prefix) and entry.get("v") and entry["at"] > cutoff:
            row = json.loads(entry["v"])
            if cutoff < row.get("at", now) <= now:
                yield key, row


def candidate(home, feature, kind, action, evidence, *, profile, instruction=None, works=()):
    """Stable topic updates the existing reviewable rule, without invented quotes."""
    key = hashlib.sha256(json.dumps([feature, kind, action], ensure_ascii=False).encode()).hexdigest()[:24]
    topic = "ddots-" + key
    word = instruction if instruction else LABELS.get(action)
    if not word:
        return False
    verb = {"prefer": "우선 제안", "avoid": "먼저 제안하지 않음", "correct": "처리 결과에 맞춰 제안", "opinion": "승인 뒤 내 지시로 제안", "method": "처리 방식으로 제안"}[kind]
    rule = f"특징 {feature}: {word} — {verb}."
    if works:
        rule += " 연결 업무: " + ", ".join(works)
    rule = rule[:500]
    if secret(rule):
        return False
    signature = hashlib.sha256(json.dumps(sorted(evidence)).encode()).hexdigest()
    with learning.locked(learning.path(home)):
        data = learning.load(home)
        previous = data["rules"].get(topic)
        # A refusal remains refused until new evidence arrives. Reviews preserve
        # source in history, so inspect both current and historical candidates.
        ancestors = ([previous] + list(reversed(previous.get("history", [])))) if previous else []
        if any(p.get("source", {}).get("evidence") == signature for p in ancestors):
            return False
        quote = instruction or f"끌어놓기 통계 {kind}: {len(evidence)}건"
        src = {"origin": "ddots-drop-review", "feature": feature, "kind": kind,
               "profile": profile, "evidence": signature, "text": quote}
        if instruction:
            src["instruction"] = instruction
        # change validates strings and appends the normal report/rollback events.
        learning.change(data, topic, rule, "remember", src, quote, via="ddots-drop-review")
        learning.persist(home, data)
    return True


def approved(home):
    result = {}
    for topic, row in learning.load(home)["rules"].items():
        src, review = row.get("source", {}), row.get("review", {})
        if (row.get("active") and src.get("origin") == "ddots-drop-review"
                and src.get("kind") == "opinion" and review.get("status") == "kept"):
            result["c:" + topic] = {"v": json.dumps({"feature": src["feature"], "instruction": src["instruction"], "profile": src["profile"]}, ensure_ascii=False, sort_keys=True),
                                    "at": review["at"], "by": "drop-review"}
    return result


def review(root, *, now=None):
    root = Path(root); now = time.time() if now is None else now
    profiles = profiles_for(root)
    work = next((p for p, v in profiles.items() if "work" in v["roles"]), None)
    count = 0
    for file in sorted((root / "state/ddots-file-drop").glob("*.json")):
        # Same flock filename as the Swift store, held through read/modify/atomic save.
        # learning.locked uses .lock replacing suffix; append .json so it locks
        # exactly <user>.json.lock rather than a separate <user>.lock.
        with learning.locked(Path(str(file) + ".json")):
            doc = json.loads(file.read_text())
            for key, row in list(rows(doc, "h:", now)):
                if now - row["at"] > 90 * 86400 and row.get("opinion"):
                    row.pop("opinion", None)
                    doc["entries"][key] = {"v": json.dumps(row, ensure_ascii=False), "at": now, "by": "drop-review"}
            grouped = defaultdict(list)
            for key, row in rows(doc, "h:", now):
                grouped[row["feature"]].append((key, row))
            if work:
                for feature, records in grouped.items():
                    chosen = Counter(r.get("chosen") for _, r in records if r.get("chosen"))
                    shown = Counter(a for _, r in records for a in set(r["shown"]))
                    corrected = defaultdict(list); opinions = defaultdict(list)
                    for key, row in records:
                        action = row.get("result")
                        if action in LABELS and action != row.get("chosen"):
                            corrected[action].append(key)
                        if row.get("opinion"):
                            opinions[normalized(row["opinion"])].append((key, row["opinion"]))
                    for action in LABELS:
                        if chosen[action] >= 3 and chosen[action] / max(1, sum(chosen.values())) >= .7:
                            count += candidate(root / "profiles" / work, feature, "prefer", action, [k for k, r in records if r.get("chosen") == action], profile=work)
                        if shown[action] >= 3 and chosen[action] == 0:
                            count += candidate(root / "profiles" / work, feature, "avoid", action, [k for k, r in records if action in r["shown"]], profile=work)
                        if len(corrected[action]) >= 2:
                            count += candidate(root / "profiles" / work, feature, "correct", action, corrected[action], profile=work)
                    for canonical, items in opinions.items():
                        if canonical and len(items) >= 2:
                            count += candidate(root / "profiles" / work, feature, "opinion", canonical, [k for k, _ in items], profile=work, instruction=items[0][1])
            cutoff = doc["entries"].get("clear", {}).get("at", 0)
            for key, row in list(rows(doc, "short:", now)):
                if now - row["at"] < 48 * 3600:
                    continue
                try:
                    profile = row["profile"]
                    if profile not in profiles:
                        raise ValueError("unconfigured_profile")
                    action = row.get("result") if row.get("result") in LABELS else row.get("action")
                    if action in LABELS:
                        count += candidate(root / "profiles" / profile, row["feature"], "method", action, [key], profile=profile, works=row.get("works", []))
                    doc["entries"][key] = {"at": now, "by": "drop-review"}
                except (ValueError, OSError):
                    if now - row["at"] > 7 * 86400:
                        doc["entries"][key] = {"at": now, "by": "drop-review"}
            customs = {}
            for profile in profiles:
                customs.update(approved(root / "profiles" / profile))
            for key, entry in list(doc["entries"].items()):
                if key.startswith("c:") and entry.get("v") and key not in customs:
                    doc["entries"][key] = {"at": now, "by": "drop-review"}
            for key, entry in customs.items():
                old = doc["entries"].get(key, {})
                if entry["at"] > max(cutoff, old.get("at", 0)):
                    doc["entries"][key] = entry
            learning.save(file, doc)
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    args = parser.parse_args()
    # Diagnostics are counts/errors only, never records, filenames or summaries.
    try:
        print(json.dumps({"rules_changed": review(args.home)}))
    except Exception as exc:
        print(json.dumps({"error": type(exc).__name__}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
