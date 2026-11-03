"""Final-answer rewrite steps that other plugins hand to team-kit's single transform_llm_output hook.

The core keeps only the first transform hook that returns text, so a second plugin registering its
own hook would silently skip team-kit's work-halt and button checks (or the reverse). Plugins add a
step here instead; team-kit's hook runs every step first, then its own checks."""
from __future__ import annotations

import logging
from typing import Any, Callable

logger = logging.getLogger(__name__)
_STEPS: dict[str, Callable[..., Any]] = {}


def add(name: str, step: Callable[..., Any]) -> None:
    """Register (or replace) one step; a step returns new text or None for unchanged."""
    _STEPS[name] = step


def apply(text: Any, **context: Any) -> Any:
    for name, step in list(_STEPS.items()):
        try:
            result = step(response_text=text, **context)
        except Exception:
            logger.exception("output step %s failed", name)
            continue
        if isinstance(result, str) and result:
            text = result
    return text
