"""Compatibility command entrypoint for the configured linked-work schedule."""
from pathlib import Path
import sys
library = Path(__file__).parent / 'lib'
if str(library) not in sys.path: sys.path.insert(0, str(library))
from hermes_packs.linked_work.notion_completion_sync import main

if __name__ == '__main__':
    main(dry_run='--dry-run' in sys.argv)
