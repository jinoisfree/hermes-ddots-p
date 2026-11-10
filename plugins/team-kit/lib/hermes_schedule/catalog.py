"""Render private timing/delivery policy against reusable role/pack job templates."""
from copy import deepcopy
from contextlib import contextmanager
import fcntl
import os
import tempfile
import hashlib
import json
from pathlib import Path

RUN_FIELDS = frozenset({'next_run_at', 'last_run_at', 'last_status', 'last_error', 'last_delivery_error',
    'failure_streak', 'monitor_state', 'last_failure', 'last_delivery_unverified', 'fire_claim', 'last_dispatch',
    'created_at', 'state', 'paused_at', 'pending_slot', 'manual_run_prompt', 'quota_hold_until'})


def read(path):
    text = Path(path).read_text()
    try:
        return json.loads(text)
    except ValueError:
        from ruamel.yaml import YAML
        # Same YAML 1.2 rules as the writer (config_assembly.yaml_bytes): unquoted 18:00 stays a string.
        return YAML(typ='safe').load(text)


def definition(job):
    value = {key: deepcopy(item) for key, item in job.items() if key not in RUN_FIELDS}
    if isinstance(value.get('repeat'), dict):
        value['repeat'].pop('completed', None)
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def rendered(root):
    root = Path(root)
    roster = read(root / 'owner/team.yaml')['agents']
    templates = read(root / 'schedules/templates.json')['templates']
    policy = read(root / 'owner/policy.yaml')
    if policy.get('version') != 1:
        raise ValueError('unsupported owner policy version')
    output = {}
    for binding in policy['schedule_bindings']:
        template = templates[binding['template']]
        profiles = [name for name, agent in roster.items() if template['role'] in agent.get('roles', [])]
        if len(profiles) != 1:
            raise ValueError('schedule role must resolve to exactly one profile: ' + template['role'])
        value = deepcopy(template['defaults'])
        value.update(deepcopy(binding['settings']))
        value.update(deepcopy(binding['timing']))
        value.update(deepcopy(binding['delivery']))
        value['id'] = binding['job_id']
        if definition(value) != value:
            raise ValueError('runtime fields in schedule definition')
        key = profiles[0], value['id']
        if key in output: raise ValueError('duplicate schedule binding')
        output[key] = {'job': value}
    return output


def home_for(root, profile):
    if profile == 'default': return Path(root)
    if not profile or Path(profile).name != profile or profile in {'.', '..'}:
        raise ValueError('invalid schedule profile')
    return Path(root) / 'profiles' / profile


def live_jobs(home):
    data = read(Path(home) / 'cron/jobs.json')
    return data.get('jobs', []) if isinstance(data, dict) else data


def check(root):
    expected = rendered(root)
    differences = []
    for profile in sorted({key[0] for key in expected}):
        actual = {job['id']: definition(job) for job in live_jobs(home_for(root, profile))}
        for (owner, identifier), row in expected.items():
            if owner == profile and actual.get(identifier) != row['job']:
                differences.append({'profile': profile, 'job_id': identifier, 'reason': 'definition_differs'})
    return {'managed': len(expected), 'differences': differences}


def _apply(root, ledger, save):
    """Update existing managed jobs only; use the core lock and mutation API.

    A changed runtime definition rejects stale policy. Unmanaged jobs and runtime counters
    are never replaced. An unchanged definition causes no write or next-run recalculation.
    """
    from cron import jobs
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    expected = rendered(root)
    changed = []
    for profile in sorted({key[0] for key in expected}):
        home = home_for(root, profile)
        token = set_hermes_home_override(home)
        try:
            with jobs._jobs_lock():
                rows = jobs._peek_jobs_unlocked()
                if rows is None: raise ValueError('invalid runtime cron store')
                actual = {job['id']: job for job in rows}
                wanted = [(identifier, row) for (owner, identifier), row in expected.items() if owner == profile]
                for identifier, row in wanted:
                    if identifier not in actual: raise ValueError('managed job missing; no automatic creation')
                    current = definition(actual[identifier])
                    if current != row['job'] and digest(current) != ledger.get(profile, {}).get(identifier):
                        raise ValueError('runtime schedule changed; preserve it and reconcile policy first')
                for identifier, row in wanted:
                    current = definition(actual[identifier])
                    updates = {key: value for key, value in row['job'].items() if key != 'id' and (key not in current or current[key] != value)}
                    if set(current) - set(row['job']):
                        raise ValueError('field removal requires an explicit native cron edit')
                    if updates:
                        if 'enabled' in updates or 'paused_reason' in updates:
                            raise ValueError('lifecycle changes require native cron pause/resume, then capture')
                        if 'repeat' in updates:
                            updates['repeat'] = {**actual[identifier].get('repeat', {}), **updates['repeat']}
                        result = jobs.update_job(identifier, updates)
                        if not result: raise RuntimeError('managed job update failed')
                        ledger.setdefault(profile, {})[identifier] = digest(definition(result))
                        save(ledger)
                        changed.append((profile, identifier))
        finally:
            reset_hermes_home_override(token)
    return changed


@contextmanager
def _ledger(root):
    directory = Path(root) / 'state'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'schedule-assembly.json'
    with (directory / 'schedule-assembly.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = read(path) if path.exists() else {'version': 1, 'baselines': {}}
        if data.get('version') != 1:
            raise ValueError('unsupported schedule state version')
        def save(baselines):
            fd, temporary = tempfile.mkstemp(prefix='.schedule-', dir=directory)
            try:
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'version': 1, 'baselines': baselines}, stream, indent=2)
                    stream.write('\n')
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        yield data['baselines'], save


def capture(root):
    """Record a baseline only when private sources match all managed runtime definitions."""
    with _ledger(root) as (ledger, save):
        if check(root)['differences']:
            raise ValueError('reconcile policy with native jobs before capture')
        expected = rendered(root)
        baseline = {}
        for (profile, identifier), row in expected.items():
            baseline.setdefault(profile, {})[identifier] = digest(row['job'])
        if baseline != ledger: save(baseline)
    return len(expected)


def apply(root):
    """Serialize assembly; native edits fail closed, unchanged jobs are never rewritten."""
    with _ledger(root) as (ledger, save):
        return _apply(root, ledger, save)
