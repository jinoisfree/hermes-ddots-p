"""Korean setup and code updates that only supplement plugin opt-ins in owner config."""
from __future__ import annotations
import argparse
from copy import deepcopy
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request


class SetupError(ValueError):
    """A static, user-facing setup explanation without credential values."""


def runtime_python(home):
    """Ask the installed core to select its environment; never install dependencies here."""
    core = home / 'hermes-agent'
    environment = {**os.environ, 'HERMES_HOME': str(home), 'HERMES_DISABLE_LAZY_INSTALLS': '1',
                   'PYTHONDONTWRITEBYTECODE': '1'}
    if (core / 'pm/environments.py').is_file():
        try:
            result = subprocess.run([sys.executable, '-I', '-c',
                "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);"
                "from pm.environments import project_python;print(project_python(Path(sys.argv[1])))", str(core)],
                capture_output=True, text=True, env=environment, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            raise SetupError('Hermes의 관리 Python 환경을 확인하지 못했습니다. 공식 설치를 먼저 마치세요.') from None
        if result.returncode:
            raise SetupError('Hermes의 관리 Python 환경을 확인하지 못했습니다. 공식 설치를 먼저 마치세요.')
        python = Path(result.stdout.strip())
    else:
        python = core / 'venv/bin/python'
    if not python.is_file() or not os.access(python, os.X_OK):
        raise SetupError('실행할 Hermes Python이 없습니다. bash install.sh --prepare-runtime --home <홈>으로 먼저 준비하세요.')
    return python


def check_runtime(home):
    python = runtime_python(home)
    launcher = home / 'hermes-agent/.hermes/bin/hermes'
    if not launcher.is_file():
        launcher = Path.home() / '.local/bin/hermes'
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        raise SetupError('Hermes CLI가 없습니다. 공식 설치기의 명령 등록을 먼저 마치세요.')
    environment = {**os.environ, 'HERMES_HOME': str(home), 'HERMES_DISABLE_LAZY_INSTALLS': '1',
                   'PYTHONDONTWRITEBYTECODE': '1'}
    try:
        dependencies = subprocess.run([str(python), '-I', '-c', 'import ruamel.yaml'],
            capture_output=True, env=environment, timeout=30)
        command = subprocess.run([str(launcher), '--version'],
            capture_output=True, env=environment, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupError('Hermes 실행 기반 점검에 실패했습니다. Python과 CLI 설치를 확인하세요.') from None
    if dependencies.returncode or command.returncode:
        raise SetupError('Hermes Python 의존성 또는 CLI 실행이 실패했습니다. 공식 설치를 먼저 마치세요.')
    print('Hermes 본체·Python·CLI 실행 점검 통과. 모델·Slack 연결과 실제 응답은 별도 확인이 필요합니다.')
    return 0


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def mapping(path, home):
    if not path.exists(): return {}
    text = path.read_text()
    try: value = json.loads(text)
    except ValueError:
        python = runtime_python(home)
        result = subprocess.run([str(python), '-c',
            "import json,sys;from ruamel.yaml import YAML;print(json.dumps(YAML(typ='safe').load(open(sys.argv[1]))))", str(path)],
            capture_output=True, text=True, env={**os.environ, 'HERMES_HOME': str(home),
                'HERMES_DISABLE_LAZY_INSTALLS': '1', 'PYTHONDONTWRITEBYTECODE': '1'}, timeout=30)
        if result.returncode: raise SetupError('기존 YAML 설정을 읽지 못했습니다.')
        value = json.loads(result.stdout)
    if not isinstance(value, dict): raise SetupError('설정은 객체 형식이어야 합니다.')
    return value


def missing_merge(current, defaults):
    result = deepcopy(current)
    for key, value in defaults.items():
        if key not in result: result[key] = deepcopy(value)
        elif isinstance(result[key], dict) and isinstance(value, dict): result[key] = missing_merge(result[key], value)
    return result


def plugin_activation(config):
    section = config.get('plugins', {})
    if not isinstance(section, dict): raise SetupError('plugins 설정은 객체 형식이어야 합니다.')
    enabled = section.get('enabled', [])
    disabled = section.get('disabled', [])
    if any(not isinstance(values, list) or any(not isinstance(name, str) for name in values)
           for values in (enabled, disabled)):
        raise SetupError('plugins.enabled와 plugins.disabled는 플러그인 이름 목록이어야 합니다.')
    return enabled, disabled


def enable_managed_plugins(config, plugins, slug):
    enabled, disabled = plugin_activation(config)
    enabled = list(enabled)
    for plugin in plugins:
        if plugin in disabled:
            print(f'{slug}: {plugin}은 plugins.disabled에 있어 활성 목록에 추가하지 않았습니다. 사용하려면 disabled에서 해제하세요.')
        elif plugin not in enabled:
            enabled.append(plugin)
    config.setdefault('plugins', {})['enabled'] = enabled


def safe_path(home, relative):
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts: raise SetupError('설치 경로가 올바르지 않습니다.')
    path = home / relative
    for parent in path.parents:
        if parent == home: break
        if parent.is_symlink(): raise SetupError('설치 경로의 상위 링크를 확인하세요.')
    return path


def signature(path):
    if path.is_symlink(): return {'link': os.readlink(path)}
    if path.is_file(): return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return None


def validate_distribution(root):
    path = root / '.starter-generated.json'
    if not path.is_file(): raise SetupError('배포 파일 목록이 없습니다. 생성된 공개판을 사용하세요.')
    for name, expected in json.loads(path.read_text()).items():
        source = safe_path(root, name)
        if source.is_symlink() or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise SetupError('배포 파일이 바뀌었거나 빠졌습니다. 확인된 공개판을 다시 받으세요.')


def code_payload(root, plugins):
    files = {}
    for name in sorted(plugins):
        source = root / 'plugins' / name
        if not source.is_dir(): raise SetupError('배포 코드가 빠졌습니다.')
        for path in sorted(source.rglob('*')):
            if path.is_symlink(): raise SetupError('배포 원본에 예상하지 못한 링크가 있습니다.')
            if path.is_file(): files['plugin-store/' + name + '/' + path.relative_to(source).as_posix()] = path.read_bytes()
    links = {}
    metadata = root / 'plugin-links.json'
    if metadata.exists():
        manifest = json.loads(metadata.read_text())
        if manifest.get('version') != 1: raise SetupError('배포 링크 버전을 확인하세요.')
        for name, target in manifest['links'].items():
            parts = Path(name).parts
            if len(parts) < 3 or parts[0] != 'plugins' or parts[1] not in plugins: continue
            relative = Path('plugin-store', *parts[1:])
            resolved = Path(os.path.normpath(str(relative.parent / target)))
            if not resolved.parts or resolved.parts[0] != 'plugin-store' or resolved.parts[1] not in plugins:
                raise SetupError('배포 링크가 코드 창고 밖을 가리킵니다.')
            if not any(p == str(resolved) or p.startswith(str(resolved) + '/') for p in files):
                raise SetupError('배포 링크의 코드가 빠졌습니다.')
            links[str(relative)] = target
    return files, links


def ensure_stopped(home):
    state = home / 'gateway_state.json'
    if not state.exists(): return
    data = json.loads(state.read_text())
    pid = data.get('pid')
    if pid:
        try: os.kill(int(pid), 0)
        except ProcessLookupError: return
        raise SetupError('업데이트 전에 Hermes 게이트웨이를 중지하세요. 대화와 예약이 끝난 뒤 다시 실행하세요.')


def apply_files(home, files, links, *, managed, previous, update=False, dry_run=False):
    """Preflight every path before writing. Update only previously managed code."""
    obsolete = set(previous) - set(managed) if update else set()
    for name in set(files) | set(links) | obsolete:
        path = safe_path(home, name)
        before = signature(path)
        if path.exists() and not path.is_file() and not path.is_symlink():
            raise SetupError('설치 대상에 기존 폴더가 있습니다. 내용을 보존하고 중단합니다.')
        if name in managed or name in obsolete:
            if before and (name not in previous or before != previous[name]):
                desired = {'link': links[name]} if name in links else {'sha256': hashlib.sha256(files[name]).hexdigest()} if name in files else None
                if before != desired: raise SetupError('직접 고친 플러그인 코드가 있습니다. 변경을 보존한 뒤 업데이트하세요.')
        elif path.is_symlink() and (name not in links or before != {'link': links[name]}):
            raise SetupError('사용자 파일의 링크를 덮어쓰지 않습니다.')
    if not dry_run and (update or any(signature(home / name) and signature(home / name) != managed[name] for name in managed)):
        ensure_stopped(home)
    if update:
        # Unknown files inside managed plugin trees may be user work: never remove them.
        roots = {Path(name).parts[1] for name in managed}
        for plugin in roots:
            for path in (home / 'plugin-store' / plugin).rglob('*'):
                if '__pycache__' in path.parts or path.suffix == '.pyc': continue
                if path.is_file() or path.is_symlink():
                    name = str(path.relative_to(home))
                    if name not in previous and name not in managed: raise SetupError('플러그인 창고에 별도 파일이 있어 보존을 위해 중단합니다.')
    if dry_run:
        print(f'미리 보기: 파일 {len(files)}개, 연결 {len(links)}개. 실제 파일·Slack은 변경하지 않습니다.')
        return
    saved = {}
    try:
        for name in sorted(set(files) | set(links) | obsolete, key=lambda n: n in links):
            path = safe_path(home, name)
            desired = {'link': links[name]} if name in links else {'sha256': hashlib.sha256(files[name]).hexdigest()} if name in files else None
            if signature(path) == desired: continue
            saved[name] = (os.readlink(path), None, None) if path.is_symlink() else (None, path.read_bytes(), path.stat().st_mode & 0o777) if path.is_file() else None
            if path.is_symlink(): path.unlink()
            path.parent.mkdir(parents=True, exist_ok=True)
            if name in links:
                if path.exists(): path.unlink()
                path.symlink_to(links[name])
            elif name in files:
                fd, temporary = tempfile.mkstemp(prefix='.install-', dir=path.parent)
                try:
                    with os.fdopen(fd, 'wb') as stream: stream.write(files[name]); stream.flush(); os.fsync(stream.fileno())
                    os.chmod(temporary, 0o755 if path.suffix == ".sh" else 0o644 if name in managed else 0o600)
                    os.replace(temporary, path)
                finally:
                    if os.path.exists(temporary): os.unlink(temporary)
            elif path.exists(): path.unlink()
    except BaseException:
        for name, original in reversed(list(saved.items())):
            path = home / name
            if path.exists() or path.is_symlink(): path.unlink()
            if original is not None:
                target, body, mode = original
                if target is not None: path.symlink_to(target)
                else: path.write_bytes(body); path.chmod(mode)
        raise


def slack_call(token, method, body):
    request = urllib.request.Request('https://slack.com/api/' + method,
        data=json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=20) as response: result = json.load(response)
    if not result.get('ok'): raise SetupError('Slack 연결에 실패했습니다. 앱 권한과 워크스페이스를 확인하세요.')
    return result


def general_channel(token, call=slack_call):
    cursor = ''; found = {}
    for _ in range(100):
        result = call(token, 'conversations.list', {'types': 'public_channel', 'exclude_archived': True, 'limit': 200, 'cursor': cursor})
        for row in result.get('channels', []):
            if row.get('is_general') is True and not row.get('is_archived'): found[row['id']] = row
        cursor = (result.get('response_metadata') or {}).get('next_cursor', '')
        if not cursor: break
    else: raise SetupError('Slack 채널 목록을 끝까지 읽지 못했습니다.')
    if len(found) != 1: raise SetupError('기본 채널(is_general)을 하나로 확인하지 못했습니다.')
    return next(iter(found.values()))


def connect_slack(home, receipt, *, call=slack_call, secret=getpass.getpass, prompt=input):
    print('선택한 직원의 Slack 앱을 같은 워크스페이스 기본 채널에 연결합니다. 메시지는 보내지 않습니다.')
    prepared = []; team_id = None; channel = None
    # Validate all local destinations before reading credentials or joining channels.
    for relative in receipt['destinations'].values():
        for name in ('.env', 'config.yaml'):
            path = safe_path(home, Path(relative) / name)
            if path.is_symlink(): raise SetupError('자격·설정 파일의 링크를 사용할 수 없습니다.')
    if safe_path(home, 'owner/vault.yaml').is_symlink(): raise SetupError('금고 링크를 사용할 수 없습니다.')
    owner = prompt('허용할 본인의 Slack 사용자 ID: ').strip()
    if not re.fullmatch(r'[UW][A-Z0-9]+', owner): raise SetupError('Slack 사용자 ID를 확인하세요.')
    for slug in receipt['agents']:
        destination = home / receipt['destinations'][slug]
        env_path = destination / '.env'
        old = env_path.read_text() if env_path.exists() else ''
        values = dict(line.split('=', 1) for line in old.splitlines() if '=' in line and not line.startswith('#'))
        token = values.get('SLACK_BOT_TOKEN') or secret(slug + ' Bot User OAuth Token: ').strip()
        app = values.get('SLACK_APP_TOKEN') or secret(slug + ' App-Level Token: ').strip()
        if not token.startswith('xoxb-') or not app.startswith('xapp-') or any('\n' in v for v in (token, app)):
            raise SetupError('Slack 토큰 종류를 확인하세요.')
        identity = call(token, 'auth.test', {})
        if team_id and team_id != identity.get('team_id'): raise SetupError('직원 앱들이 서로 다른 워크스페이스에 있습니다.')
        team_id = identity['team_id']
        if channel is None: channel = general_channel(token, call)
        config = mapping(destination / 'config.yaml', home)
        prepared.append((slug, destination, old, values, token, app, config))
    if prompt('이 직원들을 확인된 기본 채널에 참여시키고 토큰을 이 맥에 저장할까요? [예/아니오]: ').strip() != '예':
        print('연결을 보류했습니다. 설치 파일은 유지합니다.'); return
    for slug, destination, old, values, token, app, config in prepared:
        call(token, 'conversations.join', {'channel': channel['id']})
        additions = {'SLACK_BOT_TOKEN': token, 'SLACK_APP_TOKEN': app, 'SLACK_ALLOWED_USERS': owner,
                     'SLACK_HOME_CHANNEL': channel['id'], 'HERMES_ROOT': str(home),
                     'HERMES_REPLY_BUTTONS': str(home / 'shared/reply-buttons.json')}
        text = old.rstrip() + '\n' + ''.join(key + '=' + value + '\n' for key, value in additions.items() if key not in values)
        env_path = destination / '.env'
        if env_path.is_symlink(): raise SetupError('토큰 파일 링크를 사용할 수 없습니다.')
        fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as stream: stream.write(text)
        env_path.chmod(0o600)
        slack = config.setdefault('platforms', {}).setdefault('slack', {})
        slack.setdefault('home_channel', {'platform': 'slack', 'chat_id': channel['id'], 'name': channel.get('name', '기본 채널'), 'user_id': owner, 'scope_id': team_id})
        slack.setdefault('free_response_channels', [channel['id']])
        slack.setdefault('allowed_users', [owner])
        (destination / 'config.yaml').write_bytes(encoded(config))
        print(slug + ': 기본 채널 참여·로컬 자격 저장 완료')
    vault_path = home / 'owner/vault.yaml';vault = mapping(vault_path, home)
    channels = vault.setdefault('channels', {})
    for key in ('home', 'reports', 'learning'):
        if not channels.get(key): channels[key] = channel['id']
    vault_path.write_bytes(encoded(vault))


def modern_main(root, argv=None):
    root = Path(root)
    parser = argparse.ArgumentParser(description='직원을 고용하고 필요한 도구 팩을 연결합니다. 기존 기억·계정·장부는 보존합니다.')
    parser.add_argument('--list', action='store_true');parser.add_argument('--agents');parser.add_argument('--default')
    parser.add_argument('--packs', default=None);parser.add_argument('--home', type=Path, default=Path(os.environ.get('HERMES_HOME', '~/.hermes')).expanduser())
    parser.add_argument('--label-prefix', default='com.example.hermes');parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--check', action='store_true');parser.add_argument('--update', action='store_true');parser.add_argument('--connect-slack', action='store_true')
    parser.add_argument('--check-runtime', action='store_true', help='본체·Python·CLI를 설치 없이 점검합니다.')
    args = parser.parse_args(argv)
    if args.home.is_symlink(): raise SetupError('설치 홈 자체의 링크는 사용할 수 없습니다.')
    home = args.home.expanduser().resolve()
    if home == root or root in home.parents: raise SetupError('배포 폴더 밖에 설치하세요.')
    if args.check_runtime:
        return check_runtime(home)
    settings = json.loads((root / 'installation.json').read_text());available = settings['roles']
    if args.list:
        for i, (slug, row) in enumerate(available.items(), 1):print(f"{i}. {row['name']} ({slug}) — {row['description']}")
        print('도구 팩: ' + ', '.join(settings['packs']));return 0
    records = sorted((home / '.starter/receipts').glob('*.json'))
    previous = json.loads(records[-1].read_text()) if records else {'agents': [], 'default': None, 'destinations': {}, 'managed': {}}
    if records and previous.get('version') != 2:
        raise SetupError('이전 구조의 설치 기록입니다. 기존 플러그인과 설정을 보존하는 전환 점검이 먼저 필요합니다. 파일은 변경하지 않았습니다.')
    plugins = ('quiet-logs', 'team-kit', 'team-delegation')
    if args.check:
        if not previous['agents']: raise SetupError('설치 기록이 없습니다.')
        checks = {**previous.get('managed', {}), **{n: {'link': v} for n, v in previous.get('connections', {}).items()}}
        issues = [name for name, expected in checks.items() if signature(home / name) != expected]
        print(json.dumps({'scope': 'managed-code', 'checked': len(checks), 'differences': issues}, ensure_ascii=False))
        activation_issues = []
        for slug in previous['agents']:
            config_path = safe_path(home, Path(previous['destinations'][slug]) / 'config.yaml')
            enabled, disabled = plugin_activation(mapping(config_path, home))
            for plugin in plugins:
                if plugin in disabled:
                    activation_issues.append({'agent': slug, 'plugin': plugin, 'reason': 'disabled',
                        'remedy': '사용하려면 config의 plugins.disabled에서 해제한 뒤 --update를 실행하세요.'})
                elif plugin not in enabled:
                    activation_issues.append({'agent': slug, 'plugin': plugin, 'reason': 'missing-enabled',
                        'remedy': '--update를 실행해 plugins.enabled를 보충하세요.'})
        print(json.dumps({'scope': 'plugin-activation', 'differences': activation_issues}, ensure_ascii=False))
        return int(bool(issues or activation_issues))
    if args.update:
        if not previous['agents']: raise SetupError('이 설치 도우미의 기존 설치 기록이 없습니다.')
        selected = previous['agents'];default = previous['default'];destinations = previous['destinations'];packs = previous.get('packs', [])
    else:
        if not args.agents:
            if not sys.stdin.isatty(): parser.error('비대화형 실행에는 --agents가 필요합니다.')
            for i, (slug, row) in enumerate(available.items(), 1):print(f"{i}. {row['name']} — {row['description']}")
            try: args.agents = ','.join(list(available)[int(n.strip())-1] for n in input('고용할 직원 번호(쉼표 구분): ').split(',') if int(n.strip()) > 0)
            except (ValueError, IndexError): raise SetupError('직원 번호를 다시 확인하세요.')
        selected = list(dict.fromkeys(previous['agents'] + [v.strip() for v in args.agents.split(',')]))
        if not selected or any(name not in available for name in selected): raise SetupError('직원 선택을 확인하세요.')
        default = args.default or previous['default'] or ('work-assistant' if 'work-assistant' in selected else selected[0])
        if default not in selected or previous['default'] and default != previous['default']: raise SetupError('기존 기본 직원은 이동하지 않습니다.')
        destinations = {name: '.' if name == default else 'profiles/' + name for name in selected}
        if args.packs is None and sys.stdin.isatty():
            print('도구 팩: ' + ', '.join(settings['packs']))
            args.packs = input('연결할 팩(쉼표 구분, Enter=files-docs): ').strip() or 'files-docs'
        packs = list(dict.fromkeys(previous.get('packs', []) + [v.strip() for v in (args.packs if args.packs is not None else 'files-docs').split(',') if v.strip()]))
        if any(name not in settings['packs'] for name in packs): raise SetupError('도구 팩 이름을 확인하세요.')
        while True:
            expanded = set(packs)
            for name in packs: expanded.update(settings['packs'][name].get('requires', []))
            if expanded == set(packs): break
            packs = sorted(expanded)
        if sys.platform != 'darwin':
            removed = [name for name in packs if settings['packs'][name].get('mac_only')]
            while True:
                dependent = [name for name in packs if name not in removed and set(settings['packs'][name].get('requires', [])) & set(removed)]
                if not dependent: break
                removed.extend(dependent)
            packs = [name for name in packs if name not in removed]
            if removed: print('이 운영체제에서 사용할 수 없어 제외: ' + ', '.join(removed))
    validate_distribution(root)
    files, links = code_payload(root, plugins)
    managed = {name: {'sha256': hashlib.sha256(body).hexdigest()} for name, body in files.items()}
    managed.update({name: {'link': target} for name, target in links.items()})
    if not args.update:
        profiles = {slug: 'default' if slug == default else slug for slug in selected}
        fallback = profiles.get('work-assistant', profiles[default])
        router = {'enabled': True, 'claim_database_path': str(home / 'shared/common-router-claims.sqlite3'),
                  'profiles': {'fallback': fallback, **{slug: profile for slug, profile in profiles.items()}}, 'aliases': {}}
        root_model = mapping(home / 'config.yaml', home).get('model')
        for slug in selected:
            relative = Path(destinations[slug]);destination = home / relative
            config = json.loads((root / 'agents' / slug / 'config.yaml').read_text())
            if root_model: config['model'] = root_model
            config['agent']['disabled_toolsets'] = ['delegation']
            config['gateway'] = {'multiplex_profiles': True}
            config['memory'] = {'user_profile_enabled': 'customers' not in available[slug]['roles']}
            config['platforms']['slack'].update({'rich_blocks': True, 'strict_mention': True, 'thread_require_mention': True,
                'common_router_thread_routes': {'enabled': True, 'database_path': router['claim_database_path'], 'profiles': list(profiles.values())}})
            config['plugins']['entries'].update({
                'team-kit': {'enabled': True, 'settings': {'packs': {'enabled': packs}, 'reply_buttons_plugin': {'enabled': True},
                    'common_router_plugin': {'mode': 'live', 'contract': router}}},
                'team-delegation': {'enabled': True, 'settings': {'packs': {'enabled': packs}}}})
            config_path = destination / 'config.yaml'
            merged = missing_merge(mapping(config_path, home), config)
            enable_managed_plugins(merged, plugins, slug)
            # These lists describe the explicit installation choice, not private account data.
            for plugin in ('team-kit', 'team-delegation'):
                chosen = merged['plugins']['entries'][plugin]['settings']['packs']
                chosen['enabled'] = list(dict.fromkeys(chosen.get('enabled', []) + packs))
            routes = merged['platforms']['slack']['common_router_thread_routes']
            routes['profiles'] = list(dict.fromkeys(routes.get('profiles', []) + list(profiles.values())))
            files[str(relative / 'config.yaml')] = encoded(merged)
            for name in ('profile.yaml', 'SOUL.md', 'slack-manifest.json', 'README.md'):
                if not (destination / name).exists(): files[str(relative / name)] = (root / 'agents' / slug / name).read_bytes()
            for plugin in plugins:
                name = str(relative / 'plugins' / plugin)
                links[name] = os.path.relpath(home / 'plugin-store' / plugin, (home / name).parent)
            user = relative / 'memories/USER.md'
            if slug != default and 'customers' not in available[slug]['roles'] and not (home / user).exists():
                links[str(user)] = os.path.relpath(home / 'memories/USER.md', (home / user).parent)
        for name, value in {
            'owner/team.yaml': {'version': 1, 'agents': {profiles[slug]: {'name': available[slug]['name'], 'roles': available[slug]['roles']} for slug in selected}},
            'owner/vault.yaml': {'version': 1, 'channels': {}, 'accounts': {}, 'notion': {}, 'obsidian': {}},
            'owner/policy.yaml': {'version': 1, 'time_policy': {'rest_start': '11:00', 'quiet_until': '08:30'}, 'profile_packs': {profiles[slug]: packs for slug in selected}, 'schedule_bindings': [], 'rest_day_wrappers': {}},
        }.items():
            path = home / name
            if name == 'owner/vault.yaml' and path.exists(): continue
            files[name] = encoded(missing_merge(mapping(path, home), value))
        if not (home / 'memories/USER.md').exists(): files['memories/USER.md'] = b''
        for name in ('shared/reply-buttons.json', 'schemas/shared-ledgers.json'):
            if not (home / name).exists(): files[name] = (root / name).read_bytes()
    else:
        for slug in selected:
            relative = Path(destinations[slug]) / 'config.yaml'
            config = mapping(safe_path(home, relative), home)
            updated = deepcopy(config)
            enable_managed_plugins(updated, plugins, slug)
            if updated != config: files[str(relative)] = encoded(updated)
    receipt = {'version': 2, 'agents': selected, 'default': default, 'destinations': destinations, 'packs': packs, 'managed': managed, 'connections': previous.get('connections', {}) if args.update else {name: target for name, target in links.items() if not name.startswith('plugin-store/')}}
    sequence = f'{len(records)+1:06d}'
    files['.starter/receipts/' + sequence + '.json'] = encoded(receipt)
    apply_files(home, files, links, managed=managed, previous=previous.get('managed', {}), update=args.update, dry_run=args.dry_run)
    if args.dry_run: return 0
    print('코드 업데이트 완료. 금고·기억·학습·예약·운영 장부는 보존했습니다.' if args.update else '직원과 도구 팩을 설치했습니다. 자동 발송·감시는 켜지 않았습니다.')
    for name in packs: print(name + ': ' + settings['packs'][name]['guide'])
    if args.connect_slack: connect_slack(home, receipt)
    else: print('다음: --connect-slack으로 Slack 앱을 연결하세요. 각 직원의 slack-manifest.json에 필요한 권한이 있습니다.')
    print('모델 연결: hermes setup. 시작: HERMES_DISABLE_LAZY_INSTALLS=1 hermes gateway start')
    print('Slack 기본 채널에서 첫 질문과 승인·거절·의견·확인 버튼을 시험하세요. 실제 발송은 이 설치기가 하지 않습니다.')
    return 0
