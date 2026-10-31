"""Fixed-code, redacted local error recording for linked-work operations."""
from pathlib import Path
import json, traceback, logging
from logging.handlers import RotatingFileHandler

CONTENT_WARNINGS = {  # work_sync.Engine warning lines -> fixed reason codes for 진단담당
    '본문·할 일 반영 확인이 필요해 멈췄어요': 'work_content_write_uncertain',
    '앞선 본문·할 일 반영이 불명확해': 'work_content_pending_uncertain',
    '두 원본이 서로 다르게 바뀌었어요': 'work_content_conflict',
    '노션 다음 마감 반영 확인이 필요해': 'work_content_write_uncertain',
    '노션 할 일의 마감 근거를 확인해야': 'work_content_deadline_unresolved',
}


def content_warning_code(line):
    return next((code for text, code in CONTENT_WARNINGS.items() if text in line), None)


def log_work_error(home, cid, reason, exc, *, frames=None, exception_type=None):
    # Frames only: format_exception would expose messages, source lines and chained data.
    frames = frames if frames is not None else [{'file': Path(frame.filename).name, 'line': frame.lineno, 'function': frame.name}
              for frame in traceback.extract_tb(exc.__traceback__)]
    record = json.dumps({'cid': cid, 'reason': reason, 'exception': exception_type or type(exc).__name__,
                         'traceback': frames}, ensure_ascii=False)
    try:
        path = home / 'logs/notion-completion-sync.log'
        path.parent.mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler(path, maxBytes=1024 * 1024, backupCount=3, encoding='utf-8')
        try:
            handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
            handler.emit(logging.LogRecord('work-sync', logging.ERROR, '', 0, record, (), None))
        finally:
            handler.close()
    except OSError:
        # Logging must not stop other work or send sensitive data to cron stdout.
        pass
