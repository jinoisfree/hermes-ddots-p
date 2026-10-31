"""Create isolated instances from installed shared packages, without plugin paths."""
import importlib.util
import sys


def fresh(package, namespace):
    source = importlib.util.find_spec(package)
    if source is None or not source.origin:
        raise ImportError(package)
    spec = importlib.util.spec_from_file_location(namespace, source.origin,
            submodule_search_locations=list(source.submodule_search_locations) if source.submodule_search_locations else None)
    module = importlib.util.module_from_spec(spec)
    sys.modules[namespace] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        if sys.modules.get(namespace) is module:
            del sys.modules[namespace]
        raise
    return module


def source_path(package):
    from pathlib import Path
    source = importlib.util.find_spec(package)
    if source is None or not source.origin:
        raise ImportError(package)
    return Path(source.origin)
