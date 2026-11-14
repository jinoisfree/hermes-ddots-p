#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/module-cache"
SYNTHETIC_CONFIG=$(mktemp -d)
trap 'rm -rf "$SYNTHETIC_CONFIG"' EXIT
export DDOTS_CONFIG_ROOT="$SYNTHETIC_CONFIG/config" HERMES_HOME="$SYNTHETIC_CONFIG/home"
mkdir -p "$HERMES_HOME"
python3 "$ROOT/Tests/prepare_config.py" "$DDOTS_CONFIG_ROOT"
xcrun swiftc "$ROOT/Sources/HermesRouting.swift" "$ROOT/Sources/DdotsConfig.swift" -swift-version 5 -module-cache-path "$ROOT/.build/module-cache" "$ROOT/Sources/AppIdentity.swift" "$ROOT/Sources/PetLayout.swift" "$ROOT/Sources/CalendarMatch.swift" "$ROOT/Sources/Conversation.swift" "$ROOT/Sources/MessageFormat.swift" "$ROOT/Sources/ProfileAvatar.swift" "$ROOT/Sources/ChatStyle.swift" "$ROOT/Sources/BubbleOpacity.swift" "$ROOT/Sources/HermesLocator.swift" "$ROOT/Sources/HermesBridge.swift" "$ROOT/Sources/LoginLaunch.swift" "$ROOT/Sources/ThreeTap.swift" "$ROOT/Sources/ThreeTapNotice.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UsageSources.swift" "$ROOT/Sources/StreamPreview.swift" "$ROOT/Sources/AgentConnections.swift" "$ROOT/Sources/HermesRelay.swift" "$ROOT/Sources/SettingsSync.swift" "$ROOT/Sources/FileDropHistory.swift" "$ROOT/Sources/FileDropService.swift" "$ROOT/Sources/HermesRelayServer.swift" "$ROOT/Sources/RemoteHermes.swift" "$ROOT/Sources/RelayPortraits.swift" "$ROOT/Tests/FileDropModelRelayTests.swift" -o "$ROOT/.build/FileDropModelRelayTests"
"$ROOT/.build/FileDropModelRelayTests"
