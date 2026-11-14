"""Final-answer rewrite steps that other plugins hand to team-kit's single transform_llm_output hook.

The core keeps only the first transform hook that returns text, so a second plugin registering its
own hook would silently skip team-kit's work-halt and button checks (or the reverse). Plugins add a
step here instead; team-kit's hook runs every step first, then its own checks.

One gateway process loads each plugin once per profile home, every copy with its own state, while this
module is shared. A step is therefore kept per home and runs only in the home that registered it, so a
final answer is never checked against another profile's copy."""
from __future__ import annotations

import logging
from typing import Any, Callable

from hermes_constants import hermes_home_key

logger = logging.getLogger(__name__)
_STEPS: dict[tuple[str, str], Callable[..., Any]] = {}


def add(name: str, step: Callable[..., Any]) -> None:
    """Register (or replace) one step of the active home; a step returns new text or None for unchanged."""
    _STEPS[(hermes_home_key(), name)] = step


def apply(text: Any, **context: Any) -> Any:
    home = hermes_home_key()
    for (owner, name), step in list(_STEPS.items()):
        if owner != home:
            continue
        try:
            result = step(response_text=text, **context)
        except Exception:
            logger.exception("output step %s failed", name)
            continue
        if isinstance(result, str) and result:
            text = result
    return text
