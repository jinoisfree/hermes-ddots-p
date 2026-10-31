"""team-kit registration for the Common Router (``common_router_plugin.mode``: off|shadow|live)."""
from __future__ import annotations

from pathlib import Path


def register(ctx, home) -> None:
    settings = ctx.get_config("common_router_plugin", {}) or {}
    mode = str(settings.get("mode") or "off")
    if mode not in {"shadow", "live"}:
        return
    from hermes_router.ingress import install

    def factory_for(platform):
        # Adapters dedupe factories by (plugin, __qualname__): a lambda would collide with
        # team-kit's other factories (usage footer) and be skipped, so give each its own name.
        def common_router_factory(native, adapter):
            install(adapter, platform, shadow=mode == "shadow", home=Path(home), contract=settings.get("contract"))
        common_router_factory.__qualname__ = f"hermes_router.common_router_factory.{platform}"
        return common_router_factory

    for platform in ("slack", "photon", "bluebubbles"):
        ctx.register_platform_handler(platform, factory_for(platform))
