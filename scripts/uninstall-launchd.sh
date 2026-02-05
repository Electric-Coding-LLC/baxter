#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME:?HOME is required}"
PLIST_PATH="$HOME_DIR/Library/LaunchAgents/com.electriccoding.baxterd.plist"

launchctl bootout "gui/$(id -u)/com.electriccoding.baxterd" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo "Uninstalled com.electriccoding.baxterd"
