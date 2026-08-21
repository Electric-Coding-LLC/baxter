#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: ./scripts/run-in-gui-session.sh <command> [args...]" >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "run-in-gui-session.sh must run on macOS" >&2
  exit 1
fi

RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/baxter-gui-command.XXXXXX")"
LABEL="com.electriccoding.baxter.gui-command.$(id -u).$$"
SERVICE_TARGET="gui/$(id -u)/$LABEL"
COMMAND_PATH="$RUN_ROOT/command.sh"
PLIST_PATH="$RUN_ROOT/$LABEL.plist"
STATUS_PATH="$RUN_ROOT/status"
STDOUT_PATH="$RUN_ROOT/stdout.log"
STDERR_PATH="$RUN_ROOT/stderr.log"
TIMEOUT_SECONDS="${BAXTER_GUI_COMMAND_TIMEOUT_SECONDS:-2700}"

cleanup() {
  launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

{
  echo '#!/usr/bin/env bash'
  echo 'set +e'
  printf 'export HOME=%q\n' "${HOME:?HOME is required}"
  printf 'export PATH=%q\n' "${PATH:?PATH is required}"
  printf 'export TMPDIR=%q\n' "${TMPDIR:-/tmp}"
  printf 'cd %q\n' "$PWD"
  printf 'command=('
  printf ' %q' "$@"
  echo ' )'
  echo '"${command[@]}"'
  echo 'status=$?'
  printf 'printf "%%s\\n" "$status" > %q\n' "$STATUS_PATH"
  echo 'exit "$status"'
} >"$COMMAND_PATH"

cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$COMMAND_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STDOUT_PATH</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_PATH</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST_PATH" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ ! -f "$STATUS_PATH" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "GUI command timed out after ${TIMEOUT_SECONDS}s." >&2
    cat "$STDOUT_PATH" 2>/dev/null || true
    cat "$STDERR_PATH" >&2 2>/dev/null || true
    exit 124
  fi
  sleep 1
done

cat "$STDOUT_PATH" 2>/dev/null || true
cat "$STDERR_PATH" >&2 2>/dev/null || true
exit "$(cat "$STATUS_PATH")"
