"""Share exact request permits after the normal file/Notion scope guards have accepted a call."""
from pathlib import Path
import importlib.util
from types import SimpleNamespace
import importlib.util as _ilu, pathlib as _pl, sys as _sys
team = _sys.modules.get('hermes_team_registry')
if team is None:
    _spec = _ilu.spec_from_file_location('hermes_team_registry', _pl.Path(__file__).with_name('team_registry.py'))
    team = _sys.modules['hermes_team_registry'] = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(team)


def module(home):
    from hermes_governance import request_approvals
    return request_approvals


def gate(home, name, args, decision, context):
    home = Path(home)
    if not team.home_has_role(home, 'work', 'personal') or not decision or decision.get('action') != 'approve':
        return decision
    from gateway.session_context import get_session_env
    import os
    api = module(home)
    td = SimpleNamespace(get_session_env=get_session_env,
        personal_roles=SimpleNamespace(profile=lambda td: home.name),
        personal_scopes=SimpleNamespace(background=lambda td: any(get_session_env(flag, '') or os.environ.get(flag)
            for flag in ('HERMES_CRON_SESSION', 'HERMES_SINGLE_QUERY_SESSION', 'HERMES_KANBAN_TASK'))),
        _personal_role_problem=lambda *a: None)
    if api.allowed(td, name, args, context):
        return None
    return api.gate(td, name, args, decision, context)
