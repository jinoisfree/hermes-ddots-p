"""Run the installed connection facility for this home; no connection logic here."""
import os
from pathlib import Path
import sys

launcher = Path(sys.argv.pop(1)).absolute()
home = Path(os.environ.get('HERMES_HOME') or launcher.parent.parent).absolute()
os.environ.update(HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS='1', PYTHONDONTWRITEBYTECODE='1')
sys.path.insert(0, str(home / 'plugin-store/team-kit/lib'))
try:
    from hermes_facility.connections import main
except Exception:
    # Import is outside the facility's main error boundary.
    print('{"error":"connection_start_failed"}')
    raise SystemExit(1) from None
raise SystemExit(main(home))
