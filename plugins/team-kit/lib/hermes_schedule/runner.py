"""One holiday gate runner, reached through the original profile script aliases."""
from pathlib import Path
import sys

_library = Path(__file__).resolve().parents[1]
if str(_library) not in sys.path:
    sys.path.insert(0, str(_library))
from hermes_schedule.catalog import read
from hermes_team_services import load


def run(invoked):
    invoked = Path(invoked).absolute()  # Preserve the profile alias, not the shared code location.
    home = invoked.parent.parent
    root = home.parent.parent if home.parent.name == 'profiles' else home
    policy = read(root / 'owner/policy.yaml')
    options = dict(policy['rest_day_wrappers'][str(invoked.relative_to(root))])
    key = options.pop('key')
    if 'retry_state' in options:
        relative = Path(options['retry_state'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('invalid retry-state path')
        options['retry_state'] = home / relative
    rest_day = load('rest_day', '_schedule_rest_day')
    return rest_day.wrap(key, str(invoked), inner_base=invoked.parent, **options)


if __name__ == '__main__':
    sys.exit(run(__file__))
