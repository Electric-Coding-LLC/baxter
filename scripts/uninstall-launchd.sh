#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${BAXTER_HOME_DIR:-${HOME:?HOME is required}}"
LABEL="${BAXTER_LAUNCHD_LABEL:-com.electriccoding.baxterd}"
PLIST_PATH="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo "Uninstalled $LABEL"
