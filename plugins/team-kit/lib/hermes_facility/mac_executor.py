"""Bounded osascript execution under the gateway's launchd/osascript principal."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MAX_RESULT = 1024 * 1024


def execute(root, script, *, timeout=30, language='JavaScript'):
    from hermes_facility.config_assembly import atomic_write
    from hermes_facility.mac_permission import run_worker
    folder = Path(root) / 'state/connections/jobs'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='script-', dir=folder) as temporary:
        payload = Path(temporary) / 'request.json'
        atomic_write(payload, json.dumps(dict(script=script, language=language)).encode())
        answer = run_worker(root, Path(__file__).resolve(), 'execute', str(payload), timeout=timeout + 10)
    if answer.get('outcome') != 'done': raise ValueError(answer.get('reason', 'APP_READ_FAILED'))
    return answer.get('value')


def worker(payload):
    request = json.loads(Path(payload).read_bytes())
    if request['language'] not in ('JavaScript', 'AppleScript'): raise ValueError('LANGUAGE_INVALID')
    # The caller is a fixed compiler/adapter, never a model-supplied script tool.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        proc = subprocess.run(['/usr/bin/osascript', '-l', request['language'], '-e', request['script']],
                              stdout=output, stderr=errors, timeout=30, check=False)
        output.seek(0); data = output.read(MAX_RESULT + 1)
    if proc.returncode: return dict(outcome='failed', reason='APP_READ_FAILED')
    if len(data) > MAX_RESULT: return dict(outcome='failed', reason='RESULT_TOO_LARGE')
    text = data.decode('utf-8').strip()
    try: value = json.loads(text)
    except ValueError: value = text
    return dict(outcome='done', reason='OK', value=value)


if __name__ == '__main__':
    _, mode, payload, result = sys.argv
    try: answer = worker(payload) if mode == 'execute' else dict(outcome='failed', reason='INVALID_ARGUMENTS')
    except Exception: answer = dict(outcome='failed', reason='APP_READ_FAILED')
    fd = os.open(result, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream: json.dump(answer, stream)
