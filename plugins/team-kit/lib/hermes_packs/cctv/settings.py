"""Policy (owner/policy.yaml: cctv_watch) and vault (owner/vault.yaml: cctv, channels) values, validated once."""
from pathlib import Path

from hermes_facility import owner_vault, team_registry
from hermes_schedule.catalog import read

INTEGERS = ('before_minutes', 'after_minutes', 'interval_minutes', 'reconnect_wait_seconds',
            'capture_retention_days', 'alert_after_failures', 'min_window_width', 'min_window_height')
TEXTS = ('range_name', 'expires_at')
RECONNECT_MODES = ('ask', 'off')   # off: only tell the owner; there is no automatic mode (shared Windows account)
VAULT_TEXTS = ('cctv.rdp_device', 'cctv.site_label', 'cctv.channel_label', 'channels.customer_room')


class SettingsError(ValueError):
    pass


def teach_check_minutes(root=None):
    """Inspection freshness from the owner's policy only; invalid or disabled means no check source."""
    path = Path(root or team_registry.root_home()) / 'owner/policy.yaml'
    block = read(path).get('cctv_watch') if path.exists() else None
    if not isinstance(block, dict) or block.get('enabled') is not True:
        return None
    value = block.get('teach_check_minutes')
    return value if type(value) is int and 1 <= value <= 60 else None


def policy(root=None):
    """The validated cctv_watch block. Returns None when the feature is off or not configured."""
    path = Path(root or team_registry.root_home()) / 'owner/policy.yaml'
    block = read(path).get('cctv_watch') if path.exists() else None
    if not isinstance(block, dict) or block.get('enabled') is not True:
        return None
    for key in INTEGERS:
        if type(block.get(key)) is not int or block[key] < 0:
            raise SettingsError('CCTV_POLICY_INVALID:' + key)
    for key in TEXTS:
        if not isinstance(block.get(key), str) or not block[key].strip():
            raise SettingsError('CCTV_POLICY_INVALID:' + key)
    if block['interval_minutes'] < 1:
        raise SettingsError('CCTV_POLICY_INVALID:interval_minutes')
    hour, _, minute = block['expires_at'].partition(':')
    if not (hour.isdigit() and minute.isdigit() and int(hour) < 24 and int(minute) < 60):
        raise SettingsError('CCTV_POLICY_INVALID:expires_at')
    mode = block.get('reconnect', 'ask')
    if mode not in RECONNECT_MODES:
        raise SettingsError('CCTV_POLICY_INVALID:reconnect')
    relive = block.get('relive', 'auto')
    limit = block.get('relive_daily_limit', 10)
    if relive not in ('auto', 'off'):
        raise SettingsError('CCTV_POLICY_INVALID:relive')
    if type(limit) is not int or limit < 1:
        raise SettingsError('CCTV_POLICY_INVALID:relive_daily_limit')
    return {**block, 'reconnect': mode, 'relive': relive, 'relive_daily_limit': limit}


def site():
    """Windows App device, site and channel labels, and the room proposals go to, from the owner vault."""
    values = {key.split('.')[-1]: owner_vault.text(key) for key in VAULT_TEXTS}
    missing = [key for key in VAULT_TEXTS if not values[key.split('.')[-1]]]
    if missing:
        raise SettingsError('CCTV_VAULT_MISSING:' + ','.join(missing))
    values['channel_index'] = owner_vault.get('cctv.channel_index')
    if type(values['channel_index']) is not int or values['channel_index'] < 1:
        raise SettingsError('CCTV_VAULT_INVALID:cctv.channel_index')
    values['app_icon_label'] = owner_vault.text('cctv.app_icon_label')
    return values


REGION_KEYS = {'x': 'left', 'y': 'top', 'w': 'width', 'h': 'height'}   # not x/y: YAML reads an unquoted `y` as true


def scene_region():
    """(region, note): the part of the video pane the scene is read from, from the owner vault (`cctv.scene_region`:
    `left`, `top`, `width`, `height` as fractions of the pane, a value per camera). `region` is None with note
    'missing' or 'invalid' when the whole pane should be read instead."""
    value = owner_vault.get('cctv.scene_region')
    if value is None:
        return None, 'missing'
    try:
        box = {key: float(value[name]) for key, name in REGION_KEYS.items()}
    except (KeyError, TypeError, ValueError):
        return None, 'invalid'
    if (any(box[key] != box[key] for key in box) or min(box.values()) < 0 or box['w'] < 0.05 or box['h'] < 0.05
            or box['x'] + box['w'] > 1.0001 or box['y'] + box['h'] > 1.0001):
        return None, 'invalid'
    return box, None
