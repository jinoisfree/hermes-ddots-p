"""Ephemeral, text-only Slack previews for desktop-pet; Slack remains authoritative.

Stream observers run on separate queues. End events seal a generation so late
queued deltas cannot resurrect it. No API calls, tools, reasoning or chat history
are exported. Files are private, bounded snapshots, never a conversation log.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import threading
import time


logger = logging.getLogger("team_kit.chat_streaming")


class PreviewWriter:
    def __init__(self, home, clock=time.time):
        self.home = Path(home)
        self.folder = self.home / 'cache' / 'desktop-pet-streams'
        self.clock = clock
        self.lock = threading.RLock()
        self.sessions = {}
        self.generations = {}
        self.closed = {}

    def begin(self, session_id='', platform='', **_):
        if platform != 'slack' or not session_id:
            return
        now = self.clock()
        try:
            with sqlite3.connect(f'file:{self.home / "state.db"}?mode=ro', uri=True, timeout=.2) as db:
                row = db.execute("SELECT s.chat_id,s.thread_id,l.acquired_at FROM sessions s "
                                 "JOIN session_turn_leases l ON l.conversation_id=s.id "
                                 "WHERE s.id=? AND s.source='slack' AND l.expires_at>?",
                                 (session_id, now)).fetchone()
            if not row or not row[0] or not row[1]:
                logger.info('Preview binding unavailable: session=%s profile=%s reason=%s',
                            session_id, self.home.name, 'no_active_route' if not row else 'incomplete_route')
                return
            with self.lock:
                previous = self.sessions.get(session_id, {})
                pending = previous.get('pending') if previous.get('since') == row[2] else None
                self.sessions[session_id] = dict(room=row[0], thread=row[1], since=row[2], touched=now)
                old = self.generations.pop(session_id, None)
                if old:
                    self.closed[old['key']] = now
                self._remove(session_id)
                if pending:
                    self.sessions[session_id]['pending'] = pending
                    self.sessions[session_id]['status'] = 'applying'
                    self._write_status(session_id, now)
                self._prune(now)
                logger.info('Preview bound: session=%s profile=%s', session_id, self.home.name)
        except (OSError, sqlite3.Error) as exc:
            logger.warning('Preview binding failed: session=%s error=%s', session_id, type(exc).__name__)
            return

    def busy(self, session_id='', platform='', message_id='', status='', turn_id=None, iteration=None, **_):
        if platform != 'slack' or status not in ('waiting', 'redirecting') or not message_id:
            return
        with self.lock:
            meta = self.sessions.get(session_id)
            if not meta:
                return
            now = self.clock()
            # Receipt IDs allow repeat deliveries to remain idempotent in the display.
            if meta.get('pending') == message_id:
                return
            current = self.generations.get(session_id)
            previous = (session_id, turn_id, iteration) if isinstance(turn_id, str) and isinstance(iteration, int) else (current or {}).get('key')
            advanced = current and previous and current['key'][1] == previous[1] and current['key'][2] > previous[2]
            if advanced and current.get('done'):
                return
            meta.update(pending=message_id, status='applying' if advanced else status,
                        touched=now, previous_key=previous)
            if status == 'redirecting' and previous:
                self.closed[previous] = now
                if current and current['key'] == previous:
                    self.generations.pop(session_id, None)
            self._write_status(session_id, now)

    def _write_status(self, session, now):
        state = self.generations.get(session) or dict(key=(session, 'status', 0), text='', written=0.)
        self._write(session, state, now, False)

    def stream_started(self, session_id='', surface='', model='', **_):
        if surface != 'slack':
            return
        with self.lock:
            meta = self.sessions.get(session_id)
            if not meta or self.generations.get(session_id, {}).get('done'):
                return
            name = model if isinstance(model, str) and re.fullmatch(r'[\w. /:-]{1,100}', model) else '모델'
            meta['model'] = name
            meta['execution'] = f'{name} · 응답 대기 중'
            meta['activity'] = '답변을 준비하고 있습니다'
            self._write_status(session_id, self.clock())

    def tool_started(self, session_id='', tool_name='', tool_call_id='', args=None, **_):
        labels = {'mail_read': '이메일 도구를 확인하고 있습니다',
                  'gmail_direct': '이메일을 확인하고 있습니다',
                  'team_work': '업무 정보를 확인하고 있습니다',
                  'calendar_read': '일정을 조회하고 있습니다',
                  'calendar_direct_lookup': '일정을 조회하고 있습니다',
                  'notes_read': '메모를 조회하고 있습니다',
                  'notion': '노션 도구를 확인하고 있습니다',
                  'web_search': '웹에서 자료를 찾고 있습니다',
                  'web_extract': '웹 자료를 읽고 있습니다',
                  'read_file': '파일을 읽고 있습니다',
                  'doc_read': '문서를 읽고 있습니다',
                  'skills_list': '스킬 목록을 확인하고 있습니다',
                  'skill_view': '스킬을 읽고 있습니다'}
        label = labels.get(tool_name, '도구를 확인하고 있습니다')
        if tool_name == 'skill_view' and isinstance(args, dict):
            name = args.get('name') or args.get('skill')
            if isinstance(name, str) and re.fullmatch(r'[\w가-힣 .-]{1,60}', name):
                label = f'{name} 스킬을 읽고 있습니다'
        with self.lock:
            meta = self.sessions.get(session_id)
            if not meta or self.generations.get(session_id, {}).get('done'):
                return
            meta.setdefault('active_tools', {})[tool_call_id or tool_name] = label
            meta['activity'] = label
            name = tool_name if re.fullmatch(r'[\w.-]{1,80}', tool_name) else '도구'
            action = args.get('action', '') if isinstance(args, dict) else ''
            action = action if isinstance(action, str) and re.fullmatch(r'[a-zA-Z_]{1,32}', action) else ''
            detail = f'{name} · ' + (f'{action} · ' if action else '') + '실행 중'
            meta.setdefault('active_details', {})[tool_call_id or tool_name] = detail
            meta['execution'] = detail
            self._write_status(session_id, self.clock())

    def tool_finished(self, session_id='', tool_name='', tool_call_id='', **_):
        with self.lock:
            meta = self.sessions.get(session_id)
            if not meta or self.generations.get(session_id, {}).get('done'):
                return
            active = meta.setdefault('active_tools', {})
            active.pop(tool_call_id or tool_name, None)
            meta['activity'] = next(iter(active.values()), '조회 결과로 답변을 준비하고 있습니다')
            details = meta.setdefault('active_details', {})
            details.pop(tool_call_id or tool_name, None)
            meta['execution'] = next(iter(details.values()), '도구 실행 완료 · 다음 응답 준비 중')
            self._write_status(session_id, self.clock())

    def _path(self, session):
        return self.folder / (hashlib.sha256(session.encode()).hexdigest() + '.json')

    def _remove(self, session):
        self._path(session).unlink(missing_ok=True)

    def _prune(self, now):
        self.closed = {k: at for k, at in self.closed.items() if now - at < 3600}
        expired = [s for s, state in self.sessions.items() if now - state['touched'] > 3600]
        for session in expired:
            self.sessions.pop(session, None)
            self.generations.pop(session, None)
        if self.folder.exists():
            for file in self.folder.glob('*.json'):
                if now - file.stat().st_mtime > 120:
                    file.unlink(missing_ok=True)

    @staticmethod
    def visible(text):
        # Never reveal partially received internal tags or the unfinished button DSL.
        text = re.sub(r'<(think|thinking|analysis)>.*?(</\1>|$)', '', text, flags=re.S | re.I)
        text = re.sub(r'\[\[(버튼|체크리스트):.*', '', text, flags=re.S)
        for prefix in ('<think', '<analysis', '[[버튼:', '[[체크리스트:'):
            for n in range(1, len(prefix)):
                if text.endswith(prefix[:n]):
                    text = text[:-n]
                    break
        return text[:64000]

    def delta(self, session_id='', turn_id='', iteration=0, surface='', kind='', delta='', **_):
        if surface != 'slack' or kind != 'text' or not turn_id or not isinstance(delta, str):
            return
        with self.lock:
            meta = self.sessions.get(session_id)
            key = (session_id, turn_id, iteration)
            if not meta or key in self.closed:
                return
            now = self.clock()
            meta['touched'] = now
            state = self.generations.get(session_id)
            if not state or state['key'] != key:
                if state and state['key'][1] == turn_id and state['key'][2] > iteration:
                    return
                if meta.get('pending') and key != meta.get('previous_key'):
                    meta['status'] = 'applying'
                state = dict(key=key, text='', written=0.)
                self.generations[session_id] = state
            state['text'] = (state['text'] + delta)[:128000]
            if now - state['written'] >= .1:
                self._write(session_id, state, now, False)

    def end(self, session_id='', turn_id='', iteration=0, surface='', final_text='', finished=False, **_):
        if surface != 'slack' or not turn_id:
            return
        with self.lock:
            key = (session_id, turn_id, iteration)
            now = self.clock()
            if key in self.closed:
                return
            self.closed[key] = now
            state = self.generations.get(session_id)
            if session_id not in self.sessions:
                return
            if state and state['key'] != key:
                if state['key'][1] != turn_id or state['key'][2] > iteration:
                    return
            if not finished:
                if self.sessions[session_id].get('pending'):
                    self._write_status(session_id, now)
                    return
                self._remove(session_id)
                self.generations.pop(session_id, None)
                return
            meta = self.sessions[session_id]
            previous = meta.get('previous_key')
            if meta.get('status') == 'applying' or (previous and previous[1] == turn_id and previous[2] < iteration):
                self.sessions[session_id].pop('pending', None)
                self.sessions[session_id].pop('status', None)
            state = dict(key=key, text=final_text if isinstance(final_text, str) else '', written=0., done=True)
            self.generations[session_id] = state
            self._write(session_id, state, now, True)

    def _write(self, session, state, now, done):
        meta = self.sessions[session]
        text = self.visible(state['text'])
        status = meta.get('status')
        label = {'waiting': '추가 지시 반영 대기', 'redirecting': '추가 지시 반영 중',
                 'applying': '추가 지시 반영 중'}.get(status)
        if label and not text.strip():
            text = label
        elif not text.strip() and meta.get('activity'):
            text, status = meta['activity'], 'working'
        if not text.strip():
            self._remove(session)
            return
        payload = dict(id=hashlib.sha256(repr((session, meta['since'])).encode()).hexdigest(),
                       room=meta['room'], thread=meta['thread'], since=meta['since'],
                       updated=now, expires=now + (30 if done else 120), body=text, done=done, status=status, input_id=meta.get('pending'),
                       execution=(f"{meta.get('model', '모델')} · 답변 수신 중" if self.visible(state['text']).strip() else meta.get('execution')))
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(dir=self.folder, prefix='.', suffix='.tmp')
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(payload, output, ensure_ascii=False)
            os.replace(temporary, self._path(session))
            state['written'] = now
            state['done'] = done
        finally:
            Path(temporary).unlink(missing_ok=True)


def register(ctx, home):
    if ctx.get_config('chat_streaming', {}).get('enabled', True) is False:
        return
    writer = PreviewWriter(home)
    ctx.register_hook('pre_llm_call', writer.begin)
    ctx.register_hook('on_busy_input', writer.busy)
    ctx.register_hook('on_stream_start', writer.stream_started)
    ctx.register_hook('on_stream_delta', writer.delta)
    ctx.register_hook('on_stream_end', writer.end)
    ctx.register_hook('pre_tool_call', writer.tool_started)
    ctx.register_hook('post_tool_call', writer.tool_finished)
