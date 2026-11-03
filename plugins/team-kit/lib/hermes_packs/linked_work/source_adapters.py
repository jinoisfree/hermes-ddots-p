"""Source adapters shared by identity checks and synchronization; no watcher dependency."""
from pathlib import Path
import re, json, subprocess, importlib.util, sys
from hermes_facility import team_registry as team, owner_vault as vault
HOME = team.home_of_role('work', Path.home()/'.hermes')
DATABASE = vault.text('notion.work_db', '(owner-vault-notion-work-db-unset)').replace('-', '')
DUE = '다음 마감'

def page_id(value):
    value = str(value).replace('-', '').lower()
    if not re.fullmatch('[0-9a-f]{32}', value):
        raise ValueError('invalid page identifier')
    return value


def load_module(name, package):
    from hermes_facility.loading import fresh
    return fresh(package, name)


def page_title(page):
    found = [(name, value) for name, value in page.get('properties', {}).items() if 'title' in value]
    if len(found) != 1:
        raise ValueError('single Notion title property required')
    name, value = found[0]
    return name, ''.join(v.get('plain_text', v.get('text', {}).get('content', '')) for v in value['title'])


class NotionReader:
    def __init__(self, home):
        self.home = home
        from hermes_packs.notion import load_api
        self.api = load_api('_completion_notion_api')

    def request(self, method, path, body=None):
        # This class exposes only the three read operations below.
        return self.api.request(self.home, method, path, body)

    def changed(self, since):
        cursor = None
        while True:
            body = {'page_size': 100, 'filter': {'timestamp': 'last_edited_time',
                    'last_edited_time': {'on_or_after': since}}}
            if cursor:
                body['start_cursor'] = cursor
            result = self.request('POST', f'databases/{DATABASE}/query', body)
            yield from result['results']
            if not result.get('has_more'):
                break
            cursor = result['next_cursor']

    def page(self, identifier):
        return self.request('GET', f'pages/{identifier}')

    # Linked-work sync writes (2026-10-16 owner decision). Callers verify the page's database.
    def check_todo(self, block_id):
        return self.request('PATCH', f'blocks/{block_id}', {'to_do': {'checked': True}})

    def set_due(self, identifier, day):
        return self.request('PATCH', f'pages/{identifier}', {'properties': {DUE: {'date': {'start': day}}}})

    def set_title(self, identifier, expected, title):
        before = self.page(identifier)
        if (page_id(before.get('parent', {}).get('database_id', '')) != DATABASE or before.get('in_trash')
                or before.get('archived') or page_title(before)[1] != expected):
            raise ValueError('Notion title identity/scope changed')
        name, _ = page_title(before)
        self.request('PATCH', f'pages/{identifier}', {'properties': {name: {'title': [{'text': {'content': title}}]}}})
        if page_title(self.page(identifier))[1] != title:
            raise RuntimeError('Notion title verification failed')

    def blocks(self, identifier):
        result, stack, seen = [], [identifier], set()
        while stack:
            parent = stack.pop()
            if parent in seen:
                raise ValueError('cyclic blocks')
            seen.add(parent)
            cursor = None
            while True:
                suffix = '?page_size=100' + (f'&start_cursor={cursor}' if cursor else '')
                data = self.request('GET', f'blocks/{parent}/children{suffix}')
                for block in data['results']:
                    result.append(block)
                    if len(result) > 10000:
                        raise ValueError('block limit exceeded')
                    if block.get('has_children'):
                        stack.append(block['id'])
                if not data.get('has_more'):
                    break
                cursor = data['next_cursor']
        return result


def company_scope_guard(domain, args, *, strict=False):
    """The existing background-write exception covers company originals only."""
    import hermes_yaml
    from types import SimpleNamespace
    root = Path.home() / '.hermes'
    shared = hermes_yaml.safe_load((root / 'config.yaml').read_text())['plugins']['entries']['team-kit']['settings'].get('personal_scopes')
    if not shared or shared.get('enabled') is not True:
        if strict:
            raise ValueError('company title scope unavailable')
        return
    tools = load_module('_company_scope_sync', 'hermes_execution')
    settings = hermes_yaml.safe_load((HOME / 'config.yaml').read_text())['plugins']['entries']['team-delegation']['settings']
    tools._PLUGIN_CONTEXT = SimpleNamespace(get_config=lambda k,d=None:settings.get(k,d))
    tools.personal_scopes.authorize_mutation(tools, domain, args, {}, scope_config=shared, owner_scope='company')


class Calendar:
    def __init__(self):
        self.plugin = None

    def tools(self):
        if self.plugin is None:
            self.plugin = load_module('_linked_calendar_tools', 'hermes_execution')
        return self.plugin

    def lookup(self, identifier):
        return self.tools()._calendar_event_lookup(identifier)

    def get(self, identifier):
        return self.tools()._calendar_event_get(identifier)

    def rename(self, event, title):
        company_scope_guard('calendar', {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_start': event['start']}, strict=True)
        after = self.tools()._calendar_event_rename(event, title)
        if not after or after.get('title') != title:
            raise RuntimeError('calendar title verification failed')

    def set_notes(self, event, notes):
        company_scope_guard('calendar', {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_start': event['start']}, strict=True)
        if self.tools()._calendar_event_set_notes(event, notes) is None:
            raise RuntimeError('calendar notes verification failed')

    def move(self, event, start, end):
        company_scope_guard('calendar', {'action': 'update', 'event_id': event['calendarItemIdentifier'], 'expected_start': event['start']}, strict=True)
        if self.tools()._calendar_event_move(event, start, end) is None:
            raise RuntimeError('calendar move failed')


class Notes:
    def __init__(self):
        self.plugin = None

    def tools(self):
        if self.plugin is None:
            self.plugin = load_module('_completion_note_tools', 'hermes_execution')
        return self.plugin

    def current(self, identifier):
        return self.tools()._note_verification_snapshot(identifier, subprocess.run)

    def link_state(self, identifier):
        before = self.current(identifier)
        return None if not before else {**self.tools()._note_link_state(before.get('plaintext') or ''), 'title': before.get('title')}

    def rename(self, identifier, expected, title):
        company_scope_guard('notes', {'action': 'update', 'note_id': identifier, 'rename_title': True}, strict=True)
        before = self.current(identifier)
        if not before or before.get('title') != expected:
            raise ValueError('note title changed')
        if not self.tools()._rename_linked_note(identifier, title, before).get('ok'):
            raise RuntimeError('note title/body verification failed')

    def edit(self, identifier, lines, edits, before):
        company_scope_guard('notes', {'action': 'update', 'note_id': identifier}, strict=True)
        return self.tools()._edit_linked_note(identifier, before, lines, edits)

    def append(self, identifier, line, before):
        company_scope_guard('notes', {'action': 'update', 'note_id': identifier}, strict=True)
        if before and before.get('attachment_names'):
            return self.tools()._append_note_rebuild(identifier, line, before)
        return self.tools()._append_plain_note(identifier, line, before)
