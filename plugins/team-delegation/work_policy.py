"""Compatibility import for the shared work-publication scope guard."""
from pathlib import Path
import sys

_library = Path(__file__).parent / 'lib'
if str(_library) not in sys.path:
    sys.path.append(str(_library))
from hermes_facility.work_scope import ERROR, shared_pages, permitted, notion_problem
