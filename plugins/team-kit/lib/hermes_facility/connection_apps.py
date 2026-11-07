"""Installed Mac apps and the Hermes connections each one maps to (REQ-08).

Reads only app bundles' Info.plist and the presence of Metadata.appintents.
Never launches an app, sends an Apple event or writes anything.
The app -> connection table is app_links.json, the only place to add a pairing.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib

APP_ROOTS = ('/Applications', '/Applications/Utilities', '/System/Applications',
             '/System/Applications/Utilities', '~/Applications')
MAX_APPS = 500
LINKS_FILE = Path(__file__).with_name('app_links.json')
LOCALIZATION = 'ko.lproj'


def load_links():
    value = json.loads(LINKS_FILE.read_text(encoding='utf-8'))
    return {k: v for k, v in value.items() if isinstance(k, str) and isinstance(v, str)}


def read_plist(path):
    try:
        with open(path, 'rb') as stream:
            value = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, dict) else None


def localized_name(resources, info, stem):
    strings = read_plist(resources / LOCALIZATION / 'InfoPlist.strings') or {}
    for source in (strings, info):
        for key in ('CFBundleDisplayName', 'CFBundleName'):
            if isinstance(source.get(key), str) and source[key]:
                return source[key]
    return stem


def read_app(path):
    """One app dict, or None when the folder is not a readable app bundle."""
    wrapped = (path / 'WrappedBundle').is_symlink() or (path / 'Wrapper').is_dir()
    if wrapped:
        inner = next(iter(sorted((path / 'Wrapper').glob('*.app'))), None)
        base, info = inner, read_plist(inner / 'Info.plist') if inner else None
        resources = inner
    else:
        base = path / 'Contents'
        info, resources = read_plist(base / 'Info.plist'), base / 'Resources'
    if not info or not isinstance(info.get('CFBundleIdentifier'), str):
        return None
    scripting = (bool(info.get('OSAScriptingDefinition')) or info.get('NSAppleScriptEnabled') is True
                 or any(resources.glob('*.sdef')))
    return dict(name=localized_name(resources, info, path.stem), bundle_id=info['CFBundleIdentifier'],
                kind='ios_wrapped' if wrapped else 'mac',
                features=dict(applescript=scripting,
                              app_intents=(resources / 'Metadata.appintents').is_dir(),
                              url_schemes=bool(info.get('CFBundleURLTypes'))))


def scan(roots=None):
    seen = {}
    for root in (APP_ROOTS if roots is None else roots):
        folder = Path(os.path.expanduser(root))
        try:
            candidates = sorted(p for p in folder.iterdir() if p.suffix == '.app' and p.is_dir())
        except OSError:
            continue
        for path in candidates:
            app = read_app(path)
            if app and app['bundle_id'] not in seen:
                seen[app['bundle_id']] = app
    return sorted(seen.values(), key=lambda app: (app['name'].casefold(), app['bundle_id']))[:MAX_APPS]


def installed_apps(root, roots=None):
    """Status rows come from the same inventory the status command prints, without the Google checks
    (no mapped app is Google), so the pills match the connection pages."""
    from hermes_facility import connections
    google = {key: ('unknown', 'CHECK_FAILED') for key in ('personal', 'company')}
    agents = connections.inventory(root, google=google)['agents']
    links = load_links()
    result = []
    for app in scan(roots):
        service = links.get(app['bundle_id'])
        app['links'] = [dict(profile=agent['profile'], connection=row['id'], state=row['state'])
                        for agent in agents for row in agent['connections'] if service and row['service'] == service]
        result.append(app)
    return dict(schema='hermes-installed-apps/1', scanned_at=datetime.now(timezone.utc).isoformat(), apps=result)
