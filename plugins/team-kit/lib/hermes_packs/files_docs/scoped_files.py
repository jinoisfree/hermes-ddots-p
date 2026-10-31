"""File operations with an injected host contract; no plugin or profile imports.

Approval remains in the tool middleware. This pack checks path scope again at
execution, including symlink resolution, and never implements a background bypass.
"""
from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime as datetime_type
from pathlib import Path
from typing import Any, Callable
from dataclasses import dataclass
from zoneinfo import ZoneInfo


@dataclass(frozen=True)
class Services:
    """Per-call dependencies; the pack neither imports nor retains its host."""

    context: Any
    folders: Callable
    resolve: Callable
    read_tools: frozenset
    web_cache: Callable
    attachments: Callable
    images: Callable
    videos: Callable
    generated: Callable
    workspace: Callable
    error: Callable
    list_limit: int
    problem: Callable
    trash_script: str


def folders(services) -> list[Path]:
    """Folders the lead profile may read and, with approval, change: settings.lead_folders."""
    configured = services.context.get_config("lead_folders", []) if services.context is not None else []
    folders: list[Path] = []
    for item in configured if isinstance(configured, list) else []:
        try:
            folder = Path(str(item)).expanduser().resolve()
        except (OSError, RuntimeError, ValueError):
            continue
        if folder.is_absolute() and folder.is_dir():
            folders.append(folder)
    return folders


def inside(path: Any, roots: list[Path]) -> Path | None:
    """The resolved path when it is absolute and lies in one of ``roots``, else None. Links are followed
    first, so one that points out of a root does not pass."""
    try:
        target = Path(str(path or "")).expanduser()
        if not target.is_absolute():
            return None
        target = target.resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    return target if any(root == target or root in target.parents for root in roots) else None


def problem(services, tool_name: str, args: dict[str, Any]) -> str | None:
    """Why the lead profile may not make this file call; None when it may."""
    folders = services.folders()
    named = "; ".join(str(folder) for folder in folders) or "none are set"
    if tool_name in services.read_tools:
        roots = [*folders, services.web_cache(), services.attachments(), services.images(),
                 services.videos(), services.generated(), services.workspace()]
        if workspace := os.environ.get("HERMES_KANBAN_WORKSPACE", "").strip():
            roots.append(Path(workspace).resolve())
        target = services.resolve(args.get("path"), roots)
        if target is None or not target.exists() or (tool_name == "read_file" and not target.is_file()):
            return (f"{tool_name} needs the absolute path of an existing "
                    f"{'file' if tool_name == 'read_file' else 'file or folder'} inside the readable folders "
                    f"({named}), the saved rest of a web page, or a file the user attached in chat")
        return None
    folders = [*folders, services.attachments(), services.workspace()]
    target = services.resolve(args.get("path"), folders)
    if target is None:
        return (f"{tool_name} works only on an absolute path inside the readable folders ({named}) "
                "or on a file the user attached in chat")
    if tool_name == "patch" and (args.get("patch") or str(args.get("mode") or "replace") != "replace"):
        return "patch edits one file here: pass path, old_string and new_string"
    if tool_name == "patch" and not target.is_file():
        return "patch needs an existing file"
    if tool_name == "write_file" and target.is_dir():
        return "write_file needs a file path, not a folder"
    if tool_name == "file_trash" and (target in folders or not target.exists()):
        return "file_trash needs an existing file or folder below a readable folder, not the folder itself"
    return None


def list_files(services, args: dict[str, Any], **_: Any) -> str:
    folders = services.folders()
    if not str(args.get("path") or "").strip():
        return json.dumps({"ok": True, "readable_folders": [str(folder) for folder in folders]}, ensure_ascii=False)
    target = services.resolve(args.get("path"), [*folders, services.attachments(), services.images(),
                                             services.videos(), services.generated(), services.workspace()])
    if target is None or not target.is_dir():
        named = "; ".join(str(folder) for folder in folders) or "none are set"
        return services.error(f"file_list needs the absolute path of a folder inside the readable folders ({named}) "
                      "or the folder of the files the user attached in chat")
    entries: list[dict[str, Any]] = []
    try:
        with os.scandir(target) as listing:
            for entry in listing:
                if entry.name.startswith("."):
                    continue
                try:
                    folder = entry.is_dir(follow_symlinks=False)
                    info = entry.stat(follow_symlinks=False)
                    entries.append({
                        "name": entry.name, "kind": "folder" if folder else "file",
                        **({} if folder else {"bytes": info.st_size}),
                        "modified": datetime_type.fromtimestamp(info.st_mtime, ZoneInfo("Asia/Seoul")).strftime("%Y-%m-%d %H:%M"),
                    })
                except OSError:
                    entries.append({"name": entry.name, "kind": "closed by macOS"})
    except OSError as exc:
        return services.error(f"LIST_FAILED: macOS did not let Hermes open this folder ({exc.strerror or type(exc).__name__})")
    entries.sort(key=lambda entry: (entry["kind"] != "folder", entry["name"]))
    return json.dumps({
        "ok": True, "path": str(target), "count": len(entries), "entries": entries[:services.list_limit],
        **({"truncated": True} if len(entries) > services.list_limit else {}),
    }, ensure_ascii=False)


def trash(services, args: dict[str, Any], runner: Any = None, **_: Any) -> str:
    if problem := services.problem("file_trash", args):
        return services.error(problem)
    target = services.resolve(args.get("path"), [*services.folders(), services.attachments()])
    try:
        result = (runner or subprocess.run)(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", services.trash_script, str(target)],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return services.error(f"TRASH_FAILED:{type(exc).__name__}")
    if result.returncode != 0 or str(result.stdout).strip() != "trashed" or target.exists():
        return services.error("TRASH_FAILED: the item is still in place")
    return json.dumps({"ok": True, "moved_to_trash": str(target)}, ensure_ascii=False)
