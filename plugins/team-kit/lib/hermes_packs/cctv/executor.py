"""The reconnect the owner's button approves: the one place the pack reopens the remote session.

The Windows account is shared by several people, so reopening the session can take it over from someone who is
using it. The background check therefore never reconnects; it posts a proposal (`watch`), and only the owner's
approval makes the facility call `run` here. The facility registers it under `ACTION`; `verify` answers whether an
interrupted run left a session window behind."""
from . import screen, settings

ACTION = 'cctv.reconnect'
MANUAL_HINT = '원격 창을 직접 한 번 연결해 주세요.'
REASONS = {
    'prompt': 'Windows App가 확인 창(인증서 또는 로그인)을 띄웠어요. 자동으로 누르지 않고 창을 닫아 두었어요.',
    'no_app': 'Windows App을 시작하지 못했어요.',
    'no_device': 'Windows App 목록에서 저장된 원격 장치를 찾지 못했어요.',
    'timeout': '장치를 열었지만 제한 시간 안에 원격 화면 창이 뜨지 않았어요.',
    'error': '재연결 스크립트가 실패했어요.',
}


def cause(result):
    """One sentence a person can act on. The script's own text is only the tail of its error, never a path."""
    kind = str(result.get('state'))
    sentence = REASONS.get(kind, f'연결하지 못했어요({kind}).')
    detail = str(result.get('text') or '').strip().replace('\n', ' ')
    if kind != 'prompt' and detail:
        detail = detail.rsplit(': ', 1)[-1][:80]
        sentence += f' ({detail})'
    return sentence


def run(args, entry):
    """Reopen the saved device once. `connected` is applied; anything else is refused with the reason."""
    policy = settings.policy()
    if policy is None:
        return {'status': 'refused', 'message': '낙화 CCTV 확인이 꺼져 있어 연결하지 않았어요. ' + MANUAL_HINT}
    site = settings.site()
    result = screen.reconnect(site['rdp_device'], policy['reconnect_wait_seconds'],
                              policy['min_window_width'], policy['min_window_height'])
    if result.get('state') == 'connected':
        return {'status': 'applied', 'message': '원격 화면을 다시 연결했어요. 다음 확인 시각부터 화면을 읽어요.'}
    return {'status': 'refused', 'message': f'{cause(result)} {MANUAL_HINT}'}


def verify(entry):
    """True when the session window exists, i.e. an interrupted reconnect did connect."""
    policy = settings.policy()
    if policy is None:
        return False
    try:
        return screen.pick(screen.list_windows(), settings.site()['rdp_device'],
                           policy['min_window_width'], policy['min_window_height']) is not None
    except Exception:
        return False


def register(home, proposal_decisions):
    proposal_decisions.register_executor(home, ACTION, run, verify, manual_hint=MANUAL_HINT)
