#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${HOME:?HOME is required}"

APP_SUPPORT_DIR="$HOME_DIR/Library/Application Support/baxter"
BIN_DIR="$APP_SUPPORT_DIR/bin"
BAXTERD_BIN="$BIN_DIR/baxterd"
CONFIG_PATH="$APP_SUPPORT_DIR/config.toml"
IPC_ADDR="127.0.0.1:41820"
BAXTERD_BINARY_PATH="${BAXTERD_BINARY_PATH:-}"

LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.electriccoding.baxterd.plist"
TEMPLATE_PATH="$ROOT_DIR/launchd/com.electriccoding.baxterd.plist.template"
IPC_TOKEN="${BAXTER_IPC_TOKEN:-}"

mkdir -p "$BIN_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Expected config at $CONFIG_PATH"
  echo "Create it first (you can start from $ROOT_DIR/config.example.toml)."
  exit 1
fi

if [ -n "$BAXTERD_BINARY_PATH" ]; then
  if [ ! -x "$BAXTERD_BINARY_PATH" ]; then
    echo "BAXTERD_BINARY_PATH must point to an executable file: $BAXTERD_BINARY_PATH"
    exit 1
  fi
  install -m 0755 "$BAXTERD_BINARY_PATH" "$BAXTERD_BIN"
else
  pushd "$ROOT_DIR" >/dev/null
  go build -o "$BAXTERD_BIN" ./cmd/baxterd
  popd >/dev/null
fi

sed \
  -e "s|__BAXTERD_BIN__|$BAXTERD_BIN|g" \
  -e "s|__CONFIG_PATH__|$CONFIG_PATH|g" \
  -e "s|__IPC_ADDR__|$IPC_ADDR|g" \
  -e "s|__HOME__|$HOME_DIR|g" \
  "$TEMPLATE_PATH" > "$PLIST_PATH"

if [ -n "$IPC_TOKEN" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --ipc-token" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string $IPC_TOKEN" "$PLIST_PATH"
fi

launchctl bootout "gui/$(id -u)/com.electriccoding.baxterd" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/com.electriccoding.baxterd"

launchctl print "gui/$(id -u)/com.electriccoding.baxterd" >/dev/null

echo "Installed and started com.electriccoding.baxterd"
echo "Plist: $PLIST_PATH"
echo "Binary: $BAXTERD_BIN"
if [ -n "$IPC_TOKEN" ]; then
  echo "IPC auth: enabled (token sourced from BAXTER_IPC_TOKEN)"
else
  echo "IPC auth: disabled (set BAXTER_IPC_TOKEN before install to enable)"
fi
