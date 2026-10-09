#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/packaged-app-smoke.sh --zip /path/to/Baxter-darwin-arm64.zip [--debug-dir /path/to/output]

Validates the packaged Baxter.app install path by unpacking the signed app,
launching it with a temporarily cleaned Baxter home for the current user, and
verifying bundled-helper bootstrap.

The smoke replaces /Applications/Baxter.app, the Baxter app support directory,
and the launchd service of the current user while it runs. It skips when a live
install is present unless BAXTER_PACKAGED_SMOKE_ALLOW_LIVE_INSTALL=1 is set.
EOF
}

ZIP_PATH=""
DEBUG_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)
      ZIP_PATH="${2:-}"
      shift 2
      ;;
    --debug-dir)
      DEBUG_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$ZIP_PATH" ]; then
  usage
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "packaged-app-smoke.sh must run on macOS" >&2
  exit 1
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "zip artifact not found: $ZIP_PATH" >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command codesign
require_command cmp
require_command ditto
require_command launchctl
require_command plutil
require_command shasum

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/baxter-packaged-app-smoke.XXXXXX")"
BACKUP_ROOT="$RUN_ROOT/backup-root"
SERVICE_LABEL="com.electriccoding.baxterd"
SERVICE_TARGET="gui/$(id -u)/$SERVICE_LABEL"
IPC_URL="http://127.0.0.1:41820"
REAL_HOME="${HOME:?HOME is required}"
APP_SUPPORT_DIR="$REAL_HOME/Library/Application Support/baxter"
APP_SUPPORT_PARENT_DIR="$(dirname "$APP_SUPPORT_DIR")"
LAUNCH_AGENTS_DIR="$REAL_HOME/Library/LaunchAgents"
LEGACY_LAUNCH_AGENT_PATH="$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist"
LOG_DIR="$REAL_HOME/Library/Logs"
DAEMON_OUT_LOG="$LOG_DIR/baxterd.out.log"
DAEMON_ERR_LOG="$LOG_DIR/baxterd.err.log"
BACKUP_DIR="$RUN_ROOT/backups"
APP_SUPPORT_BACKUP="$BACKUP_DIR/app-support"
LEGACY_LAUNCH_AGENT_BACKUP="$BACKUP_DIR/legacy-launch-agent.plist"
DAEMON_OUT_LOG_BACKUP="$BACKUP_DIR/baxterd.out.log"
DAEMON_ERR_LOG_BACKUP="$BACKUP_DIR/baxterd.err.log"
INSTALLED_APP_PATH="/Applications/Baxter.app"
INSTALLED_APP_BACKUP="$BACKUP_DIR/Baxter.app"

if [ -n "$DEBUG_DIR" ]; then
  mkdir -p "$DEBUG_DIR"
else
  DEBUG_DIR="$RUN_ROOT/debug"
  mkdir -p "$DEBUG_DIR"
fi

APP_STDOUT_LOG="$DEBUG_DIR/app.stdout.log"
APP_STDERR_LOG="$DEBUG_DIR/app.stderr.log"
CODESIGN_LOG="$DEBUG_DIR/codesign.log"
LAUNCHCTL_DOMAIN_LOG="$DEBUG_DIR/launchctl-domain.log"
LAUNCHCTL_SERVICE_LOG="$DEBUG_DIR/launchctl-service.log"
STATUS_JSON_PATH="$DEBUG_DIR/status.json"
INSTALLED_CLI_STATUS_LOG="$DEBUG_DIR/installed-cli-status.log"
RUNTIME_DAEMON_OUT_LOG="$DEBUG_DIR/runtime-baxterd.out.log"
RUNTIME_DAEMON_ERR_LOG="$DEBUG_DIR/runtime-baxterd.err.log"
HELPER_INSTALL_LOG="$DEBUG_DIR/helper-install.log"

mkdir -p "$BACKUP_ROOT" "$BACKUP_DIR"

backup_existing_path() {
  local source_path="$1"
  local backup_path="$2"
  if [ -e "$source_path" ]; then
    mkdir -p "$(dirname "$backup_path")"
    mv "$source_path" "$backup_path"
  else
    # Marks a path this smoke may create and later delete.
    : >"$backup_path.absent"
  fi
}

# Puts back what backup_existing_path moved aside. A path that existed but
# could not be moved aside has neither a backup nor a marker and is left alone.
restore_backed_up_path() {
  local source_path="$1"
  local backup_path="$2"
  if [ -e "$backup_path" ]; then
    rm -rf "$source_path"
    mkdir -p "$(dirname "$source_path")"
    mv "$backup_path" "$source_path"
  elif [ -e "$backup_path.absent" ]; then
    rm -rf "$source_path"
  fi
}

wait_for_installed_helper() {
  local name="$1"
  local bundled_path="$2"
  local installed_path="$3"
  local timeout_seconds="${4:-30}"

  : >"$HELPER_INSTALL_LOG"

  for _ in $(seq 1 "$timeout_seconds"); do
    if [ -x "$installed_path" ] && cmp -s "$bundled_path" "$installed_path"; then
      return 0
    fi
    sleep 1
  done

  {
    echo "installed helper check failed for $name"
    echo "bundled_path=$bundled_path"
    echo "installed_path=$installed_path"
    if [ -e "$bundled_path" ]; then
      echo "bundled_sha256=$(shasum -a 256 "$bundled_path" | awk '{print $1}')"
      ls -l "$bundled_path"
    else
      echo "bundled file missing"
    fi
    if [ -e "$installed_path" ]; then
      echo "installed_sha256=$(shasum -a 256 "$installed_path" | awk '{print $1}')"
      ls -l "$installed_path"
    else
      echo "installed file missing"
    fi
  } >>"$HELPER_INSTALL_LOG"

  return 1
}

cleanup() {
  # Nothing below may run unless this script replaced the install itself.
  if [ "${install_swapped:-0}" != "1" ]; then
    if [ -z "${KEEP_RUN_ROOT:-}" ]; then
      rm -rf "$RUN_ROOT"
    fi
    return
  fi
  launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true
  if [ -n "${app_pid:-}" ]; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [ -f "$DAEMON_OUT_LOG" ]; then
    cp -f "$DAEMON_OUT_LOG" "$RUNTIME_DAEMON_OUT_LOG" >/dev/null 2>&1 || true
  fi
  if [ -f "$DAEMON_ERR_LOG" ]; then
    cp -f "$DAEMON_ERR_LOG" "$RUNTIME_DAEMON_ERR_LOG" >/dev/null 2>&1 || true
  fi
  restore_backed_up_path "$APP_SUPPORT_DIR" "$APP_SUPPORT_BACKUP"
  restore_backed_up_path "$LEGACY_LAUNCH_AGENT_PATH" "$LEGACY_LAUNCH_AGENT_BACKUP"
  restore_backed_up_path "$DAEMON_OUT_LOG" "$DAEMON_OUT_LOG_BACKUP"
  restore_backed_up_path "$DAEMON_ERR_LOG" "$DAEMON_ERR_LOG_BACKUP"
  restore_backed_up_path "$INSTALLED_APP_PATH" "$INSTALLED_APP_BACKUP"
  if [ "${service_was_running:-0}" = "1" ]; then
    launchctl kickstart -k "$SERVICE_TARGET" >/dev/null 2>&1 || true
  fi
  if [ -z "${KEEP_RUN_ROOT:-}" ]; then
    rm -rf "$RUN_ROOT"
  fi
}
trap cleanup EXIT

if ! launchctl print "gui/$(id -u)" >"$LAUNCHCTL_DOMAIN_LOG" 2>&1; then
  echo "Skipping packaged app smoke: gui/$(id -u) domain unavailable."
  exit 0
fi

service_was_running=0
service_registered=0
SERVICE_BEFORE_LOG="$RUN_ROOT/service-before.log"
if launchctl print "$SERVICE_TARGET" >"$SERVICE_BEFORE_LOG" 2>&1; then
  service_registered=1
  if grep -q 'state = running' "$SERVICE_BEFORE_LOG"; then
    service_was_running=1
  fi
fi

# This smoke replaces /Applications/Baxter.app, the app support directory, and
# the launchd service for the current user. Refuse to do that to a real install.
if [ "${BAXTER_PACKAGED_SMOKE_ALLOW_LIVE_INSTALL:-0}" != "1" ]; then
  live_install=""
  if [ "$service_registered" = "1" ]; then
    live_install="launchd service $SERVICE_LABEL"
  fi
  for live_path in "$INSTALLED_APP_PATH" "$APP_SUPPORT_DIR" "$LEGACY_LAUNCH_AGENT_PATH"; do
    if [ -e "$live_path" ]; then
      live_install="$live_path"
    fi
  done
  if [ -n "$live_install" ]; then
    echo "Skipping packaged app smoke: live Baxter install found ($live_install)."
    echo "Set BAXTER_PACKAGED_SMOKE_ALLOW_LIVE_INSTALL=1 to replace it for the duration of the smoke."
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::warning title=Packaged app smoke skipped::Live Baxter install found on this runner ($live_install); the packaged app path was not tested."
    fi
    exit 0
  fi
fi

install_swapped=1
backup_existing_path "$APP_SUPPORT_DIR" "$APP_SUPPORT_BACKUP"
backup_existing_path "$LEGACY_LAUNCH_AGENT_PATH" "$LEGACY_LAUNCH_AGENT_BACKUP"
backup_existing_path "$DAEMON_OUT_LOG" "$DAEMON_OUT_LOG_BACKUP"
backup_existing_path "$DAEMON_ERR_LOG" "$DAEMON_ERR_LOG_BACKUP"
backup_existing_path "$INSTALLED_APP_PATH" "$INSTALLED_APP_BACKUP"

ditto -x -k "$ZIP_PATH" "/Applications"
APP_PATH="$INSTALLED_APP_PATH"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"
BUNDLED_BIN_DIR="$APP_PATH/Contents/Resources/bin"
BUNDLED_LAUNCH_AGENT="$APP_PATH/Contents/Library/LaunchAgents/com.electriccoding.baxterd.plist"
INSTALLED_BIN_DIR="$APP_SUPPORT_DIR/bin"
INSTALLED_CLI="$INSTALLED_BIN_DIR/baxter"
INSTALLED_DAEMON="$INSTALLED_BIN_DIR/baxterd"

if [ ! -d "$APP_PATH" ]; then
  echo "Expected app bundle at $APP_PATH" >&2
  exit 1
fi

test -x "$BUNDLED_BIN_DIR/baxter"
test -x "$BUNDLED_BIN_DIR/baxterd"
test -x "$BUNDLED_BIN_DIR/baxterd-launch.sh"
test -f "$BUNDLED_LAUNCH_AGENT"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >"$CODESIGN_LOG" 2>&1

mkdir -p "$APP_SUPPORT_PARENT_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
HOME="$REAL_HOME" BAXTER_HOME_DIR="$REAL_HOME" "$ROOT_DIR/scripts/init-config.sh" "$BACKUP_ROOT" >/dev/null
launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true

APP_EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST_PATH")"
APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
if [ ! -x "$APP_EXECUTABLE_PATH" ]; then
  echo "App executable is not runnable: $APP_EXECUTABLE_PATH" >&2
  exit 1
fi

env \
  -u BAXTER_APP_SUPPORT_DIR \
  -u BAXTER_CONFIG_PATH \
  -u BAXTER_HOME_DIR \
  -u BAXTER_IPC_ADDR \
  -u BAXTER_IPC_TOKEN \
  -u BAXTER_LAUNCHD_LABEL \
  HOME="$REAL_HOME" \
  "$APP_EXECUTABLE_PATH" >"$APP_STDOUT_LOG" 2>"$APP_STDERR_LOG" &
app_pid=$!

for _ in $(seq 1 60); do
  if curl -fsS "$IPC_URL/v1/status" >"$STATUS_JSON_PATH" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ ! -s "$STATUS_JSON_PATH" ]; then
  launchctl print "$SERVICE_TARGET" >"$LAUNCHCTL_SERVICE_LOG" 2>&1 || true
  echo "Packaged app smoke failed: daemon IPC never became ready." >&2
  echo "App stderr:" >&2
  cat "$APP_STDERR_LOG" >&2 || true
  echo "launchctl service dump:" >&2
  cat "$LAUNCHCTL_SERVICE_LOG" >&2 || true
  exit 1
fi

launchctl print "$SERVICE_TARGET" >"$LAUNCHCTL_SERVICE_LOG" 2>&1
grep -q 'managed_by = com.apple.xpc.ServiceManagement' "$LAUNCHCTL_SERVICE_LOG"
grep -q 'parent bundle identifier = com.electriccoding.BaxterApp' "$LAUNCHCTL_SERVICE_LOG"
grep -q 'program identifier = Contents/Resources/bin/baxterd-launch.sh' "$LAUNCHCTL_SERVICE_LOG"
wait_for_installed_helper "baxter" "$BUNDLED_BIN_DIR/baxter" "$INSTALLED_CLI"
wait_for_installed_helper "baxterd" "$BUNDLED_BIN_DIR/baxterd" "$INSTALLED_DAEMON"
"$INSTALLED_CLI" backup status >"$INSTALLED_CLI_STATUS_LOG"

echo "packaged app smoke passed"
cat "$STATUS_JSON_PATH"
