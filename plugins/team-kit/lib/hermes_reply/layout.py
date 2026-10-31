from __future__ import annotations
import re
from typing import Any, Dict, List, Optional, Tuple
from .blocks import Block, MAX_BLOCKS, MAX_SECTION_TEXT, _BULLET_RE, _FENCE_RE, _HEADER_RE, _HR_RE, _ORDERED_RE, _QUOTE_RE, _TABLE_SEP_RE, _UNDERLINE_RE, _divider_block, _header_block, _indent_level, _inline_elements, _is_list_line, _list_block, _preformatted_block, _quote_block, _render_table, _rich_text_block, _section_block, _split_text, _table_block, MAX_HEADER_TEXT
_ARROW_RE = re.compile(r"^(\s*)↳\s+(.*)$")

def render_blocks(markdown: str, mrkdwn_fn=None, arrows: bool = False) -> Optional[List[Block]]:
    """Convert agent markdown to a Slack Block Kit ``blocks`` list.
    Args:
        markdown: The agent's response text (standard markdown).
        mrkdwn_fn: Optional callable converting a markdown paragraph to Slack
            mrkdwn for ``section`` blocks (the adapter passes
            ``format_message``).  When ``None``, the raw paragraph text is used.

    Returns:
        A list of Block Kit block dicts, or ``None`` when the content is empty,
        exceeds Slack's structural limits, or hits an unexpected shape — the
        caller then falls back to the flat ``text`` payload.  Never raises."""
    if not markdown or not markdown.strip():
        return None
    fmt = mrkdwn_fn or (lambda s: s)

    try:
        blocks: List[Block] = []
        lines = markdown.replace("\r\n", "\n").split("\n")
        i = 0
        n = len(lines)
        para: List[str] = []

        def flush_para() -> None:
            if not para:
                return
            text = "\n".join(para).strip()
            para.clear()
            if not text:
                return
            if _UNDERLINE_RE.search(text):
                # mrkdwn sections cannot underline; a rich_text section keeps the span.
                blocks.append(_rich_text_block("rich_text_section", _inline_elements(text)))
                return
            rendered = fmt(text)
            # Split oversized sections on the 3000-char limit.
            for chunk in _split_text(rendered, MAX_SECTION_TEXT):
                blocks.append(_section_block(chunk))
        while i < n:
            line = lines[i]

            # Blank line: paragraph boundary
            if not line.strip():
                flush_para()
                i += 1
                continue

            # Fenced code block
            fence = _FENCE_RE.match(line)
            if fence:
                flush_para()
                marker = fence.group(1)
                body: List[str] = []
                i += 1
                while i < n and not lines[i].lstrip().startswith(marker):
                    body.append(lines[i])
                    i += 1
                i += 1  # consume closing fence
                blocks.append(_preformatted_block("\n".join(body)))
                continue

            # Horizontal rule → divider
            if _HR_RE.match(line):
                flush_para()
                blocks.append(_divider_block())
                i += 1
                continue

            # ATX header
            hm = _HEADER_RE.match(line)
            if hm:
                flush_para()
                header = _header_block(hm.group(2))
                if header is not None:
                    blocks.append(header)
                i += 1
                continue

            # Pipe table: current line has a pipe AND next line is a separator
            if "|" in line and i + 1 < n and _TABLE_SEP_RE.match(lines[i + 1]):
                flush_para()
                header_row = line
                sep_line = lines[i + 1]
                trows = [header_row]
                i += 2  # skip header + separator
                while i < n and "|" in lines[i] and lines[i].strip():
                    trows.append(lines[i])
                    i += 1
                # Prefer a native Block Kit table; fall back to aligned
                # monospace when it exceeds Slack's table limits or won't parse.
                table = _table_block(trows, sep_line)
                if table is not None:
                    blocks.append(table)
                else:
                    blocks.append(_preformatted_block(_render_table(trows)))
                continue

            # Blockquote group
            if _QUOTE_RE.match(line):
                flush_para()
                qlines: List[str] = []
                while i < n:
                    qm = _QUOTE_RE.match(lines[i])
                    if not qm:
                        break
                    qlines.append(qm.group(1))
                    i += 1
                blocks.append(_quote_block(qlines))
                continue

            # List group (bullets + ordered, with nesting)
            if _is_list_line(line):
                flush_para()
                items: List[Tuple[int, bool, str]] = []
                while i < n:
                    bm = _BULLET_RE.match(lines[i])
                    om = _ORDERED_RE.match(lines[i])
                    if bm:
                        items.append((_indent_level(bm.group(1)), False, bm.group(2)))
                        i += 1
                    elif om:
                        items.append((_indent_level(om.group(1)), True, om.group(3)))
                        i += 1
                    elif arrows and items and _ARROW_RE.match(lines[i]):
                        # ``arrows`` (report layout): a ↳ detail line is its own nested item, keeping the arrow.
                        am = _ARROW_RE.match(lines[i])
                        items.append((max(1, _indent_level(am.group(1))), False, "↳ " + am.group(2)))
                        i += 1
                    elif lines[i].strip() and lines[i].startswith((" ", "\t")) and items:
                        # continuation line of the previous item
                        indent, ordered, txt = items[-1]
                        items[-1] = (indent, ordered, txt + ("\n" if arrows else " ") + lines[i].strip())
                        i += 1
                    elif not lines[i].strip() and items:
                        # Blank line inside a list run. LLM-authored ordered
                        # lists commonly separate items with a blank line; if
                        # the next non-blank line is another list item, treat
                        # the blank(s) as a soft separator and keep the run
                        # going so the items stay in one rich_text_list (Slack
                        # numbers each list independently, so splitting would
                        # restart every item at "1."). Otherwise the blank
                        # ends the list.
                        j = i + 1
                        while j < n and not lines[j].strip():
                            j += 1
                        if j < n and _is_list_line(lines[j]):
                            i = j
                        else:
                            break
                    else:
                        break
                blocks.append(_list_block(items))
                continue

            # Default: accumulate into a paragraph
            para.append(line)
            i += 1
        flush_para()

        if not blocks:
            return None
        if len(blocks) > MAX_BLOCKS:
            # Too structurally complex to express safely — let the caller fall
            # back to plain text rather than truncating and losing content.
            return None
        return blocks
    except Exception:
        # Never let a rendering bug drop a message.
        return None


SECTION_COLORS = {"fail": "#E01E5A", "warn": "#ECB22E", "check": "#2EB67D", "plain": "#9AA0A6"}
# Yellow means "answer received, still working" (owner, 2026-10-23/26), so caution words in a finished
# reply no longer turn the bar yellow; only a title's 🟡/⚠️ mark does.
SECTION_WORDS = (("fail", ("긴급", "중요도 높음", "실패", "오류", "장애", "위험", "차단")),
                 ("check", ("중요도 보통", "중요", "주의", "경고", "지연",
                            "체크", "확인 필요", "확인할", "승인", "할 일", "결정", "답 필요", "답변 필요")))
TITLE_MARKS = (("fail", ("🔴", "❌", "🚨", "⛔", ":red_circle:", ":x:", ":rotating_light:")),
               ("warn", ("🟡", "⚠️", "⚠", "🟠", ":warning:", ":large_yellow_circle:", ":large_orange_circle:")),
               ("check", ("🟢", "✅", ":large_green_circle:", ":white_check_mark:")),
               ("plain", ("🔵", "ℹ️", "📌", ":large_blue_circle:", ":information_source:")))
# A bold line as mrkdwn (*x*) or as the agent's markdown (**x**), which a paragraph keeps until format_message.
_BOLD_LINE_RE = re.compile(r"^\*{1,2}([^*\n]{1,140})\*{1,2}$")
MAX_REPORT_SECTIONS = 12


def _section_kind(words: Optional[str]) -> Optional[str]:
    for kind, marks in SECTION_WORDS:
        if words and any(mark in words for mark in marks):
            return kind
    return None


def _title_mark(title: str) -> Tuple[Optional[str], str]:
    """The status a title's leading mark stands for, and the title without it."""
    for kind, marks in TITLE_MARKS:
        for mark in marks:
            if title.startswith(mark):
                rest = title[len(mark):].lstrip("️").strip()
                return kind, rest or title
    return None, title


def _heading(block: Block) -> Optional[Tuple[str, Optional[Block]]]:
    """``(heading, rest)`` when ``block`` opens a section: a header, or a section whose first line is bold."""
    if block.get("type") == "header":
        return (block.get("text") or {}).get("text", ""), None
    if block.get("type") == "section" and (block.get("text") or {}).get("type") == "mrkdwn":
        first, _, rest = block["text"]["text"].partition("\n")
        bold = _BOLD_LINE_RE.match(first.strip())
        if bold:
            return bold.group(1).strip(), ({"type": "section", "text": {"type": "mrkdwn", "text": rest}} if rest.strip() else None)
    return None


def _split_bold_lines(blocks: List[Block]) -> List[Block]:
    """A paragraph with a bold line inside it (no blank line before the heading) splits at that line."""
    out: List[Block] = []
    for block in blocks:
        text = (block.get("text") or {}).get("text") if block.get("type") == "section" else None
        if not isinstance(text, str) or (block.get("text") or {}).get("type") != "mrkdwn":
            out.append(block)
            continue
        parts: List[List[str]] = [[]]
        for index, line in enumerate(text.split("\n")):
            if index and _BOLD_LINE_RE.match(line.strip()) and parts[-1]:
                parts.append([])
            parts[-1].append(line)
        out.extend({"type": "section", "text": {"type": "mrkdwn", "text": "\n".join(part)}} for part in parts if "".join(part).strip())
    return out


def report_sections(blocks: Optional[List[Block]]) -> Optional[Tuple[List[Block], List[Dict[str, Any]]]]:
    """``(title blocks, [one coloured attachment])`` for a reply that opens with a title, else ``None``.

    Blocks Slack keeps outside attachments (feedback controls) stay after the title."""
    if not blocks:
        return None
    blocks = _split_bold_lines(blocks)
    opening = _heading(blocks[0])
    if not opening or (len(blocks) < 2 and opening[1] is None):
        return None
    kind, title = _title_mark(opening[0])
    fallback = (kind if kind != "plain" else None) or _section_kind(title) or "plain"
    top: List[Block] = [{"type": "header", "text": {"type": "plain_text", "text": title[:MAX_HEADER_TEXT], "emoji": True}}]
    # Words under a bold title line, in the same paragraph, open the first section.
    sections: List[Tuple[Optional[str], List[Block]]] = [(None, [opening[1]] if opening[1] else [])]
    for block in blocks[1:]:
        if block.get("type") == "context_actions":
            top.append(block)
            continue
        opened = _heading(block)
        if opened:
            name, rest = opened
            sections.append((name, [{"type": "section", "text": {"type": "mrkdwn", "text": f"*{name}*"}}] + ([rest] if rest else [])))
        else:
            sections[-1][1].append(block)
    sections = [(name, body) for name, body in sections if body]
    if not sections or len(sections) > MAX_REPORT_SECTIONS:
        return None
    # One bar for the whole reply (owner, 2026-10-19): with several attachments Slack and ddots draw two
    # lines beside every section. The most urgent section heading picks its colour.
    body = [block for _, blocks_ in sections for block in blocks_]
    if len(body) > 50:
        return None
    found = {_section_kind(name) for name, _ in sections} | {fallback}
    colour = next(kind for kind in ("fail", "warn", "check", "plain") if kind in found)
    return top, [{"color": SECTION_COLORS[colour], "blocks": body}]
