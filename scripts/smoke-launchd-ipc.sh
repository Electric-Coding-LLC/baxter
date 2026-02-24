#!/usr/bin/env bash
set -euo pipefail

LABEL="com.electriccoding.baxterd"
SERVICE="gui/$(id -u)/$LABEL"
IPC_URL="${BAXTER_IPC_URL:-http://127.0.0.1:41820}"
RAW_IPC_TOKEN="${BAXTER_IPC_TOKEN:-}"
IPC_TOKEN=""
MAX_ATTEMPTS="${BAXTER_IPC_READY_ATTEMPTS:-20}"
SLEEP_SECONDS="${BAXTER_IPC_READY_SLEEP_SECONDS:-0.5}"

if [ -n "$RAW_IPC_TOKEN" ]; then
  IFS=',' read -r IPC_TOKEN _ <<< "$RAW_IPC_TOKEN"
  IPC_TOKEN="$(printf '%s' "$IPC_TOKEN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

CURL_ARGS=(-fsS)
if [ -n "$IPC_TOKEN" ]; then
  CURL_ARGS+=(-H "X-Baxter-Token: $IPC_TOKEN")
fi

echo "== launchd service =="
launchctl print "$SERVICE" >/tmp/baxter-launchctl-print.txt
sed -n '1,20p' /tmp/baxter-launchctl-print.txt

if ! grep -q "state = running" /tmp/baxter-launchctl-print.txt; then
  echo "ERROR: $LABEL is not running"
  exit 1
fi

echo "== IPC status =="
STATUS_JSON=""
for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
  if STATUS_JSON=$(curl "${CURL_ARGS[@]}" "$IPC_URL/v1/status" 2>/tmp/baxter-smoke-status.err); then
    break
  fi
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "ERROR: failed to reach $IPC_URL/v1/status after $MAX_ATTEMPTS attempts"
    cat /tmp/baxter-smoke-status.err
    exit 1
  fi
  sleep "$SLEEP_SECONDS"
done
echo "$STATUS_JSON"

echo "== IPC run trigger =="
RUN_BODY=$(curl "${CURL_ARGS[@]}" -X POST "$IPC_URL/v1/backup/run")
echo "$RUN_BODY"

echo "smoke check passed"
