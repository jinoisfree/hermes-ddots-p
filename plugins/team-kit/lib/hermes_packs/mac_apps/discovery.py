"""Installed Mac apps and the Hermes connections each one maps to (REQ-08).

Reads only app bundles' Info.plist and the presence of Metadata.appintents.
Never launches an app, sends an Apple event or writes anything.
Routing lives in this pack; employee grants live in the facility app_registry.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess

APP_ROOTS = ('/Applications', '/Applications/Utilities', '/System/Applications',
             '/System/Applications/Utilities', '~/Applications',
             '/System/Library/CoreServices/Finder.app')
MAX_APPS = 500
LOCALIZATION = 'ko.lproj'


def read_plist(path):
    try:
        with open(path, 'rb') as stream:
            value = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, dict) else None


def localized_name(resources, info, stem):
    path = resources / LOCALIZATION / 'InfoPlist.strings'
    strings = read_plist(path)
    if strings is None and path.is_file():
        # InfoPlist.strings also uses Apple's UTF-16/OpenStep format, which
        # plistlib does not parse. plutil reads data only; it never runs the app.
        try:
            result = subprocess.run(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', str(path)],
                                    capture_output=True, timeout=2, check=False)
            strings = plistlib.loads(result.stdout) if result.returncode == 0 else {}
        except (OSError, ValueError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
            strings = {}
    strings = strings if isinstance(strings, dict) else {}
    table = read_plist(resources / 'InfoPlist.loctable') or {}
    korean = table.get('ko', {})
    korean = korean if isinstance(korean, dict) else {}
    for source in (strings, korean, info):
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
    has_sdef = any(resources.glob('*.sdef'))
    # Cocoa's older metadata is converted to sdef only after connection/permission.
    has_sdef = has_sdef or any(resources.glob('*.scriptSuite'))
    scripting = (bool(info.get('OSAScriptingDefinition')) or info.get('NSAppleScriptEnabled') is True
                 or any(resources.glob('*.sdef')))
    from hermes_packs.mac_apps.catalog import script_description
    description = next((script_description(p) for p in sorted(resources.glob('*.sdef'))), '')
    return dict(script_description=description, has_sdef=has_sdef, name=localized_name(resources, info, path.stem), bundle_id=info['CFBundleIdentifier'],
                kind='ios_wrapped' if wrapped else 'mac',
                features=dict(applescript=scripting,
                              app_intents=(resources / 'Metadata.appintents').is_dir(),
                              url_schemes=bool(info.get('CFBundleURLTypes'))))


def app_paths(roots=None):
    for root in (APP_ROOTS if roots is None else roots):
        folder = Path(os.path.expanduser(root))
        try:
            if folder.suffix == '.app':
                children = [folder]
            else:
                children = sorted(p for p in folder.iterdir() if p.is_dir())
            candidates = [p for p in children if p.suffix == '.app']
            for child in children:
                if child.suffix != '.app':
                    try:
                        candidates.extend(sorted(p for p in child.iterdir() if p.suffix == '.app' and p.is_dir()))
                    except OSError:
                        continue
        except OSError:
            continue
        yield from candidates


def locate(bundle, roots=None):
    for path in app_paths(roots):
        app = read_app(path)
        if app and app['bundle_id'] == bundle: return path
    return None


def scan(roots=None):
    seen = {}
    for path in app_paths(roots):
        try: app = read_app(path)
        except (OSError, ValueError): continue
        if app and app['bundle_id'] not in seen: seen[app['bundle_id']] = app
    return sorted(seen.values(), key=lambda app: (app['name'].casefold(), app['bundle_id']))[:MAX_APPS]


def installed_apps(root, roots=None, self_id=None):
    """Status rows come from the same inventory the status command prints, without the Google checks
    (no mapped app is Google), so the pills match the connection pages."""
    from hermes_facility import connections
    google = {key: ('unknown', 'CHECK_FAILED') for key in ('personal', 'company')}
    agents = connections.inventory(root, google=google)['agents']
    from hermes_packs.mac_apps import catalog
    from hermes_facility import app_registry, app_connect
    profiles = {p: (h, cfg) for p, h, _, cfg in connections.profile_contexts(root)}
    groups = {p: dict(profile=p,role_hint=app_registry.role_hint(root,p),connected=[],connectable=[],unavailable=[]) for p in profiles}
    result = []
    discovered = scan(roots)
    if not any(a['bundle_id'] == 'md.obsidian' for a in discovered): discovered.append(catalog.obsidian_service())
    for app in discovered:
        app.update(catalog.entry(app, self_id))
        app['connection_key'] = catalog.connection_key(app['bundle_id'])
        service = app['service']
        app['links'] = [dict(profile=agent['profile'], connection=row['id'], state=row['state'])
                        for agent in agents for row in agent['connections'] if service and row['service'] == service
                        and (row['id'] == 'app-' + app['bundle_id'] or row['group'] != 'channel')]
        result.append(app)
        for profile, (home, config) in profiles.items():
            is_connected = app_registry.connected(config, home, app)
            state = 'connected' if is_connected else ('unavailable' if app['route'] in ('none', 'excluded') else 'connectable')
            item=dict(app,state=state)
            progress = app_connect.pending_progress(root, home, profile, app['connection_key'])
            if progress: item['progress'] = progress
            if service in ('synology','local_files'):
                chosen=app_registry.grants(root,profile,config)|{app['connection_key']}
                item['tools']=app_registry.capabilities(chosen,config,app_registry.values(root,profile))[app['connection_key']]['tools']
            groups[profile][state].append(item)
    installed = {catalog.connection_key(a['bundle_id']) for a in result}
    for profile, (home, config) in profiles.items():
        for bundle in sorted(app_registry.grants(root, profile, config) - installed):
            groups[profile]['connected'].append(dict(bundle_id=bundle, name=bundle, state='app_missing',
                route='none', can_do='', rules=[], reason='앱이 없어요. 다시 설치하면 연결을 이어가요.'))
    return dict(schema='hermes-installed-apps/1', scanned_at=datetime.now(timezone.utc).isoformat(), apps=[a for a in result if a.get('group') != 'service'],
                services=[a for a in result if a.get('group') == 'service'], agents=list(groups.values()))
