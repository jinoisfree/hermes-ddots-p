"""Social reading and owner-started media operations."""
import importlib.util
from pathlib import Path
import sys


def load_video_jobs(name):
    """Each host owns its approval grants, lock and expiration timers."""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('video_job.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
