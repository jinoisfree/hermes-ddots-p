"""Compatibility import for existing command consumers."""
from pathlib import Path as _Path
import sys as _sys
_library = _Path(__file__).parent / 'lib'
if str(_library) not in _sys.path:
    _sys.path.insert(0, str(_library))
from hermes_governance import request_approvals as _implementation
def __getattr__(name):
    return getattr(_implementation, name)
