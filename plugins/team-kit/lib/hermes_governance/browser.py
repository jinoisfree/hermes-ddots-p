"""Unchanged browser policy."""
from __future__ import annotations
import json, base64, fcntl, hashlib, logging, html, os, re, sqlite3, subprocess, tempfile, sys, threading, time, unicodedata
from html.parser import HTMLParser
from datetime import date as date_type, datetime as datetime_type, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from zoneinfo import ZoneInfo


def _public_web_url(services, url: Any) -> bool:
    """True for an http(s) address that resolves outside this machine and its private networks."""
    from tools.url_safety import is_safe_url

    address = str(url or "").strip()
    if address and "://" not in address:  # the browser opens a bare domain over https
        address = f"https://{address}"
    return bool(address) and is_safe_url(address)

def _gate_memory_path(services) -> Path:
    return Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser() / "state" / "bundle-gates.json"

def _gate_thread(services) -> str:
    route = services._pending_personal_route()
    return f"{route['platform']}:{route['chat_id']}:{route['thread_id']}" if route else ""

def _read_gate_memory(services) -> dict[str, dict[str, float]]:
    try:
        data = json.loads(services._gate_memory_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    now = time.time()
    return {
        thread: kept for thread, shown in (data.items() if isinstance(data, dict) else ())
        if isinstance(shown, dict)
        and (kept := {digest: at for digest, at in shown.items()
                      if isinstance(at, (int, float)) and now - at < services._GATE_MEMORY_SECONDS})
    }

def _write_gate_memory(services, data: dict[str, dict[str, float]]) -> None:
    path = services._gate_memory_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Atomic: a concurrent reader must never see half a file and drop every gate entry.
        temp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        temp.write_text(json.dumps(data), encoding="utf-8")
        os.replace(temp, path)
    except OSError:
        logging.getLogger("team_delegation.personal").warning("could not write gate memory", exc_info=True)

def _note_gate_shown(services, digest: str) -> None:
    """Remember that this thread was shown this exact bundle at the approval gate."""
    if not (thread := services._gate_thread()):
        return
    with services._PERSONAL_BUNDLE_APPROVAL_LOCK:
        data = services._read_gate_memory()
        data.setdefault(thread, {})[digest] = time.time()
        services._write_gate_memory(data)

def _approved_after_the_gate(services, digest: str, *, session_id: str = "") -> bool:
    """True once: the thread was shown this exact bundle before, and the user's latest message is a plain approval."""
    thread = services._gate_thread()
    if not thread:
        return False
    said = next((services._LAST_USER_TEXT[name] for name in services._conversation_scopes(session_id) if name in services._LAST_USER_TEXT), "")
    from hermes_router.common_router import approval_response_choice

    if approval_response_choice(said) != "approve":
        return False
    with services._PERSONAL_BUNDLE_APPROVAL_LOCK:
        data = services._read_gate_memory()
        if digest not in data.get(thread, {}):
            return False
        del data[thread][digest]
        services._write_gate_memory(data)
    return True

def _typed_by_the_user(services, text: str) -> str:
    """The user's own words in a message: without the sender label and the context another plugin appends."""
    text = text.split("[다른 대화의 최근 맥락", 1)[0].split("[현재 프로젝트", 1)[0].strip()
    return re.sub(r"^\[[^\]\n]{0,120}\]\s*", "", text).strip()

def _answer_in_one_post(services, created: Any) -> None:
    """Have a card the lead profile just made come back as its own answer only.

    A card made in chat is subscribed to wake its maker and to post a status line as well, so the
    result arrived twice. Waking alone leaves one post: the answer in the maker's voice.
    """
    try:
        made = json.loads(created) if isinstance(created, str) else created
        route = services._pending_personal_route()
        if not (isinstance(made, dict) and made.get("ok") and made.get("task_id") and made.get("subscribed") and route):
            return
        from hermes_cli import kanban_db_connect as kbc
        from hermes_cli import kanban_db_notify as kbn

        conn = kbc.connect()
        try:
            kbn.add_notify_sub(
                conn, task_id=str(made["task_id"]), platform=route["platform"], chat_id=route["chat_id"],
                thread_id=route["thread_id"] or None, delivery_mode="wake",
            )
        finally:
            conn.close()
    except Exception:  # the card exists either way; a second post is the worst that happens
        logging.getLogger("team_delegation.personal").warning("could not quiet the status post", exc_info=True)

def _trim_address(services, url: str) -> str:
    """Cut what prose and markup leave stuck to an address: a bracket that closes one it never
    opened ("[글](https://a.kr/b)에서") ends it, and closing punctuation is not part of it."""
    depth = 0
    for index, char in enumerate(url):
        if char == "(":
            depth += 1
        elif char == ")":
            if depth == 0:
                url = url[:index]
                break
            depth -= 1
    return url.rstrip(".,;:!?…'\"*_~")

def _address_key(services, url: Any) -> str:
    """One spelling per address: no scheme, fragment, or trailing slash, and escapes decoded."""
    text = services._trim_address(str(url or "").strip())
    if not text:
        return ""
    try:
        parts = urlsplit(text if "://" in text else f"https://{text}")
        host, port = (parts.hostname or "").lower().rstrip("."), parts.port
    except ValueError:
        return ""
    if not host:
        return ""
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        pass
    query = unquote(parts.query.replace("+", " "))
    return (host + (f":{port}" if port not in (None, 80, 443) else "")
            + (unquote(parts.path).rstrip("/") or "/") + (f"?{query}" if query else ""))

def _addresses_in(services, text: str, *, typed: bool = False) -> set[str]:
    """Keys of the addresses written in ``text``. In what the user typed, a bare domain counts too."""
    text = services._JSON_UNICODE_RE.sub(lambda match: chr(int(match.group(1), 16)), text.replace("\\/", "/"))
    found: set[str] = set()
    for raw in services._URL_RE.findall(text):
        found.add(services._address_key(raw))
        # A particle written straight after an address ("https://a.kr/b에서") belongs to the sentence.
        found.add(services._address_key(re.split(r"[가-힣]", raw, maxsplit=1)[0]))
    if typed:
        found.update(services._address_key(raw) for raw in services._BARE_HOST_RE.findall(text))
    found.discard("")
    return found

def _strings(services, value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from services._strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from services._strings(item)

def _conversation_scopes(services, session_id: str = "") -> list[str]:
    """Names this conversation goes by; a card run is one conversation."""
    chat_id = services.get_session_env("HERMES_SESSION_CHAT_ID", "").strip()
    names = [
        str(session_id or "").strip(),
        services.get_session_env("HERMES_SESSION_KEY", "").strip(),
        services.get_session_env("HERMES_SESSION_ID", "").strip(),
        os.environ.get("HERMES_KANBAN_TASK", "").strip(),
        f"{chat_id}:{services.get_session_env('HERMES_SESSION_THREAD_ID', '').strip()}" if chat_id else "",
    ]
    return [name for name in dict.fromkeys(names) if name]

def _remember_addresses(services, request: dict[str, Any], session_id: str = "") -> None:
    """Note every address in what the user and the tools have said so far. The model's own words are
    left out: an address counts as shown only when it came from outside the model."""
    messages = request.get("messages")
    if not isinstance(messages, list):
        return
    shown: set[str] = set()
    read: dict[str, int] = {}
    last_user = ""
    for message in messages:
        if not isinstance(message, dict) or message.get("role") in {"assistant", "system", "developer"}:
            continue
        read[str(message.get("role"))] = read.get(str(message.get("role")), 0) + 1
        if message.get("role") == "user":
            last_user = services._typed_by_the_user(" ".join(services._strings(message.get("content"))))
        for text in services._strings(message.get("content")):
            shown |= services._addresses_in(text, typed=message.get("role") == "user")
    now = time.monotonic()
    with services._SEEN_URLS_LOCK:
        for name in [name for name, (at, _) in services._SEEN_URLS.items() if now - at > services._SEEN_URLS_TTL_SECONDS]:
            services._SEEN_URLS.pop(name, None)
        for name in services._conversation_scopes(session_id):
            services._SEEN_URLS[name] = (now, frozenset(shown))
            services._LAST_USER_TEXT[name] = last_user
        for name in list(services._LAST_USER_TEXT)[:-500]:
            services._LAST_USER_TEXT.pop(name, None)
    logging.getLogger("team_delegation.personal").info(
        "%s shown addresses (%d) in %s", services.LEAD_PROFILE, len(shown), ", ".join(f"{count} {role}" for role, count in read.items()))

def _shown_addresses(services, session_id: str = "") -> frozenset[str]:
    with services._SEEN_URLS_LOCK:
        return frozenset().union(
            *(services._SEEN_URLS.get(name, (0.0, frozenset()))[1] for name in services._conversation_scopes(session_id)))

def _lead_address_gate(services,
    tool_name: str, args: dict[str, Any], *, unattended: bool, session_id: str = "",
) -> dict[str, str] | None:
    """Gate unseen addresses handed to cards or opened during unattended runs."""
    if tool_name in services.URL_OPEN_TOOLS:
        if not unattended:
            return None
        given = args.get("urls") if tool_name == "web_extract" else [args.get("url")]
        candidates = [str(item).strip() for item in (given if isinstance(given, list) else [given]) if str(item or "").strip()]
    elif tool_name in {"kanban_create", "kanban_comment"}:
        text = " ".join(str(args.get(key) or "") for key in ("title", "body"))
        candidates = [services._trim_address(raw) for raw in services._URL_RE.findall(text)]
    else:
        return None
    shown = services._shown_addresses(session_id)
    unknown = list(dict.fromkeys(url for url in candidates if services._address_key(url) not in shown))
    if not unknown:
        return None
    listed = ", ".join(unknown)
    if unattended:
        return {"action": "block", "message": (
            "Refused: this address was not in the card, a search result, or a page read in this run, and a "
            f"run nobody is watching does not open addresses of its own making: {listed[:400]}. "
            "Reach the site through web_search (site:example.com) or leave it out.")}
    digest = hashlib.sha256("\n".join(sorted(unknown)).encode("utf-8", "replace")).hexdigest()[:12]
    # "승인하면" is the wording the ddots chat puts its 승인·거절 buttons under.
    return {"action": "approve", "rule_key": f"lead-address:{digest}",
            "message": f"승인하면 뒷작업에 넘깁니다. 이 대화에 나온 적 없는 주소입니다: {listed[:600]}"}

def _unescaped(services, text: str) -> str:
    """A tool result is JSON text: give back the line breaks, quotes and letters it escaped."""
    text = text.replace("\\n", "\n").replace('\\"', '"').replace("\\/", "/")
    return services._JSON_UNICODE_RE.sub(lambda match: chr(int(match.group(1), 16)), text)

def _squeezed(services, text: Any) -> str:
    """Text as it is compared: one case, no spaces."""
    return re.sub(r"\s+", "", str(text or "")).casefold()

def _refs_in(services, text: str) -> dict[str, tuple[str, str]]:
    """Each ref a snapshot lists, with the element's role and name."""
    rows: list[tuple[int, str, str, str]] = []
    # The tree starts in the middle of a JSON line: {"snapshot": "- generic ..., {"content": "410|- button ...
    for line in re.sub(r'":\s*"', '":\n', text).splitlines():
        if match := services._SNAPSHOT_LINE_RE.match(line):
            name, ref = services._SNAPSHOT_NAME_RE.match(match.group(3)), services._SNAPSHOT_REF_RE.search(match.group(3))
            rows.append((len(match.group(1)), match.group(2), name.group(1).strip() if name else "",
                         ref.group(1) if ref else ""))
    found: dict[str, tuple[str, str]] = {}
    for index, (indent, role, name, ref) in enumerate(rows):
        if not ref:
            continue
        if not name:
            inside = []
            for row in rows[index + 1:index + 2 + services._CAPTION_ROWS]:
                if row[0] <= indent:
                    break
                inside.append(row[2])
            if len(inside) <= services._CAPTION_ROWS:
                name = " ".join(text for text in inside if text)
        found[ref] = (role, name)
    return found

def _read_from_the_web_cache(services, arguments: Any) -> bool:
    """True for a read_file call on the saved rest of a page that came back cut short."""
    try:
        path = (arguments if isinstance(arguments, dict) else json.loads(str(arguments or "{}"))).get("path")
    except (ValueError, AttributeError):
        return False
    return services._inside(path, [services._web_cache_root()]) is not None

def _card_tool_texts(services, content: Any) -> list[str]:
    """Read each text part, without the core's untrusted-result header or image metadata."""
    parts = [content] if isinstance(content, str) else content if isinstance(content, list) else []
    texts = []
    for part in parts:
        raw = part
        if isinstance(part, dict) and part.get("type") == "text":
            raw = part.get("text")
        if not isinstance(raw, str):
            continue
        raw = raw.strip()
        if raw.startswith("<untrusted_tool_result"):
            opening, newline, body = raw.partition("\n")
            closing = "\n</untrusted_tool_result>"
            if not newline or not re.fullmatch(r"<untrusted_tool_result\b[^>\n]*>", opening) or not body.endswith(closing):
                continue
            # The core puts a notice paragraph between the opening tag and the first blank
            # line. Its wording may change; neither that notice nor the tags are page text.
            _, blank, raw = body[:-len(closing)].partition("\n\n")
            if not blank:
                continue
        texts.append(raw.strip())
    return texts

def _remember_page(services, request: dict[str, Any], session_id: str = "") -> None:
    """Note how the page last looked to the model and which text it may type into one: the user's own
    words (the own card's title/body on a worker), and what search results and pages showed. A tool
    result counts by the call it answers, not by what it says about itself, so text from mail, notes
    or a file never passes for web text."""
    messages = request.get("messages")
    if not isinstance(messages, list):
        return
    by_id: dict[str, tuple[str, Any]] = {}
    waiting: list[tuple[str, Any]] = []
    refs: dict[str, tuple[str, str]] = {}
    said: list[str] = []
    read: list[str] = []
    card_id = os.environ.get("HERMES_KANBAN_TASK", "").strip()
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role == "assistant":
            waiting = []
            for call in message.get("tool_calls") or []:
                function = call.get("function") if isinstance(call, dict) else None
                if isinstance(function, dict):
                    made = (str(function.get("name") or ""), function.get("arguments"))
                    waiting.append(made)
                    if call.get("id"):
                        by_id[str(call["id"])] = made
        elif role == "user":
            if not card_id:
                said.append(services._typed_by_the_user("\n".join(services._strings(message.get("content")))))
        elif role == "tool":
            made = by_id.get(str(message.get("tool_call_id") or "")) or (waiting[0] if waiting else ("", None))
            if made in waiting:
                waiting.remove(made)
            name, arguments = made
            if card_id:
                accepted = []
                for raw in services._card_tool_texts(message.get("content")):
                    try:
                        payload = json.loads(raw)
                    except (ValueError, AttributeError):
                        payload = {}
                    payload = payload if isinstance(payload, dict) else {}
                    # A refusal may quote the very text it blocked. It is not web text that
                    # a retry may type. Browser parts count only when the call succeeded.
                    if payload.get("error") or payload.get("success") is False:
                        continue
                    if name.startswith("browser_") and payload.get("success") is not True:
                        continue
                    if name == "kanban_show":
                        # The user's worker message only says "work kanban task <id>". Take
                        # the own card's title/body, never comments, handoffs or worker_context.
                        task = payload.get("task")
                        if isinstance(task, dict) and task.get("id") == card_id and services.team.has_role(task.get("assignee"), 'personal'):
                            said = [str(task.get("title") or ""), str(task.get("body") or "")]
                    accepted.append(raw)
                if not accepted:
                    continue
            if name == "browser_back":
                refs = {}
            if not (services._reads_the_web(name) or (name == "read_file" and services._read_from_the_web_cache(arguments))):
                continue
            text = services._unescaped("\n".join(accepted if card_id else services._strings(message.get("content"))))
            read.append(text)
            if name in {"browser_navigate", "browser_snapshot"}:
                refs = services._refs_in(text)
            elif name == "read_file":
                refs.update(services._refs_in(text))
    now = time.monotonic()
    view = (now, refs, services._squeezed("\n".join(said)), services._squeezed("\n".join(read)))
    with services._SEEN_URLS_LOCK:
        for name in [name for name, kept in services._PAGE_VIEWS.items() if now - kept[0] > services._SEEN_URLS_TTL_SECONDS]:
            services._PAGE_VIEWS.pop(name, None)
        for name in services._conversation_scopes(session_id):
            services._PAGE_VIEWS[name] = view
        for name in list(services._LAST_BROWSER_ACT)[:-500]:
            services._LAST_BROWSER_ACT.pop(name, None)
    if refs:
        logging.getLogger("team_delegation.personal").info(
            "%s page view: %d refs, may type from %d user and %d web characters",
            services.LEAD_PROFILE, len(refs), len(view[2]), len(view[3]))

def _page_view(services, session_id: str = "") -> tuple[dict[str, tuple[str, str]], str, str]:
    with services._SEEN_URLS_LOCK:
        for name in services._conversation_scopes(session_id):
            if name in services._PAGE_VIEWS:
                return services._PAGE_VIEWS[name][1:]
    return {}, "", ""

def _note_browser_act(services, tool_name: str, session_id: str = "") -> None:
    with services._SEEN_URLS_LOCK:
        for name in services._conversation_scopes(session_id):
            services._LAST_BROWSER_ACT.pop(name, None)
            services._LAST_BROWSER_ACT[name] = tool_name

def _acts_on_the_site(services, role: str, label: str) -> bool:
    """True when an element's whole name is an act: sending, voting, sharing, buying, logging in.
    "구매 가능" and "추천순" are not; "구매하기" and "추천 12" are."""
    name = re.sub(r"[^0-9a-z가-힣]+", "", services._COUNT_RE.sub("", label.casefold()))
    return bool(name) and bool(services._SENDS_RE.fullmatch(name) or (role != "link" and services._DEALS_RE.fullmatch(name)))

def _lead_browse_gate(services,
    tool_name: str, args: dict[str, Any], *, unattended: bool, session_id: str = "", tool_call_id: str = "",
) -> dict[str, str] | None:
    """Let the lead profile look around a page, and stop what would send something out of it."""
    if tool_name not in services.BROWSER_ACT_TOOLS:
        return None
    refs, said, read = services._page_view(session_id)
    once = str(tool_call_id or time.time_ns())  # one approval covers one call
    if tool_name == "browser_press":
        key = re.sub(r"[\s_+-]+", "", str(args.get("key") or "")).casefold()
        with services._SEEN_URLS_LOCK:
            last = next((services._LAST_BROWSER_ACT[name] for name in services._conversation_scopes(session_id)
                         if name in services._LAST_BROWSER_ACT), "")
        if key in services._NAVIGATION_KEYS or (key in {"enter", "return"} and last == "browser_type"):
            return None
        return {"action": "block", "message": (
            "browser_press takes Tab, Escape, the arrow keys, PageUp, PageDown, Home, End, Backspace and "
            "Delete, and Enter only as the call right after browser_type. To choose or open something, "
            "click it; to enter text, use browser_type.")}
    if tool_name == "browser_type":
        text = str(args.get("text") or "")
        typed = services._squeezed(text)
        words = [services._squeezed(word) for word in text.split()]
        # The user's own words in any order, or a run of text exactly as a page showed it.
        if not typed or typed in said or typed in read or all(len(word) > 1 and word in said for word in words):
            return None
        if unattended:
            return {"action": "block", "message": (
                "Refused: browser_type text was not in this card's title/body or web text read in this run: "
                + " ".join(text.split())[:400] + ". Call kanban_block with kind='needs_input' and ask the user "
                "for the exact text before continuing.")}
        digest = hashlib.sha256(f"{once}\n{text}".encode("utf-8", "replace")).hexdigest()[:12]
        # "승인하면" is the wording the ddots chat puts its 승인·거절 buttons under.
        return {"action": "approve", "rule_key": f"lead-browse:type:{digest}", "message": (
            "승인하면 브라우저 입력창에 넣습니다. 이 대화에서 한 말이나 읽은 웹 페이지에 없던 글입니다: "
            + " ".join(text.split())[:400])}
    ref = str(args.get("ref") or "").strip().lstrip("@")
    if ref not in refs:
        return {"action": "block", "message": (
            f"browser_click takes a ref that the latest snapshot of this page lists, and {ref or 'this one'} "
            "is not in it. Take browser_snapshot again (full=true also shows the text inside unnamed "
            "elements) and use a ref from it.")}
    role, label = refs[ref]
    if not services._acts_on_the_site(role, label):
        return None
    if unattended:
        return {"action": "block", "message": (
            f"Refused: browser_click on {label[:200]} appears to send, publish, buy, pay or log in. "
            "Nobody is here to approve it. Call kanban_block with kind='needs_input' and describe the "
            "action for the user before continuing.")}
    digest = hashlib.sha256(f"{once}\n{ref}\n{label}".encode("utf-8", "replace")).hexdigest()[:12]
    return {"action": "approve", "rule_key": f"lead-browse:click:{digest}", "message": (
        f"승인하면 브라우저에서 누릅니다. 사이트에 무언가를 올리거나 사는 동작으로 보입니다: {label[:200]}")}

def _browsing(services, next_call, tool_name: str, context: dict[str, Any]):
    """Record browser acts, close non-public destinations, and expose the current page address."""
    def run(args: dict[str, Any]) -> Any:
        result = next_call(args)
        task_id = context.get("task_id") or context.get("session_id")
        if tool_name in services.LEAD_BROWSE_TOOLS | {"browser_navigate"}:
            services._note_browser_act(tool_name, str(context.get("session_id") or ""))
        url = services._current_page_address(task_id) if tool_name in services.LEAD_BROWSE_TOOLS | {"browser_snapshot"} else ""
        if tool_name in services.LEAD_BROWSE_TOOLS and (left := services._page_off_the_public_web(task_id, url)):
            return services._error(f"That took the browser to an address on this machine or its network ({left[:200]}), "
                          "so the page was closed. The browser reads public pages only.")
        if tool_name in services.LEAD_BROWSE_TOOLS | {"browser_snapshot"}:
            try:
                payload = json.loads(result)
                if (isinstance(payload, dict) and payload.get("success") is True
                        and 0 < len(url) <= 2000 and url.startswith(("http://", "https://"))
                        and services._public_web_url(url)):
                    # Put the address before a potentially long snapshot, without changing the address.
                    return json.dumps({"url": url, **{k: v for k, v in payload.items() if k != "url"}},
                                      ensure_ascii=False)
            except Exception:
                pass  # An unreadable result or failed address check must leave the tool result intact.
        return result
    return run

def _current_page_address(services, task_id: Any) -> str:
    """Read the address once; decode the browser transport without rewriting the address."""
    try:
        from tools import browser_tool as browser

        key = browser._last_session_key(str(task_id or "default"))
        result = browser._session._run_browser_command(key, "eval", ["window.location.href"], timeout=5)
        url = (result.get("data") or {}).get("result") if result.get("success") else ""
        if not isinstance(url, str):
            return ""
        if url.startswith('"'):
            url = json.loads(url)
        return url if isinstance(url, str) else ""
    except Exception:
        logging.getLogger("team_delegation.personal").warning("could not check where the browser is", exc_info=True)
        return ""

def _page_off_the_public_web(services, task_id: Any, url: str | None = None) -> str:
    """The address the browser is on when a click or a key took it onto this machine or its network."""
    try:
        from tools import browser_tool as browser

        if url is None:
            url = services._current_page_address(task_id)
        if not url or url.startswith("about:") or (url.startswith(("http://", "https://")) and services._public_web_url(url)):
            return ""
        key = browser._last_session_key(str(task_id or "default"))
        browser._session._run_browser_command(key, "open", ["about:blank"])
        return url
    except Exception:  # the page could not be asked
        logging.getLogger("team_delegation.personal").warning("could not check where the browser is", exc_info=True)
        return ""

def _mark_unverified_links(services, response_text: Any = "", platform: Any = "", session_id: Any = "", **_: Any) -> str | None:
    """Before the lead profile's answer is sent, take the link out of any address nobody showed it,
    so neither a preview nor a tap carries whatever was written into it."""
    profile = (services.get_session_env("HERMES_SESSION_PROFILE", "") or os.environ.get("HERMES_PROFILE") or services._home_profile() or "").strip()
    surface = str(platform or services.get_session_env("HERMES_SESSION_PLATFORM", "")).strip().lower()
    if not services.team.has_role(profile, 'personal') or surface not in {"slack", "photon"} or not isinstance(response_text, str):
        return None
    shown = services._shown_addresses(str(session_id or ""))

    def inert(match: re.Match) -> str:
        url = services._trim_address(match.group(0))
        tail = match.group(0)[len(url):]
        before_particle = re.split(r"[가-힣]", url, maxsplit=1)[0]  # "https://a.kr/b에서"
        if (services._address_key(url) in shown or services._address_key(before_particle) in shown
                or match.string[max(0, match.start() - 1):match.start()] == "`"):
            return match.group(0)
        return f"`{url}` {services.UNVERIFIED_LINK_NOTE}{tail}"

    marked = services._URL_RE.sub(inert, response_text)
    return marked if marked != response_text else None
