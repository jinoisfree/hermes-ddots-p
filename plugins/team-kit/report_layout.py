"""Bounded morning summaries and readable Slack detail pages (no network I/O)."""
import re

REVIEW_GUIDE = "모두 승인=이 보고의 학습·스킬 전부 유지 · 모두 거절=전부 변경 전 복구 · 의견=일부만 고칠 때 번호와 내용을 글로 · 확인=읽음, 적용은 그대로 두고 나중에 결정"


def escape(text):
    return str(text).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def excerpt(text, limit=80):
    """One plain line, bounded after escaping; never cut an escape sequence."""
    text = ' '.join(str(text).split())
    text = re.sub(r'[*_`~]', '', text)
    result = ''
    for char in text:
        escaped = escape(char)
        if len(result) + len(escaped) > limit - 1:
            return result + '…'
        result += escaped
    return result


def summary(title, status, rows, action='', *, review=False, limit=3):
    paragraphs = [f'*{title}*\n{status}']
    if review and action:
        paragraphs.append('*검토할 일*\n' + action)
    for index, (label, text) in enumerate(rows[:limit], 1):
        paragraphs.append(f'*{index}. {excerpt(label, 48)}*\n> {excerpt(text, 90)}')
    if len(rows) > limit:
        paragraphs.append(f'외 *{len(rows) - limit}건* · 전체 {len(rows)}건은 스레드에서 확인')
    paragraphs.append('📎 전체 내용·근거는 이 스레드에 이어서')
    return '\n\n'.join(paragraphs)


def bundle_parts(parts, limit=2200):
    """Pack short detail items, retaining each item's identity for review repainting.

    Only newly built, unsent reports may call this. Existing parts/markers stay immutable.
    """
    if any(p.get('ts') or p.get('attempted_at') for p in parts):
        raise ValueError('cannot repack an attempted report')
    result, pending = [], []
    def flush():
        if pending:
            result.append({'text': '\n\n'.join(p['text'] for p in pending),
                           'review_kind': '묶음', 'entries': [dict(p) for p in pending]})
            pending.clear()
    for index, part in enumerate(parts):
        if index == 0 or part.get('review_kind') not in {'학습', '스킬'}:
            flush(); result.append(part); continue
        size = sum(len(p['text']) + 2 for p in pending) + len(part['text'])
        if size > limit or len(pending) >= 5: flush()
        if len(part['text']) > limit:
            result.append(part)
        else:
            pending.append(part)
    flush()
    return result


def reviewed_bundle(part, report):
    texts = []
    for entry in part['entries']:
        states = report.get('skill_review_state' if entry['review_kind'] == '스킬' else 'review_state', {})
        status = states.get(str(entry['item']), {}).get('status')
        label = {'confirmed': '✅ 승인', 'rejected': '↩️ 거절', 'corrected': '✏️ 수정됨',
                 'deferred': '⏸ 보류 · 적용 유지'}.get(status)
        texts.append(entry['text'] + ('\n' + label if label else ''))
    return '\n\n'.join(texts)


def empty_learning(day):
    """One dated notice, with no review action or nonexistent detail thread."""
    return f'*🔵 아침 학습 보고 · {day.isoformat()}*\n\n새로 학습한 내용이 없어. (0건)'


def chunks(paragraphs, limit=2800):
    """Preserve blank lines and short paragraphs, including very long single lines."""
    pages, current = [], ''
    for paragraph in paragraphs:
        # A Slack link or escaped character must stay together at a page boundary.
        tokens = re.findall(r'<[^>\n]+>|&(?:amp|lt|gt);|.', paragraph, re.DOTALL)
        parts, part = [], ''
        for token in tokens:
            if part and len(part) + len(token) > limit:
                parts.append(part)
                part = ''
            # Only malformed/oversized links reach this fallback.
            while len(token) > limit:
                if part:
                    parts.append(part)
                    part = ''
                parts.append(token[:limit])
                token = token[limit:]
            part += token
        if part:
            parts.append(part)
        for part in parts:
            if current and len(current) + len(part) + 2 > limit:
                pages.append(current)
                current = ''
            current += ('\n\n' if current else '') + part
    if current:
        pages.append(current)
    return pages



def metadata(marker):
    return {'event_type': 'hermes_morning_report', 'event_payload': {'marker': marker}}


def matches(message, marker):
    # Reports sent before the text-only layout still carry block IDs.
    return ((message.get('metadata') or {}).get('event_payload', {}).get('marker') == marker
            or any(block.get('block_id') == marker for block in message.get('blocks', [])))


def item_messages(text, kind, number):
    """One item per message. 2026-10-29 소유자 결정: 항목별 버튼은 없고 보고 첫 글·스레드 끝의 전체 버튼만 둔다."""
    return chunks([text], limit=2800)


def review_part(text):
    match = re.search(r"\n\[\[버튼: (학습|스킬) (\d+)번(?:만)? 승인 \| \1 \2번(?:만)? 거절 \| \1 \2번 수정\]\]\s*\Z", text)
    if match:  # reports sent before 2026-10-29 carried per-item buttons
        return dict(text=text, review_kind=match[1], item=int(match[2]))
    # 2026-10-29: item messages have no buttons; the heading names the item.
    head = re.match(r"\*(?:(\d+)\. |스킬 (\d+)번 · )", text)
    if head:
        return dict(text=text, review_kind="학습" if head[1] else "스킬", item=int(head[1] or head[2]))
    return dict(text=text)
