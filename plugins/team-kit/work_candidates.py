"""Numbered proposals inside existing team-work checkpoints; never grants approval.

The report and later selection reuse ONE case, including its successful/uncertain
write receipts. Only the next selected target is returned with its full specification.
"""
from __future__ import annotations

import copy
import json
import re
import time

KINDS = ("notion", "notes", "deadline", "common_work")
CACHE_CHARS = 40_000
NOTE = ("번호 후보는 보고 전에 team_work(offer)에 번호·대상 ID·정확한 반영 문구·마감·메일 ID와 최소 발췌·근거 영수증을 저장한다. "
        "번호 선택은 start(candidate_case_id, selection)로 같은 장부를 이어간다. 장부는 승인이 아니다. "
        "현재 next_candidate 한 대상만 원문 1회 조회 → 쓰기 → 재조회 검증 → item_checkpoint(stage=verified)로 끝내고 다음 대상으로 간다. "
        "read/written 상태는 실제 도구 성공 영수증으로 자동 저장된다. dismiss 선택은 stage=dismiss로 후보만 닫는다. "
        "전체 후보의 본문을 먼저 모으거나 이미 성공한 쓰기를 반복하지 않는다. 캐시된 원문은 read(item_number)로 복구한다. "
        "스킬 전문이 현재 컨텍스트에 남아 있으면 파일별 1회 로드를 재사용한다. 압축으로 전문이 사라졌거나 파일이 바뀌면 기존 필수 스킬 검사를 따른다. "
        "메일 알림의 mail_work 후보·[[버튼]] 규칙, 수정·삭제·발송 승인과 배경 쓰기 거부는 그대로다.")


def _text(value, name, limit, *, empty=False):
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise ValueError(f"{name}: bounded text required (max {limit}).")
    return value


def offer(work, args):
    if work.get("candidates"):
        raise ValueError("This case already has a numbered offer; do not renumber or replace it.")
    rows = args.get("candidates")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 20:
        raise ValueError("Offer 1–20 numbered candidates.")
    valid = {r["tool_call_id"] for r in work["receipts"] if r["status"] == "success" and not r["write"]}
    result, numbers = [], set()
    for row in rows:
        if not isinstance(row, dict) or type(row.get("number")) is not int or not 1 <= row["number"] <= 99 or row["number"] in numbers:
            raise ValueError("Use unique candidate numbers (1–99).")
        numbers.add(row["number"])
        title = _text(row.get("title"), "title", 200)
        evidence = row.get("evidence_ids")
        if not isinstance(evidence, list) or not evidence or any(i not in valid for i in evidence):
            raise ValueError("Candidate evidence must be successful read receipts in this case.")
        sources = row.get("sources")
        if not isinstance(sources, list) or not 1 <= len(sources) <= 10:
            raise ValueError("Include source IDs and a minimal excerpt or body hash.")
        normalized_sources = []
        for src in sources:
            if not isinstance(src, dict):
                raise ValueError("Each source must be an object.")
            digest = _text(src.get("body_hash", ""), "body_hash", 64, empty=True)
            excerpt = _text(src.get("excerpt", ""), "excerpt", 2000, empty=True)
            if not excerpt.strip() and not re.fullmatch(r"[a-f0-9]{64}", digest):
                raise ValueError("Include an excerpt or SHA-256 body hash; an ID alone is insufficient.")
            normalized_sources.append({"id": _text(src.get("id"), "source ID", 500),
                                       "account": _text(src.get("account", ""), "account", 200, empty=True),
                                       "excerpt": excerpt, "body_hash": digest})
        targets = row.get("targets")
        if not isinstance(targets, list) or not 1 <= len(targets) <= len(KINDS):
            raise ValueError("Include 1–4 target specifications.")
        normalized_targets, seen = [], set()
        for target in targets:
            if not isinstance(target, dict):
                raise ValueError("Each target must be an object.")
            kind = target.get("kind")
            if kind not in KINDS or kind in seen:
                raise ValueError("Use one target per kind in a candidate.")
            seen.add(kind)
            operation = target.get("operation")
            if operation not in {"create", "update", "complete", "close"}:
                raise ValueError("Use create/update/complete/close.")
            normalized_targets.append({"kind": kind, "id": _text(target.get("id"), "target ID (parent ID for create)", 500),
                                       "operation": operation,
                                       "text": _text(target.get("text"), "exact text/change", 12_000),
                                       "due": _text(target.get("due", ""), "due", 100, empty=True),
                                       "state": "pending", "checkpoints": []})
        result.append({"number": row["number"], "title": title, "sources": normalized_sources,
                       "evidence_ids": list(dict.fromkeys(evidence)), "targets": normalized_targets})
    work["candidates"] = result
    work["candidate_report"] = {k: copy.deepcopy(work.get(k)) for k in ("goal", "scope", "plan", "done_when")}


def select(work, args, src):
    if any(work["source"].get(k) != src.get(k) for k in ("chat_id", "thread_id")):
        raise ValueError("Number selection belongs to the original report thread.")
    if work.get("candidate_selection") and any(t["state"] not in {"verified", "dismissed"} for _, t in selected(work)):
        raise ValueError("Resume the existing selection; do not replace its checkpoints.")
    rows = args.get("selection")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 20:
        raise ValueError("Specify the owner's selected numbers and destination kinds.")
    candidates = {r["number"]: r for r in work.get("candidates", [])}
    result, seen = [], set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Each selection must be an object.")
        number = row.get("number")
        if type(number) is not int or number not in candidates or number in seen:
            raise ValueError("Select unique numbers from this offer.")
        if not re.search(r"(?<!\d)" + str(number) + r"(?:번)?(?!\d)", args.get("user_said", "")):
            raise ValueError("Each selected number must appear in the verified current owner quote.")
        seen.add(number)
        kinds = row.get("kinds", [])
        allowed = {t["kind"] for t in candidates[number]["targets"]}
        dismiss = row.get("dismiss") is True
        if not isinstance(kinds, list) or len(kinds) != len(set(kinds)) or any(k not in allowed for k in kinds):
            raise ValueError("Select only offered destination kinds.")
        if dismiss == bool(kinds):
            raise ValueError("Select destination kinds OR dismiss=true, never both.")
        result.append({"number": number, "kinds": kinds, "dismiss": dismiss})
    work["candidate_selection"] = result
    work["candidate_request"] = {k: src.get(k) for k in ("session_id", "message_id", "platform_message_id", "at")}
    work["candidate_started_at"] = time.time()


def selected(work):
    by_number = {r["number"]: r for r in work.get("candidates", [])}
    for choice in work.get("candidate_selection", []):
        item = by_number[choice["number"]]
        if choice.get("dismiss"):
            yield item, item.setdefault("dismissal", {"kind": "dismiss", "state": "pending", "checkpoints": []})
        else:
            for target in item["targets"]:
                if target["kind"] in choice["kinds"]:
                    yield item, target


def current(work):
    return next(((i, t) for i, t in selected(work) if t["state"] not in {"verified", "dismissed"}), (None, None))


def public(work, number=None):
    if not work.get("candidates"):
        return {}
    out = {"candidate_summary": [{"number": i["number"], "title": i["title"],
                                  "targets": [{"kind": t["kind"], "state": t["state"]} for t in i["targets"]],
                                  "dismissed": i.get("dismissal", {}).get("state") == "dismissed"}
                                 for i in work["candidates"]]}
    if work.get("candidate_selection"):
        out["candidate_selection"] = copy.deepcopy(work["candidate_selection"])
        item, target = current(work)
        if number is not None:
            matches = [(i, t) for i, t in selected(work) if i["number"] == number]
            if not matches:
                raise ValueError("Read only selected candidate numbers in the execution case.")
            out["selected_candidate"] = {"number": number, "title": matches[0][0]["title"],
                                         "sources": copy.deepcopy(matches[0][0]["sources"]),
                                         "targets": [copy.deepcopy(t) for _, t in matches]}
        if item:
            shown_target = copy.deepcopy(target)
            cache = shown_target.pop("cached_reads", {})
            shown_target["cached_read_refs"] = [
                {k: row[k] for k in ("tool", "receipt_id", "at") if k in row} for row in cache.values()]
            state = target["state"]
            hint = ("쓰기는 이미 성공했다. 원래 도구로 새로 조회해 검증하고 item_checkpoint(stage=verified)로 넘긴다."
                    if state == "written" else
                    "원문 조회는 완료됐다. 현재 컨텍스트의 원문을 재사용한다. 전문을 잃었을 때만 아래 cache_request로 복구한다. 승인·쓰기 전 최신성 검사는 유지한다."
                    if cache else "현재 대상의 필요한 원문만 조회한다. 다른 후보 본문은 미리 모으지 않는다.")
            out["next_candidate"] = {"number": item["number"], "title": item["title"],
                                     "sources": copy.deepcopy(item["sources"]), "target": shown_target,
                                     "next_action": hint}
            if cache:
                out["next_candidate"]["cache_request"] = {"action": "read", "case_id": work["case_id"],
                                                          "item_number": item["number"]}
    return out


def checkpoint(work, args):
    item, target = current(work)
    if not item or args.get("item_number") != item["number"] or args.get("target_kind") != target["kind"]:
        raise ValueError("Checkpoint only next_candidate before moving to the next target/item.")
    stage = args.get("stage")
    summary = _text(args.get("summary"), "summary", 1500)
    evidence = args.get("evidence_ids", [])
    rows = [r for r in work["receipts"] if r.get("tool_call_id") in evidence and r["status"] == "success"
            and r.get("candidate") == [item["number"], target["kind"]] and r["at"] >= work["candidate_started_at"]]
    if not isinstance(evidence, list) or len(rows) != len(set(evidence)):
        raise ValueError("Use successful receipts for this candidate target and current selection.")
    if target["kind"] == "dismiss" and stage != "dismiss":
        raise ValueError("Use stage=dismiss for a proposal explicitly selected with dismiss=true.")
    # Optional explicit read/written checkpoints acknowledge the already recorded tool receipt.
    # The normal path needs only the final verified checkpoint, saving model/tool round trips.
    if stage in {"read", "written"} and target["state"] == stage:
        last = target["checkpoints"][-1]
        if last["stage"] != stage or not rows or any(r["write"] != (stage == "written")
                or r["at"] < last["at"] for r in rows):
            raise ValueError("Acknowledge only the actual receipt of the current stage.")
        return
    transitions = {"begin": ("pending", "active"), "read": ("active", "read"),
                   "written": ("read", "written"), "verified": ("written", "verified"),
                   "dismiss": ("pending", "dismissed")}
    if stage not in transitions or target["state"] != transitions[stage][0]:
        raise ValueError("Use begin → read → written → verified, or dismiss for a dismissed proposal.")
    if stage == "dismiss" and target["kind"] != "dismiss":
        raise ValueError("Only a proposal explicitly selected with dismiss=true can be dismissed.")
    if stage in {"read", "written", "verified"}:
        after = target["checkpoints"][-1]["at"]
        if not any(r["at"] >= after and r["write"] == (stage == "written") for r in rows):
            raise ValueError("Each stage requires actual read/write evidence after its preceding checkpoint.")
    target["state"] = transitions[stage][1]
    target["checkpoints"].append({"stage": stage, "summary": summary, "evidence_ids": evidence, "at": time.time()})
    if stage == "verified":
        target.pop("cached_reads", None)


_ID_KEYS = {"id", "page_id", "block_id", "note_id", "database_id", "data_source_id", "source_id", "common_id", "native_id"}


def _ids(value):
    if isinstance(value, dict):
        for k, v in value.items():
            if k in _ID_KEYS and isinstance(v, str):
                yield v.replace("-", "").lower()
            yield from _ids(v)
    elif isinstance(value, list):
        for v in value:
            yield from _ids(v)


def _truncated(value):
    if isinstance(value, dict):
        return any(v is True for k, v in value.items() if k in {"truncated", "body_truncated"}) or any(_truncated(v) for v in value.values())
    return isinstance(value, list) and any(_truncated(v) for v in value)


def _belongs(target, tool, args):
    family = ((target["kind"] == "notion" and tool == "notion")
            or (target["kind"] == "notes" and (tool.startswith("apple_notes_") or tool == "notes_read"
                or tool == "personal_work_bundle" and args.get("operations")
                and all(o.get("domain") == "notes" for o in args["operations"])))
            or (target["kind"] == "deadline" and tool == "deadline_watch")
            or (target["kind"] == "common_work" and tool.startswith("common_work_")))
    if not family:
        return False
    allowed = {target["id"].replace("-", "").lower(), *target.get("observed_ids", [])}
    def routed_ids(operation):
        values = operation.get("params", {}) if operation.get("action") == "api" else operation
        return set(_ids({k: v for k, v in values.items() if k in _ID_KEYS}))
    if tool == "notion" and args.get("action") == "batch":
        ops = args.get("operations", [])
        return bool(ops) and all(allowed.intersection(routed_ids(op)) for op in ops)
    if tool == "personal_work_bundle":
        return all(allowed.intersection(routed_ids(op.get("arguments", {}))) or target["operation"] == "create"
                   and op.get("action") == "create" and op.get("arguments", {}).get("folder") == target["id"]
                   for op in args.get("operations", []))
    if target["kind"] == "notes" and target["operation"] == "create" and args.get("folder") == target["id"]:
        return True
    return bool(allowed.intersection(routed_ids(args)))


def guard(work, tool, args, is_write, digest):
    if not work.get("candidate_selection"):
        return None
    item, target = current(work)
    if is_write and (not target or target["state"] not in {"read", "written"} or not _belongs(target, tool, args)):
        return {"action": "block", "message": "선택 장부의 현재 대상만 원문 조회·read 체크포인트 뒤 쓴다. next_candidate를 확인한다."}
    # Reuse only a complete bounded read before any subsequent write. Post-write verification is fresh.
    if target and target["state"] in {"active", "read"} and not is_write:
        cached = target.get("cached_reads", {}).get(digest)
        if cached:
            return {"action": "block", "message": "같은 대상·인자를 이미 조회했다. team_work(read, item_number="
                    + str(item["number"]) + ")의 cached_reads 전체 결과를 재사용한다. 쓰기 뒤 검증 조회는 허용된다."}
    return None


def observe(work, row, tool, args, result, safe_text):
    item, target = current(work)
    if not target:
        return
    try:
        payload = json.loads(result) if isinstance(result, str) else result
    except (TypeError, ValueError):
        payload = {}
    belongs = _belongs(target, tool, args)
    # The real notes lookup accepts query/folder, NOT note_id. Bind its evidence
    # to the stable ID actually returned, never to a title match alone.
    if tool == "apple_notes_direct_lookup" and target["kind"] == "notes":
        belongs = bool(args.get("include_body") is True and (belongs
            or target["id"].replace("-", "").lower() in set(_ids(payload))))
    if not belongs:
        return
    row["candidate"] = [item["number"], target["kind"]]
    if row["status"] == "success":
        target["observed_ids"] = sorted(set(target.get("observed_ids", [])) | set(_ids(payload)))[:500]
    if row["write"]:
        target.pop("cached_reads", None)
        if row["status"] == "success" and target["state"] in {"read", "written"}:
            target["state"] = "written"
            target["checkpoints"].append({"stage": "written", "summary": "실제 쓰기 성공 영수증 자동 기록",
                                          "at": row["at"], "evidence_ids": [row["tool_call_id"]]})
    elif row["status"] == "success" and target["state"] in {"pending", "active", "read"}:
        if target["state"] in {"pending", "active"}:
            target["state"] = "read"
            target["checkpoints"].append({"stage": "read", "summary": "실제 원문 조회 성공 영수증 자동 기록",
                                          "at": row["at"], "evidence_ids": [row["tool_call_id"]]})
        rendered = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        cache = target.setdefault("cached_reads", {})
        if not _truncated(payload) and len(rendered) + sum(len(r["result"]) for r in cache.values()) <= CACHE_CHARS:
            try:
                safe_text(rendered)
            except ValueError:
                return  # Still persist the receipt; never cache a credential-bearing body.
            cache[row["args_digest"]] = {"tool": tool, "receipt_id": row["tool_call_id"],
                                         "at": row["at"], "result": rendered}


def resume(work):
    """A new owner request needs a fresh pre-write read; completed writes stay completed."""
    item, target = current(work)
    if target and target["state"] in {"active", "read"}:
        target.pop("cached_reads", None)
        after = target["checkpoints"][-1]["at"]
        writes = [r for r in work["receipts"] if r.get("candidate") == [item["number"], target["kind"]]
                  and r["write"] and r["at"] >= after and r["status"] in {"success", "unknown", "partial"}]
        if writes:
            if all(r["status"] == "success" for r in writes):
                target["state"] = "written"
                target["checkpoints"].append({"stage": "written", "at": max(r["at"] for r in writes),
                    "summary": "실제 성공 영수증으로 중단 직전 쓰기 복구; 재실행 없이 검증", "evidence_ids": [r["tool_call_id"] for r in writes]})
            # Unknown writes stay in read; existing resolve_uncertain must run before more writes.
        else:
            target["state"] = "pending"


_S = {"type": "string"}
FIELDS = {
    "candidate_case_id": {"type": "string", "description": "start only: reuse numbered report case in this thread; never transfers approval."},
    "item_number": {"type": "integer"}, "target_kind": {"type": "string", "enum": [*KINDS, "dismiss"]},
    "stage": {"type": "string", "enum": ["begin", "read", "written", "verified", "dismiss"]},
    "selection": {"type": "array", "maxItems": 20, "items": {"type": "object", "properties": {
        "number": {"type": "integer"}, "kinds": {"type": "array", "items": {"type": "string", "enum": list(KINDS)}},
        "dismiss": {"type": "boolean"}}, "required": ["number"], "additionalProperties": False}},
    "candidates": {"type": "array", "maxItems": 20, "items": {"type": "object", "properties": {
        "number": {"type": "integer"}, "title": _S, "evidence_ids": {"type": "array", "items": _S},
        "sources": {"type": "array", "items": {"type": "object", "properties": {
            "id": _S, "account": _S, "excerpt": _S, "body_hash": _S}, "required": ["id"], "additionalProperties": False}},
        "targets": {"type": "array", "items": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": list(KINDS)}, "id": _S, "operation": _S, "text": _S, "due": _S},
            "required": ["kind", "id", "operation", "text"], "additionalProperties": False}}},
        "required": ["number", "title", "evidence_ids", "sources", "targets"], "additionalProperties": False}},
}
