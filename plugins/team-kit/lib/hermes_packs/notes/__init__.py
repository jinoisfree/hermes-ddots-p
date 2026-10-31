"""Notes execution with injected account, scope and approval services."""
from __future__ import annotations
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo
from dataclasses import dataclass

@dataclass(frozen=True)
class Services:
    """One call's dependencies. No profile or gateway modules are imported here."""
    DEFAULT_NOTES_FOLDER: Any
    INBOX_NOTES_FOLDER: Any
    NOTE_CHOICE_LIMIT: Any
    NOTE_CONTEXT_LIMIT: Any
    NOTE_ORIGINAL_HEADING: Any
    NOTE_PREVIEW_HEADING: Any
    NOTE_PROGRESS_VALUES: Any
    NOTE_STATE_RETENTION_DAYS: Any
    NOTE_SUMMARY_HEADING: Any
    NoteAttachmentsNotPreserved: Any
    PERSONAL_PROFILE: Any
    _LINKED_TITLE_AUTHORITY: Any
    _NOTE_DUE_LABEL: Any
    _NOTE_EXPORTS: Any
    _NOTE_FILE_NAME_RE: Any
    _NOTE_FILE_SIGNATURES: Any
    _NOTE_IMAGE_SUFFIXES: Any
    _NOTE_MARKS_DONE: Any
    _NOTE_MARKS_OPEN: Any
    _NOTE_PROGRESS: Any
    _NOTE_RENAME_SUMMARY_REQUIRED: Any
    _NOTE_VERIFY_BUDGET_SECONDS: Any
    _NOTE_VERIFY_INTERVAL_SECONDS: Any
    _NoteHTML: Any
    _append_note_rebuild: Any
    _apple_notes_direct_mutation: Any
    _apple_notes_restore: Any
    _apply_note_choice: Any
    _attach_common_work_links: Any
    _cached_files_named: Any
    _calendar_cache_root: Any
    _clean_note_block_name: Any
    _clear_pending_personal_owner: Any
    _direct_receipt: Any
    _drop_existing_note_files: Any
    _error: Any
    _export_note_attachments: Any
    _is_note_image: Any
    _linked_note_sections: Any
    _mutation_preview: Any
    _note_apply_edits: Any
    _note_block_icon: Any
    _note_choices: Any
    _note_choices_path: Any
    _note_context_path: Any
    _note_first_title: Any
    _note_html_with_progress: Any
    _note_link_state: Any
    _note_missing_files: Any
    _note_native_info: Any
    _note_parse_day: Any
    _note_plaintext: Any
    _note_progress: Any
    _note_progress_html: Any
    _note_verification_snapshot: Any
    _notes_create_folder: Any
    _notes_html: Any
    _notes_layout: Any
    _notes_original_html: Any
    _notes_reuse_source: Any
    _notes_summary_html: Any
    _original_from_plaintext: Any
    _owner_chat_no_approval: Any
    _personal_owner_error: Any
    _preserve_note_context: Any
    _read_note_context: Any
    _register_approved_common_work_source: Any
    _remember_note_context: Any
    _removed_summary_blocks: Any
    _save_note_choice: Any
    _select_note_attachments: Any
    _seoul_stamp: Any
    _squash: Any
    _stable_note_files: Any
    _structured_note_body: Any
    _unlink_owner_deleted_source: Any
    _update_note_state: Any
    _verify_note_after_update: Any
    _verify_note_update: Any
    deadline_time: Any
    host: Any
    notes_format: Any
    notes_rebuild: Any
    notes_screen: Any
    obsidian_notes: Any


def _clean_note_block_name(services, name: str) -> str:
    # Strip decorative icons (including variation selectors), not letters or numbers.
    return ''.join(c for c in name if unicodedata.category(c) not in {'So', 'Sk', 'Cf'}
                   and c not in '\ufe0e\ufe0f').strip()

def _removed_summary_blocks(services, body_html: str, summary: str) -> list[str] | None:
    try:
        before = services._NoteHTML(); before.feed(body_html); before.close(); before.text()
        if not before.has_source:
            return None  # An unstructured or unreadable note is not proof of zero missing blocks.
        after = services._NoteHTML(); after.feed(services._notes_summary_html(summary)); after.close(); after.text()
        present = set(after.blocks)
        return list(dict.fromkeys(name for name in before.blocks if name and name not in present))
    except (ValueError, TypeError):
        return None

def _apple_notes_direct_lookup(services, args: dict[str, Any], **context: Any) -> str:
    if services.obsidian_notes.selected(services.host):
        if error := services._personal_owner_error("apple_notes_direct_lookup"):
            return error
        try:
            return services.obsidian_notes.lookup(services.host, args)
        except Exception as exc:
            return services._error('Obsidian 조회 실패 — 결과 없음으로 해석하지 마세요: '+str(exc))
    if error := services._personal_owner_error("apple_notes_direct_lookup"):
        return error
    query = str(args.get("query") or "").strip()
    folder = str(args.get("folder") or "").strip()
    try:
        limit = min(20, max(1, int(args.get("limit") or 10)))
    except (TypeError, ValueError):
        return services._error("invalid notes limit")
    include_body = bool(args.get("include_body"))
    script = Path(__file__).with_name("apple_notes_lookup.js")
    command = [
        "/usr/bin/osascript", "-l", "JavaScript", str(script),
        query, folder, str(limit), "true" if include_body else "false",
        "true" if args.get("search_body") else "false",
    ]
    runner = context.get("runner") or subprocess.run
    try:
        proc = runner(command, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"APPLE_NOTES_NATIVE_UNAVAILABLE:{type(exc).__name__}")
    if proc.returncode != 0:
        return services._error(f"APPLE_NOTES_NATIVE_FAILED:{proc.returncode}")
    try:
        items = json.loads(str(proc.stdout or "[]"))
    except (ValueError, TypeError):
        return services._error("APPLE_NOTES_NATIVE_PARSE_FAILED")
    if not isinstance(items, list) or any(
        not isinstance(item, dict) or not str(item.get("stableNoteIdentifier") or "").strip()
        for item in items
    ):
        return services._error("APPLE_NOTES_NATIVE_PARSE_FAILED")
    for item in items:
        raw_html = item.pop("_html", None)
        if include_body:
            item.update(body_format="plaintext", summary_readable=False)
            if raw_html:
                try:
                    parsed = services._NoteHTML()
                    parsed.feed(raw_html)
                    parsed.close()
                    item.update(body=parsed.text(), bodyAvailable=True, body_format="html",
                                table_count=parsed.tables, summary_readable=True,
                                body_representation="edit_markup",
                                body_notice="body는 저장 HTML을 수정용 글로 풀어 쓴 결과이며 Notes 화면이나 원시 HTML이 아니다. 구역 접두·[ ]/[x]·{fmt:...}는 서식 복원용 표시다. 새 목록 서식의 table_count=0은 정상이며 이 값이나 표시만으로 서식 오류·내용 손실을 판단하지 않는다.")
                except (ValueError, TypeError):
                    pass  # Keep plaintext and explicitly mark the unreadable summary.
    services._attach_common_work_links(items, domain="notes", source_id_field="stableNoteIdentifier")
    payload = json.loads(services._direct_receipt(
        "apple_notes_lookup", "Apple Notes via Notes.app JXA", items,
    ))
    payload["stable_note_identifier_available"] = True
    payload["common_id_link_allowed"] = True
    return json.dumps(payload, ensure_ascii=False)

def _squash(services, text: str) -> str:
    return re.sub(r"\s+", "", str(text or ""))

def _seoul_stamp(services) -> str:
    return datetime_type.now(ZoneInfo("Asia/Seoul")).strftime("%Y-%m-%d %H:%M")

def _structured_note_body(services, summary: Any, original_text: Any, preview_summary: Any = "") -> str:
    clean_summary = str(summary or "").strip()
    original = str(original_text or "")
    clean_preview = str(preview_summary or "").strip()
    if clean_preview:
        return (
            f"{services.NOTE_PREVIEW_HEADING}\n{clean_preview}\n\n"
            f"{services.NOTE_SUMMARY_HEADING}\n{clean_summary}\n\n{services.NOTE_ORIGINAL_HEADING}\n{original}"
        )
    return f"{services.NOTE_SUMMARY_HEADING}\n{clean_summary}\n\n{services.NOTE_ORIGINAL_HEADING}\n{original}"

def _note_block_icon(services, heading: str) -> str:
    for tokens, icon in (
        (("확인", "결정", "조치"), "✅"),
        (("일정", "행사", "기한"), "🗓️"),
        (("신청", "접수", "수료"), "📝"),
        (("배송", "물류"), "📦"),
        (("운영", "역할"), "🏢"),
        (("장소", "위치"), "📍"),
        (("담당", "연락"), "👤"),
        (("링크", "자료"), "🔗"),
        (("유의", "주의", "위험"), "⚠️"),
        (("교육", "과정", "커리큘럼"), "📚"),
    ):
        if any(token in heading for token in tokens):
            return icon
    return ""

def _notes_summary_html(services, summary: str, layout: str = "table") -> str:
    # Keep the layout argument for callers; both folders share the same summary.
    return services.notes_format.render(services.notes_format.parse(summary), services._note_block_icon)

def _notes_original_html(services, original: str) -> str:
    paragraphs = original.split("\n\n")
    rendered = []
    for paragraph in paragraphs:
        safe_lines = "<br>".join(
            "&nbsp;" * (4 + len(re.match(r"[ \t]*", line).group().replace("\t", "    ")))
            + html.escape(line[len(re.match(r"[ \t]*", line).group()):], quote=True)
            for line in paragraph.splitlines()
        )
        rendered.append(f"<p>{safe_lines or '<br>'}</p>")
    return "".join(rendered)

def _is_note_image(services, path: str) -> bool:
    return Path(path).suffix.lower() in services._NOTE_IMAGE_SUFFIXES

def _export_note_attachments(services, note_id: str, runner: Any, body_html: str) -> list[str] | None:
    """Copy a note's own file attachments out of Notes when no saved originals exist.

    Items Notes cannot save are body-native tables; their count must equal the body's
    tables, otherwise an unknown attachment would be lost and None is returned.
    """
    key = (note_id, hashlib.sha256(str(body_html or "").encode()).hexdigest())
    cached = services._NOTE_EXPORTS.get(key)
    if cached and all(Path(p).is_file() for p in cached):
        return list(cached)
    # Outside note-files, so _stable_note_files copies the exports before the folder is removed.
    kept_store = services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent / "state" / "note-files"
    store = services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent / "state" / "note-exports"
    folder = store / hashlib.sha256(f"{note_id}{time.time()}".encode()).hexdigest()[:16]
    folder.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    try:
        proc = runner(["/usr/bin/osascript", str(script), "export", note_id, "", str(folder), ""],
                      capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if getattr(proc, "returncode", 1) != 0:
        return None
    exported, unsaved = [], 0
    for line in str(getattr(proc, "stdout", "") or "").splitlines():
        index, _, rest = line.partition("\t")
        name, _, saved = rest.partition("\t")
        source = Path(saved.strip()) if saved.strip() else None
        if source is None or not source.is_file() or folder not in source.parents:
            # Notes cannot save some documents (e.g. .pptx); a file this tool attached earlier
            # is kept under the exact same content-hashed name in note-files.
            kept = kept_store / Path(name).name if name.strip() else None
            if kept is not None and kept.is_file():
                exported.append(str(kept))
            else:
                unsaved += 1
            continue
        suffix = Path(name).suffix.lower()
        if not suffix:
            head = source.read_bytes()[:16]
            suffix = next((ext for magic, ext in services._NOTE_FILE_SIGNATURES if head.startswith(magic)), "")
            if not suffix and head[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1"):
                suffix = ".heic"
            if not suffix and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
                suffix = ".webp"
        if not suffix:
            return None
        stem = Path(name).stem if name.strip() else f"note_attachment_{index.strip()}"
        target = folder / f"{stem}{suffix}"
        source.rename(target)
        exported.append(str(target))
    if unsaved != str(body_html or "").count("<table"):
        return None
    import shutil

    services._NOTE_EXPORTS[key] = services._stable_note_files(exported)
    shutil.rmtree(folder, ignore_errors=True)
    return list(services._NOTE_EXPORTS[key])

def _drop_existing_note_files(services, attachments, existing, mode) -> list[str]:
    """Existing files the user asked to remove (remove_existing); new files are never dropped."""
    if mode not in {"images", "documents", "all"}:
        return []
    return [p for p in attachments if p in existing and (
        mode == "all" or (mode == "images") == services._is_note_image(p))]

def _select_note_attachments(services, paths, existing=()):
    # Fresh HTML imports documents before native image attachments.
    return sorted(paths, key=services._is_note_image), []

def _note_native_info(services, note_id: str, runner: Any) -> tuple[str | None, str]:
    if services.obsidian_notes.handles(note_id):
        row=services.obsidian_notes.disk.Store().read(note_id)
        return str(row['properties'].get('created') or ''), row['folder']
    """(creation time as 'YYYY-MM-DD HH:MM' or None, folder name or '') of an existing note."""
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    try:
        proc = runner(["/usr/bin/osascript", str(script), "created", note_id, "", "", ""],
                      capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if getattr(proc, "returncode", 1) != 0:
        return None, ""
    stamp, _, folder = str(getattr(proc, "stdout", "") or "").strip().partition("\t")
    created = stamp[:16].replace("T", " ") if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", stamp) else None
    return created, folder.strip()

def _notes_layout(services, folder: str) -> str:
    """Inbox memos read as bullet lists; Task Notes keep their label/value tables."""
    return "list" if folder.casefold() == services.INBOX_NOTES_FOLDER.casefold() else "table"

def _notes_html(services,
    title: str,
    body: str,
    attachments: list[str] | None = None,
    updated_at: str | None = None,
    created_at: str | None = None,
    attachment_analysis: str = "",
    layout: str = "table",
    progress: str = "",
) -> str:
    safe_title = html.escape(title, quote=True)
    marker = f"\n\n{services.NOTE_ORIGINAL_HEADING}\n"
    preview_summary = ""
    structured_body = body
    if body.startswith(f"{services.NOTE_PREVIEW_HEADING}\n"):
        preview_marker = f"\n\n{services.NOTE_SUMMARY_HEADING}\n"
        preview_summary, separator, summary_payload = body[len(services.NOTE_PREVIEW_HEADING) + 1:].partition(preview_marker)
        if separator:
            structured_body = f"{services.NOTE_SUMMARY_HEADING}\n{summary_payload}"
    if structured_body.startswith(f"{services.NOTE_SUMMARY_HEADING}\n") and marker in structured_body:
        summary, _, original = structured_body[len(services.NOTE_SUMMARY_HEADING) + 1:].partition(marker)
        analysis_html = ""
        if attachment_analysis.strip():
            analysis_html = (
                '<div><br></div><h2 style="font-size:22px;line-height:1.3;">첨부 분석</h2>'
                f"<div>{services._notes_original_html(attachment_analysis.strip())}</div>"
            )
        attachment_html = ""
        if attachments:
            # Documents embed once through file://; images are attached by the AppleScript
            # afterwards (they land right below this heading) because Notes shows file:// images
            # as empty placeholders.
            documents = "".join(
                f'<div><img src="file://{html.escape(quote(path), quote=True)}"></div>'
                for path in attachments if not services._is_note_image(path)
            )
            attachment_html = f"<div><br></div><h2>원문 첨부파일</h2>{documents}"
        modified = updated_at or datetime_type.now(ZoneInfo("Asia/Seoul")).strftime("%Y-%m-%d %H:%M")
        stamp = f"생성: {created_at or modified}"
        if created_at and created_at != modified:
            stamp += f" · 최종 수정: {modified}"
        preview_html = html.escape(preview_summary.strip() or "요약", quote=True)
        return (
            f'<h1 style="font-size:36px;line-height:1.2;">{safe_title}</h1>'
            f'<div style="font-size:16px;line-height:1.4;">'
            f'<font color="#39FF14"><b>{preview_html}</b></font></div>'
            f"<div><small>{html.escape(stamp, quote=True)} (Asia/Seoul)</small>{services._note_progress_html(progress)}</div>"
            f"<div>{services._notes_summary_html(summary, layout)}</div>"
            "<div><br></div><div>━━━━━━━━━━━━━━━━━━━━</div><div><br></div>"
            f'<h2 style="font-size:22px;line-height:1.3;">원문</h2>'
            f"<div><br></div><blockquote>{services._notes_original_html(original)}</blockquote>"
            f"{analysis_html}{attachment_html}"
        )
    safe_body = "<br>".join(html.escape(body, quote=True).splitlines())
    return f"<h1>{safe_title}</h1><div>{safe_body}</div>"

def _note_progress_html(services, progress: str) -> str:
    # Lives on the 생성: line so the structured-summary parser and linked-work content ignore it.
    if progress not in services.NOTE_PROGRESS_VALUES:
        return ""
    color = "#FF9500" if progress == "진행중" else "#8E8E93"
    return f' · <b><font color="{color}">진행도: {progress}</font></b>'

def _note_progress(services, body_html: str) -> str:
    """Progress on a structured note's 생성: line, or on its own line near the top of other notes."""
    parsed = services._NoteHTML(); parsed.feed(str(body_html or "")); parsed.close()
    for line in parsed.text().splitlines()[:4]:
        if line.startswith("생성:"):
            hit = services._NOTE_PROGRESS.search(line)
            return hit[1] if hit else ""
        if line.startswith("진행도: ") and line[5:].strip() in services.NOTE_PROGRESS_VALUES:
            return line[5:].strip()
    return ""

def _note_html_with_progress(services, body_html: str, progress: str) -> str | None:
    """Text-level edit of a note's native HTML: replace the 진행도 value, else add it after the
    structured 생성: stamp, else as its own line under the title."""
    current = services._note_progress(body_html)
    if current:
        return re.sub(r"진행도: (진행중|완료)", f"진행도: {progress}", body_html, count=1)
    parsed = services._NoteHTML(); parsed.feed(body_html); parsed.close()
    lines = parsed.text().splitlines()
    if len(lines) > 2 and lines[2].startswith("생성:") and "(Asia/Seoul)" in body_html:
        return body_html.replace("(Asia/Seoul)", "(Asia/Seoul)" + services._note_progress_html(progress), 1)
    end = re.search(r"</(div|h1)>", body_html)
    if not end:
        return None
    return body_html[:end.end()] + f"<div>진행도: {html.escape(progress)}</div>" + body_html[end.end():]

def _stable_note_files(services, paths: list[str]) -> list[str]:
    """Copy note attachments into a durable store under ASCII names.

    Notes silently skips file:// sources whose name has non-ASCII characters (e.g. Chinese PDF
    names), and inbound caches get pruned, so later edits could no longer re-attach them.
    """
    import shutil

    store = services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent / "state" / "note-files"
    stable: list[str] = []
    for raw in paths:
        source = Path(raw)
        if store in source.parents and source.name.isascii():
            stable.append(str(source))
            continue
        try:
            digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
        except OSError:
            stable.append(str(source))
            continue
        # A file exported back out of a rebuilt note already carries this content digest; adding it again
        # grew the name on every rebuild ('a_<d>' -> 'a_<d>_<d>'), so keep only the part before it.
        base = source.stem.split(f"_{digest}", 1)[0]
        stem = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("_")[:40] or "file"
        target = store / f"{stem}_{digest}{source.suffix.lower()}"
        if not target.is_file():
            store.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        stable.append(str(target))
    return stable

def _note_context_path(services) -> Path:
    return services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent / "state" / "note-context.json"

def _read_note_context(services) -> dict[str, Any]:
    try:
        payload = json.loads(services._note_context_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}

def _update_note_state(services, path, key, row, limit):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f".tmp-{os.getpid()}-{threading.get_ident()}")
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            try:
                data = json.loads(path.read_text())
            except FileNotFoundError:
                data = {}
            if not isinstance(data, dict):
                raise ValueError("Invalid note state")
            now = time.time()
            # Undated legacy entries get a full retention window on first migration.
            for value in data.values():
                if not isinstance(value, dict):
                    raise ValueError("Invalid note state entry")
                value.setdefault("updated_at", now)
            data = {k: v for k, v in data.items()
                    if float(v["updated_at"]) >= now - services.NOTE_STATE_RETENTION_DAYS * 86400}
            data[key] = {**row, "updated_at": now}
            data = dict(sorted(data.items(), key=lambda pair: float(pair[1]["updated_at"]))[-limit:])
            with temporary.open("w") as output:
                json.dump(data, output, ensure_ascii=False)
                output.flush()
                os.fsync(output.fileno())
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)

def _remember_note_context(services, note_id: str, attachments: list[str], original_text: str) -> None:
    """Bounded, locked attachment/source recovery hints for later edits."""
    try:
        services._update_note_state(services._note_context_path(), note_id,
                           {"attachments": list(attachments), "original_text": original_text}, services.NOTE_CONTEXT_LIMIT)
    except (OSError, ValueError, TypeError) as exc:
        logging.getLogger(__name__).warning("Note context save failed (%s)", type(exc).__name__)

def _note_plaintext(services, note_id: str, runner: Any) -> str:
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.disk.Store().read(note_id)['plaintext']
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    try:
        proc = runner(["/usr/bin/osascript", str(script), "plaintext", note_id, "", "", ""],
                      capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return str(getattr(proc, "stdout", "") or "") if getattr(proc, "returncode", 1) == 0 else ""

def _cached_files_named(services, names: list[str]) -> list[str]:
    """Find inbound-cache files by the names an older note body listed under 원문 첨부파일."""
    home = services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent
    install = home.parent.parent
    roots = [home / "cache" / "documents", home / "cache" / "images", install / "cache" / "documents",
             install / "cache" / "images", install / "image_cache", install / "document_cache"]
    found: list[str] = []
    for name in names:
        for root in roots:
            candidate = root / name
            if candidate.is_file():
                found.append(str(candidate))
                break
    return found

def _original_from_plaintext(services, plaintext: str, *, strip_prefix: bool = True) -> str:
    """Source text of a rendered note: the block under its last '원문' heading."""
    _, marker, rest = plaintext.replace("\xa0", " ").rpartition("\n원문\n")
    if not marker:
        return ""
    rest = re.split(r"\n(?:첨부 분석|원문 첨부파일)(?:\n|$)", rest, maxsplit=1)[0]
    lines = [
        line[4:] if strip_prefix and line.startswith("    ") else line
        for line in rest.splitlines()
        if not line.strip().startswith("최종 수정:")
    ]
    return "\n".join(lines).strip("\n")

def _preserve_note_context(services,
    note_id: str, attachments: list[str], original_text: str, runner: Any, *, reuse_source: bool = False,
) -> tuple[list[str], str]:
    if services.obsidian_notes.handles(note_id):
        # Obsidian preserves its own source and attachments during mutate; Apple caches are unrelated.
        row = services.obsidian_notes.disk.Store().read(note_id)
        return list(dict.fromkeys([*services.obsidian_notes.preserved_attachments(row), *attachments])), original_text
    records = services._read_note_context()
    saved = records.get(note_id) or {}
    plaintext = ""
    added = attachments
    attachments = [path for path in saved.get("attachments") or [] if Path(path).is_file()]
    if not attachments:
        plaintext = services._note_plaintext(note_id, runner)
        # Notes can rebuild both its store UUID and object IDs. Only one source-text
        # match in another store is safe; titles and filenames alone are not identity.
        store = re.match(r"^x-coredata://[^/]+/", note_id)
        sources = [services._squash(services._original_from_plaintext(plaintext)),
                   services._squash(str(saved.get("original_text") or ""))]
        candidates = []
        if store:
            for key, record in records.items():
                other_store = re.match(r"^x-coredata://[^/]+/", key)
                if not other_store or other_store.group() == store.group():
                    continue
                previous_source = services._squash(str(record.get("original_text") or ""))
                if previous_source and any(previous_source in source for source in sources):
                    candidates.append(record)
        if len(candidates) == 1:
            attachments = [path for path in candidates[0].get("attachments") or []
                           if Path(path).is_file()]
        if not attachments:
            attachments = services._cached_files_named(sorted(set(services._NOTE_FILE_NAME_RE.findall(plaintext))))
        if not attachments:
            # No saved originals (e.g. files the user added by hand): copy them out of Notes.
            snapshot = services._note_verification_snapshot(note_id, runner) or {}
            if any(snapshot.get("attachment_names") or []):
                attachments = services._export_note_attachments(note_id, runner, str(snapshot.get("body_html") or "")) or []
        if not attachments and "원문 첨부파일" in plaintext:
            raise services.NoteAttachmentsNotPreserved(
                "APPLE_NOTES_ATTACHMENTS_NOT_PRESERVED: Apple 메모 첨부 원본을 찾지 못해 수정을 중단했다. "
                "Apple 메모 경로에서만 원본 파일 확보가 필요하다. "
                "Obsidian 메모는 기존 vault 첨부를 attachments로 다시 넘기지 않는다."
            )
    previous = str(saved.get("original_text") or "")
    if not previous:
        previous = services._original_from_plaintext(plaintext or services._note_plaintext(note_id, runner))
    if reuse_source:
        if not previous.strip():
            raise ValueError("APPLE_NOTES_SOURCE_NOT_PRESERVED: 기존 원문을 읽지 못해 제목 변경을 중단했다. 기존 원문을 확인할 수 없어 자동 수정을 중단했다.")
        original_text = previous
    elif previous.strip() and services._squash(previous) not in services._squash(original_text):
        # Rule: source text only grows, oldest first, each addition under a dated header.
        original_text = f"{previous.rstrip(chr(10))}\n\n[{services._seoul_stamp()} 추가]\n{original_text.strip(chr(10))}"
    return list(dict.fromkeys([*attachments, *added])), original_text

def _note_snapshot(services, note_id: str, runner: Any) -> dict[str, str] | None:
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.rollback_snapshot(services.host, note_id)
    """Exact title and HTML body of a note right before it is changed, or None."""
    if not note_id:
        return None
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    try:
        proc = runner(["/usr/bin/osascript", str(script), "snapshot", note_id, "", "", ""],
                      capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if getattr(proc, "returncode", 1) != 0:
        return None
    title, separator, body_html = str(getattr(proc, "stdout", "") or "").rstrip("\n").partition("\t")
    if not separator or not body_html:
        return None
    return {"note_id": note_id, "title": title, "body_html": body_html}

def _note_verification_snapshot(services, note_id: str, runner: Any, *, timeout: float = 30) -> dict[str, Any] | None:
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.snapshot(services.host, note_id)
    """One bounded read of native HTML and attachment names; tables have no filename."""
    try:
        proc = runner(["/usr/bin/osascript", "-l", "JavaScript",
                       str(Path(__file__).with_name("apple_notes_verify.js")), note_id],
                      capture_output=True, text=True, timeout=timeout, check=False)
        if proc.returncode != 0:
            return None
        data = json.loads(proc.stdout)
        if not isinstance(data, dict) or data.get("note_id") != note_id:
            return None
        return data
    except (OSError, subprocess.TimeoutExpired, ValueError, TypeError):
        return None

def _verify_note_update(services, before, after, managed_files, removed):
    def count(snapshot):
        names = (snapshot or {}).get("attachment_names")
        if not isinstance(names, list) or any(not isinstance(n, str) for n in names):
            return None
        if managed_files is None:
            # Title-only writes preserve native attachments without needing local originals.
            return sum(bool(name) for name in names)
        managed = {Path(p).name for p in managed_files}
        return sum(Path(unquote(name)).name in managed for name in names if name)

    def source(snapshot):
        body = (snapshot or {}).get("body_html")
        if not isinstance(body, str) or not body:
            return None
        try:
            parsed = services._NoteHTML(); parsed.feed(body); parsed.close()
            text = parsed.text()
            return services._original_from_plaintext(text, strip_prefix=False) if parsed.has_source else None
        except (ValueError, TypeError):
            return None

    old_source, new_source = source(before), source(after)
    before_count, after_count = count(before), count(after)
    preserved = (services._squash(old_source) in services._squash(new_source)
                 if old_source is not None and new_source is not None else None)
    verification = {"attachments_expected": before_count if managed_files is None else len(managed_files),
                    "attachments_before": before_count, "attachments_after": after_count,
                    "source_preserved": preserved, "summary_blocks_removed": removed}
    loss = []
    if before_count is not None and after_count is not None and after_count < before_count:
        loss.append(f"attachments: {before_count} → {after_count}")
    if preserved is False:
        loss.append("original_text: previous source missing")
    if removed:
        loss.append("summary_blocks: " + ", ".join(removed))
    return verification, loss

def _note_first_title(services, snapshot):
    body = (snapshot or {}).get('body_html')
    if not isinstance(body, str):
        return None
    first = re.match(r'\s*<(div|h1)\b[^>]*>(.*?)</\1>', body, re.I | re.S)
    return html.unescape(re.sub(r'<[^>]+>', '', first.group(2))).strip() if first else None

def _verify_note_after_update(services, note_id, runner, before, files, removed, *, title=None):
    deadline = time.monotonic() + services._NOTE_VERIFY_BUDGET_SECONDS
    verification, loss = services._verify_note_update(before, None, files, removed)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            after = None
        else:
            after = services._note_verification_snapshot(note_id, runner, timeout=remaining)
        verification, loss = services._verify_note_update(before, after, files, removed)
        if title is not None:
            actual = (after or {}).get('title')
            first = services._note_first_title(after)
            verification.update(title_actual=actual, title_first_line=first,
                                title_applied=(actual == title and first == title)
                                if isinstance(actual, str) and first is not None else None)
        count = verification['attachments_after']
        expected = verification['attachments_expected']
        retry = (count is None or verification['source_preserved'] is not True or
                 (expected is not None and count < expected) or
                 (title is not None and verification['title_applied'] is not True))
        if not retry or deadline - time.monotonic() <= services._NOTE_VERIFY_INTERVAL_SECONDS:
            break
        time.sleep(services._NOTE_VERIFY_INTERVAL_SECONDS)
    return verification, loss

def _note_missing_files(services, note_id, files, runner):
    """Compare file-name multiplicities after Notes' asynchronous import has settled."""
    from collections import Counter
    expected = Counter(Path(path).name for path in files)
    deadline = time.monotonic() + services._NOTE_VERIFY_BUDGET_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        after = services._note_verification_snapshot(note_id, runner, timeout=max(.01, remaining)) if remaining > 0 else None
        names = (after or {}).get('attachment_names')
        actual = Counter(Path(unquote(name)).name for name in names if name) if isinstance(names, list) else Counter()
        missing = list((expected - actual).elements())
        if isinstance(names, list) and actual == expected:
            return []
        if deadline - time.monotonic() <= services._NOTE_VERIFY_INTERVAL_SECONDS:
            return missing or ['첨부 개수/이름 불일치 또는 확인 불가']
        time.sleep(services._NOTE_VERIFY_INTERVAL_SECONDS)

def _append_plain_note(services, note_id, line, before, runner=subprocess.run):
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.edit(services.host, note_id, before, line.splitlines(), [])
    """Watcher-only append: compare-and-set, no attachments, verified text preservation.

    The caller journals the pre-write snapshot before entering this function.
    This does not expose a new conversation tool or weaken background guards.
    """
    if not isinstance(before, dict) or before.get('attachment_names') != [] or not isinstance(before.get('plaintext'), str) or not before.get('body_html'):
        return {"ok": False, "reason": "메모 원문 또는 무첨부 상태 확인 불가"}
    present = before['plaintext'].splitlines()
    wanted = [x for x in line.splitlines() if x not in present]
    if not wanted:
        return {"ok": True, "changed": False}
    line = '\n'.join(wanted)
    script = Path(__file__).with_name('apple_notes_mutation.applescript')
    fragment = ''.join('<div>' + html.escape(x, quote=True) + '</div>' for x in wanted)
    try:
        proc = runner(['/usr/bin/osascript', str(script), 'append_plain', note_id, '', '',
                       fragment, before['body_html']], capture_output=True, text=True, timeout=30, check=False)
        if proc.returncode:
            return {"ok": False, "reason": "메모 변경 충돌 또는 쓰기 실패"}
        deadline = time.monotonic() + services._NOTE_VERIFY_BUDGET_SECONDS
        after = None
        while time.monotonic() < deadline:
            after = services._note_verification_snapshot(note_id, runner, timeout=max(.01, deadline-time.monotonic()))
            text = (after or {}).get('plaintext')
            if (after or {}).get('attachment_names') == [] and isinstance(text, str) and all(x in text.splitlines() for x in wanted) and services._squash(before['plaintext']) in services._squash(text):
                return {"ok": True, "changed": True}
            time.sleep(services._NOTE_VERIFY_INTERVAL_SECONDS)
        restored = False
        if after and after.get('attachment_names') == [] and after.get('body_html'):
            proc = runner(['/usr/bin/osascript', str(script), 'restore_plain', note_id, '', '',
                           before['body_html'], after['body_html']], capture_output=True, text=True, timeout=30, check=False)
            check = services._note_verification_snapshot(note_id, runner)
            restored = proc.returncode == 0 and bool(check and check.get('attachment_names') == [] and
                       services._squash(check.get('plaintext', '')) == services._squash(before['plaintext']))
        return {"ok": False, "reason": "메모 추기 검증 실패", "restored": restored}
    except (OSError, subprocess.TimeoutExpired):
        return {"ok": False, "reason": "메모 쓰기 결과 불명확"}

def _note_choices_path(services) -> Path:
    return services._calendar_cache_root(services.PERSONAL_PROFILE).parent.parent / "state" / "note-choices.json"

def _note_choices(services) -> dict[str, Any]:
    try:
        data = json.loads(services._note_choices_path().read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

def _save_note_choice(services, choice: dict[str, Any]) -> None:
    try:
        services._update_note_state(services._note_choices_path(), choice["choice_id"], choice, services.NOTE_CHOICE_LIMIT)
    except (OSError, ValueError, TypeError) as exc:
        logging.getLogger(__name__).warning("Note choice save failed (%s)", type(exc).__name__)
        raise

def _apply_note_choice(services, args: dict[str, Any], runner: Any) -> str:
    """Carry out a waiting watcher line on a mixed note the way the owner chose."""
    mode = str(args.get("mixed_mode") or "").strip()
    choices = {k: v for k, v in services._note_choices().items() if v.get("status") == "waiting"}
    choice = choices.get(str(args.get("choice_id") or "")) or (next(iter(sorted(choices.values(), key=lambda c: -c["created_at"])), None)
                                                              if not args.get("choice_id") and len(choices) == 1 else None)
    if choice is None:
        return services._error("APPLE_NOTES_CHOICE_NOT_FOUND: 기다리는 선택이 없거나 둘 이상이다. pending_choices로 확인해 choice_id를 넘긴다.")
    if mode not in {"rebuild", "screen"}:
        return services._error("mixed_mode must be rebuild or screen")
    note_id = choice["note_id"]
    before = services._note_verification_snapshot(note_id, runner)
    if not before or not isinstance(before.get("plaintext"), str):
        return services._error("APPLE_NOTES_NOTE_NOT_FOUND: 메모를 읽지 못했다.")
    lines = [x for x in choice["lines"] if x not in before["plaintext"].splitlines()]
    if not lines:
        receipt = {"ok": True, "changed": False}
    elif mode == "screen":
        receipt = services.notes_screen.append(services.host, note_id=note_id, before=before, lines=lines, files=[], runner=runner)
    else:
        originals = services._export_note_attachments(note_id, runner, str(before.get("body_html") or ""))
        if originals is None:
            return services._error("APPLE_NOTES_REBUILD_ORIGINAL_FILES_REQUIRED")
        files, _ = services._select_note_attachments(originals)
        receipt = services.notes_rebuild.rebuild(
            services.host, note_id=note_id, folder=services._note_native_info(note_id, runner)[1], title=before.get("title"),
            body="".join("<div>" + html.escape(x, quote=True) + "</div>" for x in lines), files=files, existing=originals,
            before=before, args={}, runner=runner, exported=True, append=True)
    if receipt.get("ok") is True:
        services._save_note_choice({**choice, "status": "done", "mode": mode, "done_at": time.time()})
    return json.dumps({**receipt, "choice": {"title": choice.get("title"), "lines": choice["lines"], "mode": mode}}, ensure_ascii=False)

def _append_note_rebuild(services, note_id, line, before, runner=subprocess.run):
    """Watcher append for a note with attachments, in the same note when Notes allows it.

    A body rewrite drops native attachments, so photos and files are copied out first and put back
    after the new body (old body + lines). A note keeping both photos and documents loses the
    documents that way: it is not touched and the owner is asked (needs_choice).
    """
    if not isinstance(before, dict) or not isinstance(before.get('plaintext'), str) or not before.get('body_html'):
        return {"ok": False, "reason": "메모 원문 확인 불가", "written": False}
    present = before['plaintext'].splitlines()
    wanted = [x for x in line.splitlines() if x not in present]
    applied = before.get('_applied') or []
    if not wanted and not applied:
        return {"ok": True, "changed": False}
    originals = services._export_note_attachments(note_id, runner, before['body_html'])
    if originals is None:
        return {"ok": False, "reason": "기존 첨부를 꺼내지 못함", "written": False}
    images = [p for p in originals if services._is_note_image(p)]
    documents = [p for p in originals if not services._is_note_image(p)]
    if images and documents:
        choice_id = hashlib.sha256(f"{note_id}|{'|'.join(wanted)}".encode()).hexdigest()[:8]
        if services._note_choices().get(choice_id, {}).get("status") != "done":
            services._save_note_choice({"choice_id": choice_id, "note_id": note_id, "title": before.get("title"),
                               "lines": wanted, "created_at": time.time(), "status": "waiting"})
        return {"ok": False, "needs_choice": True, "written": False, "lines": wanted, "choice_id": choice_id,
                "reason": "사진과 문서가 함께 있는 메모라 자동으로 넣지 않음"}
    old_html = str(before['body_html'])
    tables = old_html.count('<table')
    carried = re.sub(r'<img\b[^>]*>', '', str(before.get('_edited_html') or old_html))
    original_carried = re.sub(r'<img\b[^>]*>', '', old_html)
    doc_html = ''.join('<div><img src="' + html.escape(Path(p).as_uri(), quote=True) + '"></div>' for p in documents)
    body = carried + ''.join('<div>' + html.escape(x, quote=True) + '</div>' for x in wanted) + doc_html
    script = Path(__file__).with_name('apple_notes_mutation.applescript')

    def write(content, files):
        proc = runner(['/usr/bin/osascript', str(script), 'update', note_id, '', '', content, *files],
                      capture_output=True, text=True, timeout=120, check=False)
        return proc.returncode == 0

    def expected(edits):
        """Old lines as they should read after the edits (ticked tasks, the 다음 마감 line left out)."""
        out = []
        for raw in before['plaintext'].replace('\ufffc', '').splitlines():
            line = raw.strip()
            if not line:
                continue
            if any(e['kind'] == 'due' for e in edits) and line.startswith(services._NOTE_DUE_LABEL):
                continue
            for e in edits:
                if e['kind'] == 'check' and line.startswith('☐') and line[1:].strip().split(':', 1)[0].strip() == e['label']:
                    line = '☑' + line[1:]
            out.append(line)
        return out

    def intact(snapshot, lines, edits=()):
        names = [n for n in (snapshot or {}).get('attachment_names') or [] if n]
        text = str((snapshot or {}).get('plaintext') or '')
        have = {x.strip() for x in text.replace('\ufffc', '').splitlines()}
        return (snapshot is not None and len(set(names)) >= len(originals)
                and str(snapshot.get('body_html') or '').count('<table') >= tables
                and all(x in text.splitlines() for x in lines) and all(x in have for x in expected(list(edits))))

    try:
        ok = write(body, images)
        after = services._note_verification_snapshot(note_id, runner)
        if ok and intact(after, wanted, applied):
            return {"ok": True, "changed": True, "applied": applied}
        # Put the previous body and the copied originals back in the same note.
        restored = write(original_carried + doc_html, images) and intact(services._note_verification_snapshot(note_id, runner), [])
        return {"ok": False, "reason": "메모 기록 검증 실패", "restored": restored, "written": not restored}
    except (OSError, subprocess.TimeoutExpired):
        return {"ok": False, "reason": "메모 쓰기 결과 불명확"}

def _note_link_state(services, plaintext: str) -> dict[str, Any]:
    """Tasks (label -> done) and the 다음 마감 date that a linked note shows."""
    tasks, due = {}, None
    for raw in str(plaintext or "").splitlines():
        line = raw.strip()
        if re.match(r"^(✅\s*완료:|📅)", line):
            continue  # watcher log lines, not tasks
        mark = next((m for m in (*services._NOTE_MARKS_OPEN, *services._NOTE_MARKS_DONE) if line.startswith(m)), None)
        if mark:
            label = line[len(mark):].strip().split(":", 1)[0].split("：", 1)[0].strip()
            if label:
                tasks.setdefault(label, mark in services._NOTE_MARKS_DONE)
        elif line.startswith(services._NOTE_DUE_LABEL) and due is None:
            due = services.deadline_time.note_value(line[len(services._NOTE_DUE_LABEL):].lstrip(" :：|"), services._note_parse_day)
    return {"tasks": tasks, "due": due}

def _note_parse_day(services, text: str) -> str | None:
    """First date in text as YYYY-MM-DD; a date without a year is the nearest one to today."""
    today = datetime_type.now(ZoneInfo("Asia/Seoul")).date()
    match = re.search(r"(\d{4})[-./](\d{1,2})[-./](\d{1,2})", text)
    if match:
        y, m, d = map(int, match.groups())
    else:
        match = re.search(r"(\d{1,2})/(\d{1,2})(?!\d)", text) or re.search(r"(\d{1,2})월\s*(\d{1,2})일", text)
        if not match:
            return None
        m, d = map(int, match.groups())
        y = min((today.year - 1, today.year, today.year + 1),
                key=lambda year: abs((date_type(year, m, d) - today).days) if 1 <= m <= 12 and 1 <= d <= 31 else 10**6)
    try:
        return date_type(y, m, d).isoformat()
    except ValueError:
        return None

def _note_apply_edits(services, body_html: str, edits: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    """Tick ☐ tasks and move the 다음 마감 date inside the note HTML; returns the edits applied."""
    applied, out = [], body_html
    for edit in edits:
        for match in re.finditer(r"<li>(?:(?!<li>|</li>).)*", out, flags=re.S):
            segment = match.group(0)
            text = html.unescape(re.sub(r"<[^>]+>", "", segment)).strip()
            if edit["kind"] == "check" and text.startswith("☐") and services._squash(edit["label"]) and \
                    text[1:].strip().split(":", 1)[0].strip() == edit["label"]:
                new = segment.replace("☐", "☑", 1)
            elif edit["kind"] == "due" and text.startswith(services._NOTE_DUE_LABEL):
                found = services.deadline_time.NOTE_STAMP.search(html.unescape(re.sub(r"<[^>]+>", "", segment)))
                if not found or services.deadline_time.note_value(found.group(0), services._note_parse_day) != edit["old"]:
                    continue
                value = services.deadline_time.canonical(edit['new'])
                y, m, d = value[:10].split('-')
                shown = value[:10] if re.match(r"\d{4}", found.group(0)) else f"{int(m)}/{int(d)}"
                if len(value) > 10:
                    shown += ' ' + services.deadline_time.native(value)[11:]
                new = segment.replace(html.escape(found.group(0)), html.escape(shown), 1)
                if new == segment:
                    continue
            else:
                continue
            out = out[:match.start()] + new + out[match.end():]
            applied.append(edit)
            break
    return out, applied

def _edit_linked_note(services, note_id, before, lines, edits, runner=subprocess.run):
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.edit(services.host, note_id, before, lines, edits)
    """Watcher edit of one linked note in place: tick tasks, move 다음 마감, add log lines.

    Plain notes use a compare-and-set body write; notes with photos or files are rewritten with
    their copied-out originals put back. Photos together with documents are not touched (asked).
    """
    if not isinstance(before, dict) or not isinstance(before.get("plaintext"), str) or not before.get("body_html"):
        return {"ok": False, "reason": "메모 원문 확인 불가", "written": False}
    present = before["plaintext"].splitlines()
    wanted = [x for x in lines if x not in present]
    edited, applied = services._note_apply_edits(str(before["body_html"]), edits)
    if not wanted and not applied:
        return {"ok": True, "changed": False, "applied": []}
    names = [n for n in before.get("attachment_names") or [] if n]
    if not names:
        script = Path(__file__).with_name("apple_notes_mutation.applescript")
        body = edited + "".join("<div>" + html.escape(x, quote=True) + "</div>" for x in wanted)
        proc = runner(["/usr/bin/osascript", str(script), "restore_plain", note_id, "", "", body, before["body_html"]],
                      capture_output=True, text=True, timeout=60, check=False)
        after = services._note_verification_snapshot(note_id, runner) or {}
        state = services._note_link_state(after.get("plaintext") or "")
        ok = proc.returncode == 0 and all(x in str(after.get("plaintext") or "").splitlines() for x in wanted) and all(
            state["tasks"].get(e["label"]) is True if e["kind"] == "check" else state["due"] == e["new"] for e in applied)
        return {"ok": ok, "changed": ok, "applied": applied, **({} if ok else {"reason": "메모 수정 검증 실패"})}
    return services._append_note_rebuild(note_id, "\n".join(wanted), {**before, "_edited_html": edited, "_applied": applied}, runner)

def _linked_note_sections(services, body_html):
    parsed = services._NoteHTML(); parsed.feed(body_html); parsed.close()
    text = parsed.text()
    lines = text.splitlines()
    if len(lines) < 5 or not lines[2].startswith('생성:') or not parsed.has_source:
        raise ValueError('structured note summary/source unavailable')
    divider = next((i for i, line in enumerate(lines) if line.startswith('━━━━')), None)
    if divider is None:
        raise ValueError('structured note divider unavailable')
    summary_lines = lines[3:divider]
    markup = [line for line in summary_lines if line.startswith(('- ', '  - '))]
    if not markup or any(services._clean_note_block_name(line) not in parsed.blocks for line in summary_lines if line not in markup):
        raise ValueError('editable note summary unavailable')
    original = services._original_from_plaintext(text, strip_prefix=False)
    return lines[1].strip(), '\n'.join(markup), original

def _rename_linked_note(services, note_id, title, before, runner=subprocess.run):
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.rename(services.host, note_id, title, before)
    """Use the existing rename_title preservation path, with no new original text or rebuild choice."""
    try:
        preview, summary, original = services._linked_note_sections(before['body_html'])
    except (KeyError, ValueError):
        return {'ok': False, 'reason': 'structured note snapshot incomplete'}
    current = services._note_verification_snapshot(note_id, runner)
    if not current or current.get('title') != before.get('title') or current.get('body_html') != before['body_html']:
        return {'ok': False, 'reason': 'note changed before rename'}
    _, reused = services._preserve_note_context(note_id, [], '', runner, reuse_source=True)
    if reused != original:
        return {'ok': False, 'reason': 'cached/source snapshot differs; do not overwrite'}
    result = json.loads(services._apple_notes_direct_mutation({
        'action': 'update', 'note_id': note_id, 'title': title, 'rename_title': True,
        'preview_summary': preview, 'summary': summary, 'approved': True, '_skip_common_work': True},
        runner=runner, _linked_title_authority=services._LINKED_TITLE_AUTHORITY, _linked_title_before=before))
    after = services._note_verification_snapshot(note_id, runner) if result.get('ok') else None
    try:
        preserved = bool(after and services._linked_note_sections(after['body_html']) == (preview, summary, original)
                         and sorted(before.get('attachment_names') or []) == sorted(after.get('attachment_names') or []))
    except (ValueError, KeyError):
        preserved = False
    ok = bool(result.get('ok') and after and after.get('title') == title and preserved
              and not (result.get('result') or {}).get('content_loss'))
    return {'ok': ok, 'before': before, 'after': after, 'receipt': result}

def _set_linked_note_progress(services, note_id, progress, runner=subprocess.run):
    if services.obsidian_notes.handles(note_id):return services.obsidian_notes.progress(services.host, note_id, progress)
    """Watcher-only (work_completion): rewrite one structured note with the same preview, summary and
    original, changing only the 진행도 on its 생성: line. Notes with photos and documents are rebuilt."""
    if progress not in services.NOTE_PROGRESS_VALUES:
        return {'ok': False, 'reason': 'invalid progress'}
    before = services._note_verification_snapshot(note_id, runner)
    if not before or not before.get('body_html'):
        return {'ok': False, 'reason': 'note unavailable'}
    if services._note_progress(before['body_html']) == progress:
        return {'ok': True, 'changed': False, 'note_id': note_id}
    if before.get('attachment_names') == []:
        # No attachments: compare-and-set only the 진행도 text; nothing else is rewritten.
        wanted = services._note_html_with_progress(before['body_html'], progress)
        if not wanted:
            return {'ok': False, 'reason': 'note layout not recognized'}
        script = Path(__file__).with_name('apple_notes_mutation.applescript')
        try:
            proc = runner(['/usr/bin/osascript', str(script), 'restore_plain', note_id, '', '',
                           wanted, before['body_html']], capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return {'ok': False, 'reason': 'note write uncertain'}
        after = services._note_verification_snapshot(note_id, runner) if not proc.returncode else None
        strip = lambda text: services._squash(re.sub(r"(· )?진행도: (진행중|완료)", "", str(text or "")))
        ok = bool(after and services._note_progress(after['body_html']) == progress
                  and strip(after.get('plaintext')) == strip(before.get('plaintext')) and after.get('attachment_names') == [])
        return {'ok': ok, 'changed': True, 'note_id': note_id, **({} if ok else {'reason': 'note verification failed'})}
    names = before.get('attachment_names') or []
    if names and not any(names):
        # Tables only (Notes lists each table as an unnamed attachment). Tables are rebuilt from the
        # body HTML, so a compare-and-set body edit keeps them; photos would be dropped, so they never
        # take this path. Bodies go through files (argv limit).
        wanted = services._note_html_with_progress(before['body_html'], progress)
        if not wanted:
            return {'ok': False, 'reason': 'note layout not recognized'}
        script = Path(__file__).with_name('apple_notes_mutation.applescript')
        with tempfile.TemporaryDirectory() as folder:
            want, expect = Path(folder) / 'want.html', Path(folder) / 'expect.html'
            want.write_text(wanted, encoding='utf-8'); expect.write_text(before['body_html'], encoding='utf-8')
            try:
                proc = runner(['/usr/bin/osascript', str(script), 'replace_body_cas', note_id, '', '',
                               str(want), str(expect)], capture_output=True, text=True, timeout=60, check=False)
            except (OSError, subprocess.TimeoutExpired):
                return {'ok': False, 'reason': 'note write uncertain'}
        after = services._note_verification_snapshot(note_id, runner) if not proc.returncode else None
        strip = lambda text: services._squash(re.sub(r"(· )?진행도: (진행중|완료)", "", str(text or "")).replace("\ufffc", ""))
        ok = bool(after and services._note_progress(after['body_html']) == progress
                  and len(after.get('attachment_names') or []) == len(names) and not any(after.get('attachment_names') or [])
                  and after['body_html'].count('<table') == before['body_html'].count('<table')
                  and strip(after.get('plaintext')) == strip(before.get('plaintext')))
        if not ok and after and not proc.returncode:
            return {'ok': False, 'reason': 'table note verification failed', 'before_html': before['body_html']}
        return {'ok': ok, 'changed': True, 'note_id': note_id}
    # Photos or documents: Notes drops them when the body is replaced, and a full rewrite re-renders the
    # summary (list/table layout), which the linked-work sync would read as a content change. Skip.
    return {'ok': False, 'reason': 'note with photos or files: 진행도 not written'}

def _notes_reuse_source(services, action, args):
    return action == "update" and args.get("rename_title") is True and not str(args.get("original_text") or "").strip()

def _apple_notes_restore(services, args: dict[str, Any], runner: Any) -> str:
    """Rollback-only: put a note's saved HTML body back exactly as it was."""
    note_id = str(args.get("note_id") or "").strip()
    body_html = str(args.get("body_html") or "")
    if not note_id or not body_html:
        return services._error("restore needs note_id and body_html")
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    try:
        proc = runner(["/usr/bin/osascript", str(script), "restore", note_id, "", "", body_html],
                      capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"APPLE_NOTES_NATIVE_UNAVAILABLE:{type(exc).__name__}")
    if proc.returncode != 0:
        return services._error(f"APPLE_NOTES_RESTORE_FAILED:{proc.returncode}")
    # Reuse the existing exact-key / unique old-store attachment discovery, without
    # changing the restored HTML or attaching files during rollback.
    try:
        pending, _ = services._preserve_note_context(note_id, [], "", runner)
    except services.NoteAttachmentsNotPreserved:
        pending = []
    saved = services._read_note_context().get(note_id)
    if saved is not None:
        services._remember_note_context(note_id, saved.get("attachments") or [], "")
    output = str(proc.stdout or "").strip().split("\t", 1)
    return json.dumps({
        "ok": True, "authority": "Apple Notes", "action": "restore", "target_id": note_id,
        "result": {"note_id": note_id, "title": output[1] if len(output) == 2 else None,
                   **({"attachments_pending": list(dict.fromkeys(Path(path).name for path in pending))} if pending else {})},
        "mutation_calls": 1, "approved": True, "fallback_used": False, "tool_search_calls": 0,
    }, ensure_ascii=False)

def _apple_notes_direct_mutation(services, args: dict[str, Any], **context: Any) -> str:
    # Only strict company linked-work adapters may reuse this preservation path in background.
    if context.get('_linked_title_authority') is not services._LINKED_TITLE_AUTHORITY:
        if error := services._personal_owner_error("apple_notes_direct_mutation"):
            return error
    if services.obsidian_notes.selected(services.host) or services.obsidian_notes.handles(args.get('note_id')):
        try:
            return services.obsidian_notes.mutate(services.host, args, context)
        except Exception as exc:
            return services._error('Obsidian 반영 확인 필요: '+str(exc), reflection_unknown=bool(context.get('_obsidian_write_attempted')))
    action = str(args.get("action") or "").strip().lower()
    if action == "restore" and args.get("_skip_common_work") is True:
        return services._apple_notes_restore(args, context.get("runner") or subprocess.run)
    if action == "rollback_rebuild" and args.get("_rollback"):
        return json.dumps(services.notes_rebuild.rollback(services.host, args["reconstruction"],
                                                context.get("runner") or subprocess.run), ensure_ascii=False)
    if action == "pending_choices":
        return json.dumps({"ok": True, "choices": [c for c in services._note_choices().values() if c.get("status") == "waiting"]}, ensure_ascii=False)
    if action == "apply_choice":
        return services._apply_note_choice(args, context.get("runner") or subprocess.run)
    if action not in {"create", "update", "move", "delete"}:
        return services._error("invalid Apple Notes mutation action", mutation_calls=0)
    note_id = str(args.get("note_id") or "").strip()
    folder = str(args.get("folder") or "").strip()
    if action == "create" and (not folder or folder == services.INBOX_NOTES_FOLDER):
        folder = services._notes_create_folder(folder)
    title = str(args.get("title") or "").strip()
    preview_summary = str(args.get("preview_summary") or "").strip()
    summary = str(args.get("summary") or "").strip()
    original_text = str(args.get("original_text") or "")
    if action in {"create", "update"} and (problem := services.notes_format.validate_summary(summary)):
        return services._error(problem, mutation_calls=0)
    raw_attachments = args.get("attachments", [])
    attachments: list[str] = []
    if raw_attachments is not None:
        if not isinstance(raw_attachments, list) or len(raw_attachments) > 10:
            return services._error("attachments must be an array of at most 10 absolute file paths", mutation_calls=0)
        for raw_path in raw_attachments:
            if not isinstance(raw_path, str) or not raw_path.strip():
                return services._error("each attachment must be a non-empty absolute file path", mutation_calls=0)
            path = Path(raw_path).expanduser()
            if not path.is_absolute():
                return services._error("each attachment path must be absolute", mutation_calls=0)
            try:
                resolved = path.resolve(strict=True)
            except OSError:
                return services._error(f"attachment not found: {path}", mutation_calls=0)
            if not resolved.is_file():
                return services._error(f"attachment is not a file: {resolved}", mutation_calls=0)
            attachments.append(str(resolved))
    if action in {"create", "update"} and attachments:
        attachments = services._stable_note_files(attachments)
    body = services._structured_note_body(summary, original_text, preview_summary) if action in {"create", "update"} else ""
    if action != "create" and not note_id:
        return services._error("note_id is required for this action", mutation_calls=0)
    if action in {"create", "update"} and not title:
        return services._error("title is required for note creation or update", mutation_calls=0)
    if action == "update" and args.get("rename_title") is True and (not preview_summary or not summary):
        return services._error(services._NOTE_RENAME_SUMMARY_REQUIRED, mutation_calls=0)
    if action in {"create", "update"} and (not preview_summary or not summary or (not original_text.strip() and not services._notes_reuse_source(action, args))):
        return services._error("preview_summary, summary, and original_text are required for note creation or update", mutation_calls=0)
    if action in {"create", "update"} and ("\n" in preview_summary or len(preview_summary) > 140):
        return services._error("preview_summary must be one line and at most 140 characters", mutation_calls=0)
    if action not in {"create", "update"} and attachments:
        return services._error("attachments are supported only for note creation or update", mutation_calls=0)
    if action == "move" and not folder:
        return services._error("folder is required for note move", mutation_calls=0)
    preview = {key: value for key, value in {
        "note_id": note_id or None, "folder": folder or None,
        "title": title or None, "body": body if action in {"create", "update"} else None,
        "attachments": attachments or None,
        "common_id": str(args.get("common_id") or "").strip() or None,
    }.items() if value is not None}
    if not bool(args.get("approved")) and not services._owner_chat_no_approval("apple_notes_direct_mutation", action, args):
        return services._mutation_preview("Apple Notes", action, preview)

    runner = context.get("runner") or subprocess.run
    created_at, note_folder = (
        services._note_native_info(note_id, runner) if action == "update" else (None, folder)
    )
    existing_files = []
    if action == "update" and not args.get("_rollback"):
        # An update rewrites the whole body: keep attachments and earlier source text the
        # model did not repeat, so a follow-up edit can never silently drop them.
        try:
            existing_files, _ = services._preserve_note_context(note_id, [], "", runner)
            attachments, original_text = services._preserve_note_context(
                note_id, attachments, original_text, runner, reuse_source=services._notes_reuse_source(action, args),
            )
        except ValueError as exc:
            return services._error(str(exc), mutation_calls=0)
        if not args.get("rename_title"):
            # Rule: the title changes only when the user asked (rename_title=true).
            current_title = (services._note_plaintext(note_id, runner).splitlines() or [""])[0].strip()
            if current_title:
                title = current_title
        attachments = services._stable_note_files(attachments)
        existing_files = services._stable_note_files(existing_files)
        removed_attachments = services._drop_existing_note_files(attachments, existing_files, args.get("remove_existing"))
        attachments = [p for p in attachments if p not in removed_attachments]
        body = services._structured_note_body(summary, original_text, preview_summary)
    attachments_skipped = []
    if action in {"create", "update"}:
        try:
            attachments, attachments_skipped = services._select_note_attachments(
                attachments, services._stable_note_files(existing_files))
        except services.NoteAttachmentsNotPreserved as exc:
            return services._error(str(exc), mutation_calls=0)
    summary_blocks_removed = None
    before_verification = None
    if action == "update" and not args.get("_rollback"):
        before_verification = services._note_verification_snapshot(note_id, runner)
        if before_verification and before_verification.get("body_html"):
            summary_blocks_removed = services._removed_summary_blocks(before_verification["body_html"], summary)
    # 진행도 (2026-10-26): kept across rewrites; company task notes start 진행중; the linked-work
    # watcher sets 완료 on completion.
    progress = str(args.get("progress") or "").strip()
    if progress not in services.NOTE_PROGRESS_VALUES:
        progress = services._note_progress((before_verification or {}).get("body_html", "")) if action == "update" else (
            "진행중" if action == "create" and folder == services.DEFAULT_NOTES_FOLDER else "")
    runner = context.get("runner") or subprocess.run
    if context.get('_linked_title_authority') is services._LINKED_TITLE_AUTHORITY:
        expected = context['_linked_title_before']
        if not before_verification or any(before_verification.get(k) != expected.get(k) for k in ('title', 'body_html')):
            return services._error('APPLE_NOTES_CONCURRENT_CHANGE', mutation_calls=0)
    exported = False
    if action == "update" and not args.get("_rollback") and before_verification:
        native_all = before_verification.get("attachment_names") or []
        native_names = [n for n in native_all if n]
        # Unnamed native items are tables, rebuilt from the body; only missing files need copying out.
        if native_names and services.notes_rebuild.names(native_names) != services.notes_rebuild.names(existing_files):
            # Attachments the user added by hand have no saved originals: copy them out of Notes.
            originals = services._export_note_attachments(note_id, runner, str(before_verification.get("body_html") or ""))
            if originals is None:
                return services._error("APPLE_NOTES_REBUILD_ORIGINAL_FILES_REQUIRED", mutation_calls=0)
            added = [p for p in attachments if p not in existing_files]
            existing_files, attachments, exported = originals, [*originals, *added], True
            removed_attachments = services._drop_existing_note_files(attachments, existing_files, args.get("remove_existing"))
            attachments = [p for p in attachments if p not in removed_attachments]
            attachments, _ = services._select_note_attachments(attachments)
    if action == "update" and not args.get("_rollback") and before_verification is not None:
        shown = len(set(re.findall(r'src="(data:image/[^"]{0,64})', str(before_verification.get("body_html") or ""))))
        keeping = sum(services._is_note_image(p) for p in attachments)
        if (shown and not isinstance(before_verification.get("attachment_names"), list)) or (
                shown > keeping and args.get("remove_existing") not in {"images", "all"}):
            # The rewrite would drop photos that cannot be put back.
            return services._error("APPLE_NOTES_REBUILD_SNAPSHOT_REQUIRED" if not isinstance(before_verification.get("attachment_names"), list)
                          else "APPLE_NOTES_PHOTOS_NOT_PRESERVED: 메모의 사진 원본을 확보하지 못해 고치지 않았다.", mutation_calls=0)
    mixed = any(services._is_note_image(p) for p in attachments) and any(not services._is_note_image(p) for p in attachments)
    if action == "update" and not args.get("_rollback") and before_verification and mixed:
        # Rewriting a note that keeps photos and documents drops the documents (Notes scripting limit).
        mode = str(args.get("mixed_mode") or "").strip()
        if mode not in {"rebuild", "screen"}:
            return json.dumps({
                "ok": False, "error": "APPLE_NOTES_MIXED_NEEDS_CHOICE", "needs_choice": True, "mutation_calls": 0,
                "note_id": note_id, "files": [Path(p).name for p in attachments],
                "options": {
                    "rebuild": "새 메모로 다시 만들어 고침. 내용·표·첨부는 유지, 메모 ID·링크·만든 날짜가 바뀌고 공유 중이면 공유가 풀림.",
                    "keep": "고치지 않고 그대로 둠. 원하면 메모 앱에서 직접 넣는다. (화면 조작 방식은 시험에서 첨부가 사라져 사용 중지)",
                },
                "instruction": "Nothing was written. Ask the owner which option to use, then call update again with mixed_mode.",
            }, ensure_ascii=False)
        if mode == "screen":
            return json.dumps(services.notes_screen.append(
                services.host, note_id=note_id, before=before_verification,
                lines=[x for x in str(args.get("append_text") or "").splitlines() if x.strip()],
                files=[p for p in attachments if p not in existing_files], runner=runner), ensure_ascii=False)
        if not exported:
            originals = services._export_note_attachments(note_id, runner, str(before_verification.get("body_html") or ""))
            if originals is None:
                return services._error("APPLE_NOTES_REBUILD_ORIGINAL_FILES_REQUIRED", mutation_calls=0)
            added = [p for p in attachments if p not in existing_files]
            existing_files, exported = originals, True
            attachments = [p for p in [*originals, *added] if p not in services._drop_existing_note_files(
                [*originals, *added], originals, args.get("remove_existing"))]
            attachments, _ = services._select_note_attachments(attachments)
        return json.dumps(services.notes_rebuild.rebuild(
            services.host, note_id=note_id, folder=note_folder, title=title, exported=exported,
            body=services._notes_html(title, body, [], attachment_analysis=str(args.get("attachment_analysis") or ""),
                             layout=services._notes_layout(note_folder), progress=progress), files=attachments, existing=existing_files,
            before=before_verification, args={**args, "original_text": original_text}, runner=runner), ensure_ascii=False)
    script = Path(__file__).with_name("apple_notes_mutation.applescript")
    command = [
        "/usr/bin/osascript", str(script), action, note_id, folder,
        "" if action == "create" else title,
        services._notes_html(
            title, body, attachments, created_at=created_at,
            attachment_analysis=str(args.get("attachment_analysis") or ""),
            layout=services._notes_layout(note_folder), progress=progress,
        ) if action in {"create", "update"} else "",
    ]
    command.extend(path for path in attachments if services._is_note_image(path))
    try:
        proc = runner(command, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return services._error(f"APPLE_NOTES_NATIVE_UNAVAILABLE:{type(exc).__name__}")
    if proc.returncode != 0:
        detail = str(proc.stderr or "").strip().replace("\n", " ")[:300]
        suffix = f":{detail}" if detail else ""
        return services._error(f"APPLE_NOTES_MUTATION_FAILED:{proc.returncode}{suffix}")
    output = str(proc.stdout or "").strip().split("\t", 3)
    result = {"note_id": output[0] if output else note_id}
    if attachments_skipped:
        result["attachments_skipped"] = attachments_skipped
    if action == "update":
        result["summary_blocks_removed"] = summary_blocks_removed
        if not args.get("_rollback"):
            result["verification"], result["content_loss"] = services._verify_note_after_update(
                note_id, runner, before_verification, attachments, summary_blocks_removed,
                title=title if args.get("rename_title") is True else None,
            )
    if len(output) >= 2:
        result["title"] = output[1]
    if len(output) == 4:
        result["native_attachment_count"] = int(output[2])
        result["native_attachment_names"] = output[3].splitlines()
    if action in {"create", "update"} and attachments:
        missing = services._note_missing_files(str(result['note_id']), attachments, runner)
        if missing:
            recovery = None
            if action == "update" and before_verification and before_verification.get("body_html"):
                recovery = json.loads(services._apple_notes_restore({
                    "note_id": note_id, "body_html": before_verification['body_html']}, runner))
                restored = services._note_verification_snapshot(note_id, runner)
                recovery['attachments_restored'] = bool(restored and
                    sorted(restored.get('attachment_names') or []) ==
                    sorted(before_verification.get('attachment_names') or []))
            return json.dumps({"ok": False, "error": "APPLE_NOTES_ATTACHMENTS_MISMATCH",
                               "target_id": result['note_id'], "attachments_missing": missing,
                               "rollback": recovery, "result": result}, ensure_ascii=False)
    if action == "move":
        _, actual_folder = services._note_native_info(note_id, runner)
        if result.get("note_id") != note_id or actual_folder != folder:
            return services._error("APPLE_NOTES_MOVE_NOT_CONFIRMED")
    if action in {"create", "update"} and result.get("note_id"):
        services._remember_note_context(str(result["note_id"]), attachments, original_text)
        result["attachments"] = len(attachments)
    common_work = None
    if action == "delete" and not args.get("_skip_common_work"):
        common_work = {"unlinked": services._unlink_owner_deleted_source("notes", note_id)}
    if action != "delete" and not args.get("_skip_common_work"):
        common_work = services._register_approved_common_work_source(
            domain="notes",
            source_id=str(result.get("note_id") or note_id or ""),
            title=title,
            common_id=str(args.get("common_id") or ""),
            source_date=(services._note_link_state(preview_summary + '\n' + summary).get('due') or '')[:10] or None,
        )
    services._clear_pending_personal_owner()
    payload = {
        "ok": True, "authority": "Apple Notes", "action": action,
        "target_id": result.get("note_id") or note_id or None, "result": result,
        "mutation_calls": 1, "approved": True, "fallback_used": False,
        "tool_search_calls": 0,
    }
    if common_work is not None:
        payload["common_work"] = common_work
    return json.dumps(payload, ensure_ascii=False)


class NoteHTML(HTMLParser):
    def __init__(self, services):
        self._services = services
        super().__init__(convert_charrefs=True)
        self.parts = []; self.cells = None; self.cell = None
        self.tables = 0; self.images = 0; self.objects = []; self.hidden = 0
        self.blocks = []; self.source_started = False; self.has_source = False
        self.list_depth = 0; self.inbox_summary = False; self.block_label = None
        self.summary_list = None

    def emit(self, text):
        (self.cell if self.cell is not None else self.parts).append(text)

    def handle_starttag(self, tag, attrs):
        if self.summary_list is not None:
            self.summary_list.start(tag, attrs); return
        if tag in ('style', 'script'): self.hidden += 1
        if self.hidden: return
        if tag in ('table', 'ul'):
            lines = [line.strip() for line in ''.join(self.parts).splitlines() if line.strip()]
            heading = lines[-1] if lines else ''
            if not self.source_started and heading and heading != '정리' and self.list_depth == 0:
                self.blocks.append(self._services._clean_note_block_name(heading))
                if tag == "ul" and not self.inbox_summary:
                    self.summary_list = self._services.notes_format.ListReader(self._services._clean_note_block_name(heading))
                    self.summary_list.start(tag, attrs); return
            if tag == 'ul':
                if heading == '정리': self.inbox_summary = True
                self.list_depth += 1
        if tag == 'b' and self.inbox_summary and self.list_depth == 1 and not self.source_started:
            self.block_label = []
        if tag == 'object': self.objects.append(False)
        if tag == 'table':
            self.tables += 1
            if self.objects: self.objects[-1] = True
        elif tag == 'tr':
            if self.cells is not None: raise ValueError('nested row')
            self.cells = []
        elif tag in ('td', 'th'):
            if self.cell is not None: raise ValueError('nested cell')
            self.cell = []
        elif tag == 'img':
            self.images += 1; self.emit('[사진 %d]' % self.images)
            if self.objects: self.objects[-1] = True
        elif tag in ('br', 'div', 'p', 'li', 'h1', 'h2', 'h3'): self.emit('\n')

    def handle_endtag(self, tag):
        if self.summary_list is not None:
            self.summary_list.end(tag)
            if self.summary_list.depth == 0:
                self.emit("\n" + self.summary_list.text() + "\n")
                self.summary_list = None
            return
        if tag in ('script', 'style'):
            self.hidden = max(0, self.hidden - 1); return
        if self.hidden: return
        if tag == 'ul':
            self.list_depth = max(0, self.list_depth - 1)
        if tag == 'b' and self.block_label is not None:
            self.blocks.append(self._services._clean_note_block_name(''.join(self.block_label)))
            self.block_label = None
        if tag in ('td', 'th'):
            if self.cell is None or self.cells is None: raise ValueError('invalid cell')
            self.cells.append(' '.join(''.join(self.cell).split())); self.cell = None
        elif tag == 'tr':
            if self.cells is None: raise ValueError('invalid row')
            self.parts.append('\n' + ' | '.join(self.cells) + '\n'); self.cells = None
        elif tag == 'object':
            if not self.objects: raise ValueError('invalid object')
            if not self.objects.pop(): self.emit('[첨부]')
        elif tag in ('div', 'p', 'li', 'table', 'h1', 'h2', 'h3'): self.emit('\n')

    def handle_data(self, data):
        if self.summary_list is not None:
            self.summary_list.data(data); return
        if not self.hidden:
            if data.strip() in ('원문', '[원문]') and self.cell is None:
                self.source_started = True; self.has_source = True
            if self.block_label is not None: self.block_label.append(data)
            self.emit(re.sub(r'data:[^\s<>\"\']+', '', data).replace('\ufffc', '[첨부]'))

    def text(self):
        if self.cells is not None or self.cell is not None or self.objects or self.hidden or self.summary_list is not None:
            raise ValueError('incomplete HTML')
        lines = []
        source = False
        for raw in ''.join(self.parts).replace('\xa0', ' ').splitlines():
            heading = raw.strip()
            if heading in ('원문', '[원문]'):
                source = True
                lines.append(heading)
            elif heading in ('첨부 분석', '원문 첨부파일'):
                source = False
                lines.append(heading)
            elif heading:
                lines.append((raw[4:] if raw.startswith('    ') else raw) if source else (raw if raw.startswith("  - ") else heading))
        return '\n'.join(lines)


class NoteAttachmentsNotPreserved(ValueError):
    """A body rewrite would lose attachments whose source files are unavailable."""
