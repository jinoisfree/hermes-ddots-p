"""Stable command entrypoint for the diagnosis pack."""
from pathlib import Path
import sys
library = Path(__file__).resolve().parent.parent
if str(library) not in sys.path: sys.path.insert(0, str(library))
if __name__ == '__main__':
    import runpy
    runpy.run_module('hermes_packs.diagnosis.diagnosis_requests', run_name='__main__')
