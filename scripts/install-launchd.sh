#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${BAXTER_HOME_DIR:-${HOME:?HOME is required}}"
LAUNCHD_LABEL="${BAXTER_LAUNCHD_LABEL:-com.electriccoding.baxterd}"

APP_SUPPORT_DIR="${BAXTER_APP_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/baxter}"
BIN_DIR="$APP_SUPPORT_DIR/bin"
BAXTERD_BIN="$BIN_DIR/baxterd"
CONFIG_PATH="${BAXTER_CONFIG_PATH:-$APP_SUPPORT_DIR/config.toml}"
IPC_ADDR="${BAXTER_IPC_ADDR:-127.0.0.1:41820}"
BAXTERD_BINARY_PATH="${BAXTERD_BINARY_PATH:-}"

LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LAUNCHD_LABEL.plist"
TEMPLATE_PATH="$ROOT_DIR/launchd/com.electriccoding.baxterd.plist.template"
IPC_TOKEN="${BAXTER_IPC_TOKEN:-}"
AWS_PROFILE_VALUE="${AWS_PROFILE:-}"
AWS_SDK_LOAD_CONFIG_VALUE="${AWS_SDK_LOAD_CONFIG:-}"
AWS_REGION_VALUE="${AWS_REGION:-}"
AWS_DEFAULT_REGION_VALUE="${AWS_DEFAULT_REGION:-}"
AWS_SHARED_CREDENTIALS_FILE_VALUE="${AWS_SHARED_CREDENTIALS_FILE:-}"
AWS_CONFIG_FILE_VALUE="${AWS_CONFIG_FILE:-}"
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY:-}"
AWS_SESSION_TOKEN_VALUE="${AWS_SESSION_TOKEN:-}"

if [ -z "$AWS_PROFILE_VALUE" ] && [ -f "$CONFIG_PATH" ]; then
  AWS_PROFILE_VALUE="$(awk '
    /^\[s3\]$/ { in_s3=1; next }
    /^\[/ { in_s3=0 }
    in_s3 && $0 ~ /^[[:space:]]*aws_profile[[:space:]]*=/ {
      line=$0
      sub(/^[[:space:]]*aws_profile[[:space:]]*=[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH")"
fi
if [ -n "$AWS_PROFILE_VALUE" ] && [ -z "$AWS_SDK_LOAD_CONFIG_VALUE" ]; then
  AWS_SDK_LOAD_CONFIG_VALUE="1"
fi

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
  -e "s|__LABEL__|$LAUNCHD_LABEL|g" \
  -e "s|__BAXTERD_BIN__|$BAXTERD_BIN|g" \
  -e "s|__CONFIG_PATH__|$CONFIG_PATH|g" \
  -e "s|__IPC_ADDR__|$IPC_ADDR|g" \
  -e "s|__HOME__|$HOME_DIR|g" \
  "$TEMPLATE_PATH" > "$PLIST_PATH"

if [ -n "$IPC_TOKEN" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --ipc-token" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string $IPC_TOKEN" "$PLIST_PATH"
fi

/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string $HOME_DIR" "$PLIST_PATH"

add_env_var() {
  local key="$1"
  local value="$2"
  if [ -n "$value" ]; then
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:$key string $value" "$PLIST_PATH"
  fi
}

add_env_var "AWS_PROFILE" "$AWS_PROFILE_VALUE"
add_env_var "AWS_SDK_LOAD_CONFIG" "$AWS_SDK_LOAD_CONFIG_VALUE"
add_env_var "AWS_REGION" "$AWS_REGION_VALUE"
add_env_var "AWS_DEFAULT_REGION" "$AWS_DEFAULT_REGION_VALUE"
add_env_var "AWS_SHARED_CREDENTIALS_FILE" "$AWS_SHARED_CREDENTIALS_FILE_VALUE"
add_env_var "AWS_CONFIG_FILE" "$AWS_CONFIG_FILE_VALUE"
add_env_var "AWS_ACCESS_KEY_ID" "$AWS_ACCESS_KEY_ID_VALUE"
add_env_var "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY_VALUE"
add_env_var "AWS_SESSION_TOKEN" "$AWS_SESSION_TOKEN_VALUE"

launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$LAUNCHD_LABEL"

launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null

echo "Installed and started $LAUNCHD_LABEL"
echo "Plist: $PLIST_PATH"
echo "Binary: $BAXTERD_BIN"
if [ -n "$IPC_TOKEN" ]; then
  echo "IPC auth: enabled (token sourced from BAXTER_IPC_TOKEN)"
else
  echo "IPC auth: disabled (set BAXTER_IPC_TOKEN before install to enable)"
fi
if [ -n "$AWS_PROFILE_VALUE" ]; then
  echo "AWS auth: using AWS_PROFILE=$AWS_PROFILE_VALUE"
elif [ -n "$AWS_ACCESS_KEY_ID_VALUE" ]; then
  echo "AWS auth: using explicit AWS access key environment"
else
  echo "AWS auth: no AWS environment variables were propagated"
fi
