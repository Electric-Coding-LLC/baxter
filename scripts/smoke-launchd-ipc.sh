#!/usr/bin/env bash
set -euo pipefail

LABEL="com.electriccoding.baxterd"
SERVICE="gui/$(id -u)/$LABEL"
IPC_URL="http://127.0.0.1:41820"

echo "== launchd service =="
launchctl print "$SERVICE" >/tmp/baxter-launchctl-print.txt
sed -n '1,20p' /tmp/baxter-launchctl-print.txt

if ! grep -q "state = running" /tmp/baxter-launchctl-print.txt; then
  echo "ERROR: $LABEL is not running"
  exit 1
fi

echo "== IPC status =="
STATUS_JSON=$(curl -fsS "$IPC_URL/v1/status")
echo "$STATUS_JSON"

echo "== IPC run trigger =="
RUN_BODY=$(curl -fsS -X POST "$IPC_URL/v1/backup/run")
echo "$RUN_BODY"

echo "smoke check passed"
