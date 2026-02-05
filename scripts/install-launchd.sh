#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${HOME:?HOME is required}"

APP_SUPPORT_DIR="$HOME_DIR/Library/Application Support/baxter"
BIN_DIR="$APP_SUPPORT_DIR/bin"
BAXTERD_BIN="$BIN_DIR/baxterd"
CONFIG_PATH="$APP_SUPPORT_DIR/config.toml"
IPC_ADDR="127.0.0.1:41820"

LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.electriccoding.baxterd.plist"
TEMPLATE_PATH="$ROOT_DIR/launchd/com.electriccoding.baxterd.plist.template"

mkdir -p "$BIN_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Expected config at $CONFIG_PATH"
  echo "Create it first (you can start from $ROOT_DIR/config.example.toml)."
  exit 1
fi

pushd "$ROOT_DIR" >/dev/null
go build -o "$BAXTERD_BIN" ./cmd/baxterd
popd >/dev/null

sed \
  -e "s|__BAXTERD_BIN__|$BAXTERD_BIN|g" \
  -e "s|__CONFIG_PATH__|$CONFIG_PATH|g" \
  -e "s|__IPC_ADDR__|$IPC_ADDR|g" \
  -e "s|__HOME__|$HOME_DIR|g" \
  "$TEMPLATE_PATH" > "$PLIST_PATH"

launchctl bootout "gui/$(id -u)/com.electriccoding.baxterd" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/com.electriccoding.baxterd"

launchctl print "gui/$(id -u)/com.electriccoding.baxterd" >/dev/null

echo "Installed and started com.electriccoding.baxterd"
echo "Plist: $PLIST_PATH"
echo "Binary: $BAXTERD_BIN"
