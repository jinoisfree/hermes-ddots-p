"""Stamp the source revision without embedding developer paths or credentials."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def source_info():
    commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True)
    changed = subprocess.run(['git', 'status', '--porcelain', '--untracked-files=all', '--',
                              'Sources', 'Resources', 'scripts', 'Tests', 'requirements-build.txt'],
                             cwd=ROOT, capture_output=True, text=True)
    return {'commit': commit.stdout.strip() if commit.returncode == 0 else None,
            'dirty': changed.returncode != 0 or bool(changed.stdout.strip())}


if __name__ == '__main__':
    Path(sys.argv[1]).write_text(json.dumps(source_info(), sort_keys=True) + '\n')
