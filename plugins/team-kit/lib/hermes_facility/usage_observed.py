"""Provider usage presence contract shared by plugin hosts."""
from typing import Any, Optional

ANTHROPIC_SHAPE = ((("input_tokens",),), (("output_tokens",),), (("cache_read_input_tokens",),), (("cache_creation_input_tokens",),))
CODEX_SHAPE = (
    (("input_tokens",),), (("output_tokens",),), (("input_tokens_details", "cached_tokens"),),
    (("input_tokens_details", "cache_write_tokens"), ("input_tokens_details", "cache_creation_tokens")),
)
CHAT_SHAPE = (
    (("prompt_tokens",), ("input_tokens",)),
    (("completion_tokens",), ("output_tokens",)),
    (("prompt_tokens_details", "cached_tokens"), ("cache_read_input_tokens",), ("prompt_cache_hit_tokens",), ("cached_tokens",)),
    (("prompt_tokens_details", "cache_write_tokens"), ("prompt_tokens_details", "cache_creation_input_tokens"),
     ("cache_creation_input_tokens",), ("cache_write_tokens",)),
)
INPUT, OUTPUT, CACHE_READ, CACHE_WRITE = 0, 1, 2, 3


def shape(provider: Optional[str], api_mode: Optional[str]):
    name = (provider or "").strip().lower()
    mode = (api_mode or "").strip().lower()
    if mode == "anthropic_messages" or name == "anthropic":
        return ANTHROPIC_SHAPE
    if mode == "codex_responses":
        return CODEX_SHAPE
    return CHAT_SHAPE


def path_present(obj: Any, path: tuple) -> bool:
    """Whether a provider explicitly returned *path*, preserving explicit zero vs missing."""
    current = obj
    for hop in path:
        if isinstance(current, dict):
            if hop not in current:
                return False
            current = current[hop]
        else:
            if not hasattr(current, hop):
                return False
            current = getattr(current, hop)
        if current is None:
            return False
    return True


def observed(raw_usage: Any, which: int, *, provider: Optional[str] = None, api_mode: Optional[str] = None) -> bool:
    return any(path_present(raw_usage, path) for path in shape(provider, api_mode)[which])


def input_usage_observed(response_usage: Any, *, provider: Optional[str] = None, api_mode: Optional[str] = None) -> bool:
    return observed(response_usage, INPUT, provider=provider, api_mode=api_mode)


def output_usage_observed(response_usage: Any, *, provider: Optional[str] = None, api_mode: Optional[str] = None) -> bool:
    return observed(response_usage, OUTPUT, provider=provider, api_mode=api_mode)


def cache_read_usage_observed(response_usage: Any, *, provider: Optional[str] = None, api_mode: Optional[str] = None) -> bool:
    return observed(response_usage, CACHE_READ, provider=provider, api_mode=api_mode)


def cache_write_usage_observed(response_usage: Any, *, provider: Optional[str] = None, api_mode: Optional[str] = None) -> bool:
    return observed(response_usage, CACHE_WRITE, provider=provider, api_mode=api_mode)
