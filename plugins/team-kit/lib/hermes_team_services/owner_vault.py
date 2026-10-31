"""Compatibility import; implementation is shared in hermes_facility."""
from pathlib import Path as _Path
import sys as _sys
_library = _Path(__file__).resolve().parent.parent
if str(_library) not in _sys.path:
    _sys.path.insert(0, str(_library))
from hermes_facility import owner_vault as _implementation
def __getattr__(name):
    return getattr(_implementation, name)
