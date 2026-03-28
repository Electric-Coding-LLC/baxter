#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
CONTENTS_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
DAEMON_BIN="$CONTENTS_DIR/Resources/bin/baxterd"
HOME_DIR="${HOME:-}"

if [ -z "$HOME_DIR" ]; then
  HOME_DIR="$(/usr/bin/dirname "$(/usr/bin/getconf DARWIN_USER_DIR 2>/dev/null || /usr/bin/printf '/tmp/')")"
fi

LOG_DIR="$HOME_DIR/Library/Logs"
/bin/mkdir -p "$LOG_DIR"

export BAXTER_HOME_DIR="$HOME_DIR"
export AWS_SDK_LOAD_CONFIG=1

exec "$DAEMON_BIN" >>"$LOG_DIR/baxterd.out.log" 2>>"$LOG_DIR/baxterd.err.log"
