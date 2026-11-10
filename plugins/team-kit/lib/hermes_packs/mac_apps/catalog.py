"""App routes are public capabilities, never per-user connection state."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

CATALOG_FILE = Path(__file__).with_name('app_catalog.json')

def load_catalog():
    value = json.loads(CATALOG_FILE.read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError('APP_CATALOG_INVALID')
    from hermes_packs.files_docs import files
    for item in value.values():
        if item['service'] in ('synology', 'local_files'):
            item['tools'] = files.tool_names(dict(enabled=True,convert=True,extra_only=False,
                synology=dict(enabled=item['service']=='synology')))
    return value

def entry(app, self_id=None):
    if app['bundle_id'] == self_id:
        return dict(route='excluded', service=None, tools=[], permission='none',
                    can_do='', rules=[], reason='지금 이 연결 화면을 보여 주는 앱이에요.')
    configured = load_catalog().get(connection_key(app['bundle_id']))
    if configured is not None:
        return dict(configured)
    if sync_folders(app):
        from hermes_packs.files_docs import files
        return dict(route='tool', service='local_files', tools=files.tool_names(dict(enabled=True,convert=True,extra_only=False)),
            permission='none', can_do='고른 동기화 폴더의 파일을 읽고 다룰 수 있어요.',
            rules=[], reason=None, packs=['files-docs'], scope='sync_folders')
    scripting = app['has_sdef']
    return dict(route='sdef' if scripting else 'none', service=None,
                tools=['mac_app'] if scripting else [],
                permission='apple_events' if scripting else 'none',
                can_do=app.get('script_description') or ('앱이 공개한 항목을 읽고 다룰 수 있어요.' if scripting else ''),
                rules=[], reason=None if scripting else '이 앱은 다른 프로그램이 쓸 수 있는 방법을 열어 두지 않았어요.')

def connection_key(bundle):
    return 'service:obsidian-notes' if bundle == 'md.obsidian' else bundle


def obsidian_service():
    return dict(bundle_id='service:obsidian-notes', name='Obsidian 메모(보관함)',
                group='service', has_sdef=False, features={})


def script_description(path):
    try:
        tree = ET.parse(path)
        suite = tree.find('.//suite')
        if suite is None: return ''
        text = suite.get('description') or ', '.join(c.get('name', '') for c in suite.findall('class'))
        import re
        return ' '.join(text.split())[:240] if re.search('[가-힣]', text) else ''
    except (OSError, ET.ParseError):
        return ''


def sync_folders(app, home=None):
    """Use installed File Provider folders, not a table of personal bundle ids."""
    home = Path.home() if home is None else Path(home)
    name = ''.join(c.casefold() for c in app.get('name', '') if c.isalnum())
    cloud = home / 'Library/CloudStorage'
    found = []
    if cloud.is_dir():
        for path in sorted(cloud.iterdir()):
            provider = ''.join(c.casefold() for c in path.name.split('-')[0] if c.isalnum())
            if path.is_dir() and name and (name in provider or provider in name): found.append(path)
    if app.get('bundle_id') == 'com.apple.finder':
        documents = home / 'Library/Mobile Documents/com~apple~CloudDocs'
        if documents.is_dir(): found.append(documents)
    return found
