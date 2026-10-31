"""Optional installation pack selection; existing hosts without this setting are unchanged."""
import json
import logging
from pathlib import Path
import sys


def catalog():
    return json.loads((Path(__file__).resolve().parents[1] / 'hermes_packs/catalog.json').read_text())['packs']


def selected(requested, platform=None):
    available = catalog()
    enabled = set(requested)
    if any(not isinstance(name, str) or name not in available for name in enabled):
        raise ValueError('unknown tool pack')
    changed = True
    while changed:
        before = set(enabled)
        for name in before:
            enabled.update(available[name].get('requires', {}).get('packs', []))
        if enabled - available.keys(): raise ValueError('missing required pack')
        changed = enabled != before
    return enabled


class PackContext:
    def __init__(self, context, enabled, unavailable=False):
        self._context = context
        self._unavailable = unavailable
        self._enabled = selected(enabled)
        self._packs = catalog()

    def __getattr__(self, name):
        return getattr(self._context, name)

    def register_tool(self, *args, **kwargs):
        if self._unavailable: return None
        name = kwargs.get('name') or (args[0] if args else None)
        owners = {key for key, pack in self._packs.items() if name in pack['tools']}
        if owners and not owners.intersection(self._enabled): return None
        if sys.platform != 'darwin' and (str(name).startswith(('apple_notes_', 'contacts_direct_', 'messages_direct_')) or name == 'file_trash'):
            return None
        return self._context.register_tool(*args, **kwargs)


def scoped_context(context):
    try:
        config = context.get_config('packs', None)
    except Exception:
        logging.getLogger(__name__).warning('Pack configuration unavailable; tool registration disabled')
        return PackContext(context, [], unavailable=True)
    if config is None or config == {}: return context
    if not isinstance(config, dict) or not isinstance(config.get('enabled'), list):
        raise ValueError('invalid pack selection')
    return PackContext(context, config['enabled'])
