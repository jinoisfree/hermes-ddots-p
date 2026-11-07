"""Mac permission judgement/request for the gateway's own TCC subject.

The gateway runs as launchd -> /usr/bin/osascript wrapper -> Python, so its
Mail/Notes/Calendar grants belong to that wrapper's process tree, not to the
caller. A one-off launchd job with the same wrapper shape runs this file as the
worker and is removed afterwards (docs/changes/AGENT-CONNECTIONS-CHECK-20261107).
The worker part is stdlib-only because it runs by path inside that job. App
contents (mail, notes, events) are never read.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import time
import uuid

JUDGE_SECONDS = 15
REQUEST_SECONDS = 120
LABEL_PREFIX = 'ai.hermes.connections-permission.'

# service -> (mechanism, bundle id, name shown in System Settings)
TARGETS = {'mail_read': ('apple_event', 'com.apple.mail', 'Mail'),
           'notes_read': ('apple_event', 'com.apple.Notes', '메모'),
           'calendar_read': ('eventkit', None, '캘린더')}

# AEDeterminePermissionToAutomateTarget results and EKAuthorizationStatus values.
APPLE_EVENT_STATUS = {0: 'granted', -1743: 'denied', -1744: 'not_determined', -600: 'target_unavailable'}
EVENTKIT_STATUS = {0: 'not_determined', 1: 'denied', 2: 'denied', 3: 'granted', 4: 'denied'}
OUTCOME_STATE = {'granted': ('connected', 'PERMISSION_GRANTED'),
                 'denied': ('not_connected', 'PERMISSION_DENIED'),
                 'not_determined': ('unknown', 'NOT_DETERMINED'),
                 'target_unavailable': ('unknown', 'TARGET_UNAVAILABLE')}


def outcome_to_state(outcome):
    return OUTCOME_STATE.get(outcome, ('unknown', 'CHECK_FAILED'))


def job_script(python, worker, mode, service, result):
    """Same wrapper shape as ai.hermes.gateway.plist; exit code follows the child."""
    command = 'exec ' + ' '.join(shlex.quote(str(part)) for part in
                                 (python, '-B', worker, mode, service, result)) + ' >/dev/null 2>&1'
    return ('ObjC.import("stdlib"); const status=$.system(' + json.dumps(command) + '); '
            'const signal=status & 127; $.exit(status === -1 ? 1 : signal === 0 ? (status >> 8) & 255 : 128 + signal);')


def run_job(root, mode, service, *, timeout, python=None, launchctl=subprocess.run,
            sleep=time.sleep, monotonic=time.monotonic):
    """Run the worker as a one-off launchd job; the job and its files never outlive this call."""
    if service not in TARGETS or mode not in ('judge', 'request'):
        return dict(outcome='failed', reason='INVALID_ARGUMENTS')
    python = python or sys.executable
    label = LABEL_PREFIX + uuid.uuid4().hex[:12]
    folder = Path(root) / 'state/connections/jobs' / label
    domain = 'gui/%d' % os.getuid()
    try:
        folder.mkdir(parents=True, mode=0o700)
        result_path = folder / 'result.json'
        plist = folder / 'job.plist'
        plist.write_bytes(plistlib.dumps({
            'Label': label,
            'ProgramArguments': ['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                                 job_script(python, Path(__file__).resolve(), mode, service, result_path)],
            'WorkingDirectory': str(root),
            'LimitLoadToSessionType': ['Aqua', 'Background'],
            'RunAtLoad': True}))
        os.chmod(plist, 0o600)
        loaded = launchctl(['launchctl', 'bootstrap', domain, str(plist)], capture_output=True, text=True,
                           timeout=10, check=False)
        if loaded.returncode != 0:
            return dict(outcome='failed', reason='LAUNCH_FAILED')
        try:
            deadline = monotonic() + timeout
            while monotonic() < deadline:
                if result_path.is_file():
                    try:
                        answer = json.loads(result_path.read_text(encoding='utf-8'))
                    except ValueError:
                        answer = None
                    if isinstance(answer, dict) and isinstance(answer.get('outcome'), str):
                        return dict(outcome=answer['outcome'], reason=answer.get('reason', 'OK' if answer['outcome'] != 'failed' else 'CHECK_FAILED'))
                sleep(0.2)
            return dict(outcome='failed', reason='TIMEOUT')
        finally:
            launchctl(['launchctl', 'bootout', domain + '/' + label], capture_output=True, text=True,
                      timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return dict(outcome='failed', reason='LAUNCH_FAILED')
    finally:
        shutil.rmtree(folder, ignore_errors=True)


# System Settings pane per mechanism and the entry the owner switches on. "osascript" is the name both panes
# show for the gateway's wrapper (Automation list and Calendars list, confirmed on screen 2026-11-07, impl-report V-2).
SETTINGS_PANES = {'apple_event': 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation',
                  'eventkit': 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'}
SETTINGS_ENTRY = 'osascript'


def settings_guide(service):
    kind, _, name = TARGETS[service]
    where = '자동화' if kind == 'apple_event' else '캘린더'
    target = ' 아래의 "%s"' % name if kind == 'apple_event' else ''
    return dict(url=SETTINGS_PANES[kind],
                instruction='개인정보 보호 및 보안 > %s 목록에서 "%s"%s을(를) 켜 주세요.' % (where, SETTINGS_ENTRY, target))


def judge(root, service, **kwargs):
    """No dialog: the worker passes askUserIfNeeded=false."""
    answer = run_job(root, 'judge', service, timeout=JUDGE_SECONDS, **kwargs)
    return outcome_to_state(answer['outcome']) if answer['outcome'] != 'failed' else ('unknown', answer['reason'])


def request(root, service, **kwargs):
    """Show the OS permission dialog on this Mac's screen, as the gateway's subject."""
    answer = run_job(root, 'request', service, timeout=REQUEST_SECONDS, **kwargs)
    return outcome_to_state(answer['outcome']) if answer['outcome'] != 'failed' else ('unknown', answer['reason'])


# ---- worker: runs inside the one-off job ----------------------------------

def _fourcc(text):
    return int.from_bytes(text.encode('ascii'), 'big')


def _apple_event_status(bundle, ask):
    import ctypes

    class AEDesc(ctypes.Structure):
        _fields_ = [('descriptorType', ctypes.c_uint32), ('dataHandle', ctypes.c_void_p)]

    lib = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    lib.AECreateDesc.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_long, ctypes.POINTER(AEDesc)]
    lib.AECreateDesc.restype = ctypes.c_int32
    lib.AEDisposeDesc.argtypes = [ctypes.POINTER(AEDesc)]
    lib.AEDeterminePermissionToAutomateTarget.argtypes = [
        ctypes.POINTER(AEDesc), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_ubyte]
    lib.AEDeterminePermissionToAutomateTarget.restype = ctypes.c_int32
    target = AEDesc()
    lib.AECreateDesc(_fourcc('bund'), bundle.encode('ascii'), len(bundle), ctypes.byref(target))
    try:
        return lib.AEDeterminePermissionToAutomateTarget(
            ctypes.byref(target), _fourcc('****'), _fourcc('****'), 1 if ask else 0)
    finally:
        lib.AEDisposeDesc(ctypes.byref(target))


def _eventkit_status():
    import ctypes
    import ctypes.util
    ctypes.CDLL('/System/Library/Frameworks/EventKit.framework/EventKit')
    objc = ctypes.CDLL(ctypes.util.find_library('objc'))
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    send = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong)(('objc_msgSend', objc))
    return send(objc.objc_getClass(b'EKEventStore'),
                objc.sel_registerName(b'authorizationStatusForEntityType:'), 0)  # EKEntityTypeEvent


def _eventkit_request(folder):
    """Compile and run the one-call helper next to the result file; it dies with the job folder."""
    binary = os.path.join(folder, 'eventkit-permission')
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'eventkit_permission.swift')
    compiled = subprocess.run(['/usr/bin/swiftc', '-parse-as-library', source, '-o', binary],
                              capture_output=True, text=True, timeout=60, check=False)
    if compiled.returncode != 0:
        return 'failed'
    answer = subprocess.run([binary], capture_output=True, text=True, timeout=REQUEST_SECONDS - 65, check=False)
    return answer.stdout.strip() if answer.stdout.strip() in ('granted', 'denied') else 'failed'


def _launch_hidden(bundle):
    """AEDeterminePermission needs a running target; the gateway's own JXA launches it the same way."""
    subprocess.run(['/usr/bin/open', '-g', '-j', '-b', bundle], timeout=10, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def worker(mode, service, result_path):
    kind, bundle, _ = TARGETS[service]
    ask = mode == 'request'
    if kind == 'eventkit':
        status = _eventkit_status()
        outcome = EVENTKIT_STATUS.get(status, 'failed')
        if ask and outcome == 'not_determined':
            outcome = _eventkit_request(os.path.dirname(result_path))
    else:
        status = _apple_event_status(bundle, ask)
        if status == -600:
            _launch_hidden(bundle)
            for _ in range(25):
                time.sleep(0.4)
                status = _apple_event_status(bundle, ask)
                if status != -600:
                    break
        outcome = APPLE_EVENT_STATUS.get(status, 'failed')
    temporary = result_path + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as stream:
        json.dump(dict(outcome=outcome), stream)
    os.replace(temporary, result_path)


if __name__ == '__main__':
    worker(*sys.argv[1:4])
