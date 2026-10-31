"""Notion pack: create one API instance per host to preserve cache isolation."""
from pathlib import Path
import importlib.util


def load_api(name="hermes_notion_api"):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("api.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
