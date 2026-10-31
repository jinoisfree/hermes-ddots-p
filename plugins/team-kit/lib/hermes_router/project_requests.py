"""Bounded request interpretation for the opt-in project hub.

Routing prose is never an authorization proof. The ingress receipt retains the
transport author's original caption separately from documents and routing prose.
"""
from __future__ import annotations

import html
import re


def direct_request(text):
    from hermes_router.common_router import _direct_text
    text = html.unescape(str(text or ''))
    text = re.split(r'\n\s*(?:[-=]{3,}\s*(?:\n|$)|<(?:html|body|div|table|span)\b)',
                    text, maxsplit=1, flags=re.I)[0]
    text = re.sub(r'<(html|body|div|table|style|blockquote)\b[^>]*>.*?</\1\s*>', '', text,
                  flags=re.I | re.S)
    text = re.split(r'\n\s*(?:[-=]{2,}\s*(?:Original|Forwarded)|보낸\s*사람\s*:|From\s*:)', text,
                    maxsplit=1, flags=re.I)[0]
    return _direct_text(text)


def operation_text(text):
    text = direct_request(text)
    # Existing artifacts are inputs, not requests to recreate them.
    text = re.sub(r'\([^()\n]*(?:연동|연결|참고)[^()\n]*\)', '', text)
    text = re.sub(r'기존\s+[^\n.!?]{0,100}?(?:연동|연결|참고)(?:만)?(?:\s*해줘)?', '', text)
    text = re.sub(r'(?:노션|notion)\s*(?:의\s*)?(?:내용|자료|기록)[^\n.!?]{0,30}?(?:참고|바탕|기반)(?:해서|으로|해)?', '', text, flags=re.I)
    text = re.sub(r'(?:메일|일정|메모)(?:이라는|라는|이라고\s*하는)\s*(?:열|칼럼|필드|속성)', '문서 열', text)
    return text.strip()


def addressed_profiles(text, hub):
    """Resolve the complete mention set once; every receiving bot sees the same set."""
    users = set(re.findall(r'<@([A-Z0-9]+)>', direct_request(text)))
    return sorted(profile for profile, user in hub.get('staff_user_ids', {}).items() if user in users)


def request_title(text):
    direct = direct_request(text)
    title = re.search(r'제목(?:은)?\s*[:：]\s*([^\n]+)', direct)
    if title:
        direct = title.group(1)
    direct = re.sub(r'<@[A-Z0-9]+>|@[a-z][a-z0-9-]+', '', direct)
    direct = re.sub(r'<[^>]+>', '', direct)
    return ' '.join(direct.split())[:60] or '첨부 자료 확인'


def record_request(store, source, text, profile):
    """Called only by the receiving gateway, before any model sees the message."""
    if re.search(r'(?i)(?:\bsecret\b|비밀\s*(?:자료|폴더|프로젝트|업무))', text):
        return
    project = store.ensure(source.scope_id, source.chat_id, source.thread_id, source.user_id, request_title(text))
    message_id = str(source.message_id or '')
    if not message_id:
        raise ValueError('The owner message ID is required.')
    def update(data):
        records = data.setdefault('requests', {})
        record = {'owner_id': source.user_id, 'message_id': message_id, 'profile': profile,
                  'text': text[:32000], 'truncated': len(text) > 32000}
        if message_id in records and records[message_id] != record:
            raise ValueError('The transport request already has different provenance.')
        records[message_id] = record
        # Transcript retention remains in state.db; this is a bounded working index.
        for old in list(records)[:-32]:
            del records[old]
        return data
    store.change(project['id'], update)
