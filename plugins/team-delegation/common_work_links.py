"""Compatibility for persisted project settings; implementation lives in the linked-work pack."""
from pathlib import Path
import sys
library = Path(__file__).parent / 'lib'
if str(library) not in sys.path: sys.path.insert(0, str(library))
from hermes_packs.linked_work.common_work_links import *
