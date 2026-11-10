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
def targets():
    """Catalog-derived targets; legacy service identifiers remain aliases."""
    table = json.loads((Path(__file__).resolve().parents[1] /
                        'hermes_packs/mac_apps/app_catalog.json').read_text())
    result = {}
    for bundle, item in table.items():
        kind = {'apple_events': 'apple_event', 'calendar': 'eventkit', 'contacts': 'contacts'}.get(item['permission'])
        if kind:
            target = (kind, bundle if kind == 'apple_event' else None, item.get('permission_label') or item.get('service') or bundle)
            result['app:' + bundle] = target
            if item.get('service'): result[item['service']] = target
    # Gmail is independent of Mail.app; this is the existing permission CLI alias only.
    if 'apple_mail' in result: result['mail_read'] = result['apple_mail']
    return result


class PermissionTargets:
    def __contains__(self, key):
        try: self[key]; return True
        except KeyError: return False
    def __getitem__(self, key):
        if key in targets(): return targets()[key]
        if isinstance(key, str) and key.startswith('app:'):
            bundle = key[4:]
            import re
            if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{1,250}', bundle):
                return ('apple_event', bundle, bundle)
        raise KeyError(key)
    def get(self, key, default=None):
        try: return self[key]
        except KeyError: return default


TARGETS = PermissionTargets()

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
    if service not in TARGETS or mode not in ('judge', 'request', 'judge_info', 'request_info', 'guide'):
        return dict(outcome='failed', reason='INVALID_ARGUMENTS')
    return run_worker(root, Path(__file__).resolve(), mode, service, timeout=timeout,
                      python=python, launchctl=launchctl, sleep=sleep, monotonic=monotonic)


def run_worker(root, worker, mode, service, *, timeout, python=None, launchctl=subprocess.run,
               sleep=time.sleep, monotonic=time.monotonic):
    """Internal fixed worker launcher; never receives model-supplied executables."""
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
                                 job_script(python, worker, mode, service, result_path)],
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
                        return answer if mode in ('execute', 'judge_info', 'request_info', 'guide') else dict(outcome=answer['outcome'], reason=answer.get('reason', 'OK' if answer['outcome'] != 'failed' else 'CHECK_FAILED'))
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
# Only this facility defines Settings destinations. The screen receives these values.
PANE_INFO = {
    'automation': ('x-apple.systempreferences:com.apple.preference.security?Privacy_Automation', '자동화'),
    'calendars': ('x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars', '캘린더'),
    'contacts': ('x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts', '연락처'),
    'full_disk_access': ('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles', '전체 디스크 접근 권한'),
    'internet_accounts': ('x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension', '인터넷 계정'),
}

SETTINGS_PANES = {kind:PANE_INFO[pane][0] for kind,pane in
                  [('apple_event','automation'),('eventkit','calendars'),('contacts','contacts')]}
SETTINGS_ENTRY = 'osascript'


def settings_guide(service):
    kind, _, name = TARGETS[service]
    where = {'apple_event': '자동화', 'eventkit': '캘린더', 'contacts': '연락처'}[kind]
    target = ' 아래의 "%s"' % name if kind == 'apple_event' else ''
    return dict(url=SETTINGS_PANES[kind],
                instruction='개인정보 보호 및 보안 > %s 목록에서 "%s"%s을(를) 켜 주세요.' % (where, SETTINGS_ENTRY, target))


def internet_accounts():
    return dict(kind='open_settings', pane='internet_accounts', url=PANE_INFO['internet_accounts'][0],
                hint='인터넷 계정에서 사용할 계정을 직접 추가한 뒤 이 화면으로 돌아와 다시 골라 주세요.',
                guide=[dict(n=1,text='인터넷 계정 설정을 여세요.',open_url=PANE_INFO['internet_accounts'][0]),
                       dict(n=2,text='사용할 계정을 직접 추가하세요.'),dict(n=3,text='이 화면으로 돌아와 계정을 직접 고르세요.')])



def mac_account_settings(app):
    if app.get('scope') in ('mail_accounts','calendars','note_folders') or app.get('permission')=='contacts':
        return internet_accounts()
    return None


def permission_next(pane, observation, reason):
    url, label = PANE_INFO[pane]
    target = observation.get('target') if isinstance(observation, dict) else None
    # Names are observed by the same worker that judged TCC; no guessed process/app labels.
    hint = ('개인정보 보호 및 보안 → '+label+'에서 '+target+' 항목을 허용해 주세요.' if target else
            '권한을 사용할 실행 주체를 확인하지 못했어요. 권한 창의 항목을 확인해 주세요.')
    guide=[dict(n=1,text=hint)]
    if pane=='automation':
        guide.extend([dict(n=2,text='토글을 눌러도 켜지지 않으면 시스템 설정을 종료한 뒤 다시 여세요.'),
                      dict(n=3,text='사진 연결이라면 사진 앱을 한 번 연 뒤 자동화 설정을 다시 확인하세요.'),
                      dict(n=4,text='허용한 뒤 이 화면으로 돌아와 켰어요 · 다시 확인을 누르세요.')])
    return dict(kind='open_settings' if reason in ('PERMISSION_DENIED','PERMISSION_REQUIRED') else 'permission_request',
                pane=pane, url=url, target=target, hint=hint, guide=guide)


def connection_step(root, service, permission, resume=None):
    def probe(ask=False, automation=False):
        mode='request_info' if ask else 'judge_info'
        if automation:
            return run_worker(root,Path(__file__).resolve(),mode,'automation:'+service[4:],
                              timeout=REQUEST_SECONDS if ask else JUDGE_SECONDS)
        return run_job(root,mode,service,timeout=REQUEST_SECONDS if ask else JUDGE_SECONDS)
    if permission=='full_disk_access':
        answer=run_job(root,'guide',service,timeout=JUDGE_SECONDS)
        return dict(ok=False,reason='PERMISSION_REQUIRED',next=permission_next('full_disk_access',answer,'PERMISSION_REQUIRED'))
    asked=False
    answer=probe()
    state,reason=outcome_to_state(answer['outcome']) if answer['outcome']!='failed' else ('unknown',answer['reason'])
    if state!='connected' and resume=='permission_request':
        answer=probe(ask=True);asked=True
        state,reason=outcome_to_state(answer['outcome']) if answer['outcome']!='failed' else ('unknown',answer['reason'])
    pane={'calendar':'calendars','contacts':'contacts'}.get(permission,'automation')
    if permission=='contacts' and state=='connected':
        answer=probe(ask=resume=='permission_request' and not asked,automation=True)
        state,reason=outcome_to_state(answer['outcome']) if answer['outcome']!='failed' else ('unknown',answer['reason'])
        pane='automation'
    following=permission_next(pane,answer,reason)
    return dict(ok=state=='connected',reason=reason,next=following)


def worker_target(service, bundle):
    """Observe the responsible wrapper in this worker's real ancestry and the installed app name."""
    subject=None;pid=os.getppid()
    for _ in range(12):
        if pid<=1:break
        try:
            row=subprocess.run(['/bin/ps','-p',str(pid),'-o','ppid=,comm='],capture_output=True,text=True,timeout=2,check=False)
            parent,executable=row.stdout.strip().split(None,1)
            if Path(executable).name=='osascript':subject=Path(executable).name;break
            pid=int(parent)
        except (ValueError,OSError,subprocess.SubprocessError):break
    if not bundle and service.startswith('app:'):bundle=service[4:]
    name=None
    if bundle:
        script="ObjC.import('AppKit');const u=$.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier(%s);u ? ObjC.unwrap($.NSFileManager.defaultManager.displayNameAtPath(u.path)) : '';"
        try:
            row=subprocess.run(['/usr/bin/osascript','-l','JavaScript','-e',script % json.dumps(bundle)],capture_output=True,text=True,timeout=5,check=False)
            if row.returncode==0:name=row.stdout.strip().removesuffix('.app') or None
        except (OSError,subprocess.SubprocessError):pass
    target=(subject+' → '+name if name else subject) if subject else None
    return dict(target=target)


def judge(root, service, **kwargs):
    """No dialog: the worker passes askUserIfNeeded=false."""
    answer = run_job(root, 'judge', service, timeout=JUDGE_SECONDS, **kwargs)
    return outcome_to_state(answer['outcome']) if answer['outcome'] != 'failed' else ('unknown', answer['reason'])


def judge_automation(root,bundle,*,ask=False,**kwargs):
    """Internal second permission for native packs that also use Apple Events."""
    import re
    if not isinstance(bundle,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{1,250}',bundle):
        return ('unknown','INVALID_ARGUMENTS')
    answer=run_worker(root,Path(__file__).resolve(),'request' if ask else 'judge','automation:'+bundle,
                      timeout=REQUEST_SECONDS if ask else JUDGE_SECONDS,**kwargs)
    return outcome_to_state(answer['outcome']) if answer['outcome']!='failed' else ('unknown',answer['reason'])


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


def _contacts_permission(ask, folder):
    binary = os.path.join(folder, 'contacts-permission')
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'contacts_permission.swift')
    built = subprocess.run(['/usr/bin/swiftc', source, '-o', binary], capture_output=True, timeout=60)
    if built.returncode: return 'failed'
    result = subprocess.run([binary, 'request' if ask else 'judge'], capture_output=True, text=True, timeout=45)
    value = result.stdout.strip()
    return value if value in ('granted', 'denied', 'not_determined') else 'failed'


def _launch_hidden(bundle):
    """AEDeterminePermission needs a running target; the gateway's own JXA launches it the same way."""
    subprocess.run(['/usr/bin/open', '-g', '-j', '-b', bundle], timeout=10, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def worker(mode, service, result_path):
    if service.startswith('automation:'):
        import re
        bundle=service[len('automation:'):]
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{1,250}',bundle):raise ValueError('INVALID_ARGUMENTS')
        kind='apple_event'
    else:kind,bundle,_=TARGETS[service]
    ask = mode in ('request', 'request_info')
    if mode == 'guide':
        outcome = 'not_determined'
    elif kind == 'contacts':
        outcome = _contacts_permission(ask, os.path.dirname(result_path))
    elif kind == 'eventkit':
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
        json.dump(dict(outcome=outcome, **(worker_target(service,bundle) if mode in ('judge_info','request_info','guide') else {})), stream)
    os.replace(temporary, result_path)


if __name__ == '__main__':
    worker(*sys.argv[1:4])
