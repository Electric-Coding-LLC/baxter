#!/usr/bin/env bash
set -euo pipefail

LABEL="${BAXTER_LAUNCHD_LABEL:-com.electriccoding.baxterd}"
SERVICE="gui/$(id -u)/$LABEL"
IPC_ADDR="${BAXTER_IPC_ADDR:-127.0.0.1:41820}"
IPC_URL="${BAXTER_IPC_URL:-http://$IPC_ADDR}"
RAW_IPC_TOKEN="${BAXTER_IPC_TOKEN:-}"
IPC_TOKEN=""
MAX_ATTEMPTS="${BAXTER_IPC_READY_ATTEMPTS:-20}"
SLEEP_SECONDS="${BAXTER_IPC_READY_SLEEP_SECONDS:-0.5}"
SMOKE_DEADLINE_SECONDS="${BAXTER_SMOKE_DEADLINE_SECONDS:-120}"
CONNECT_TIMEOUT_SECONDS="${BAXTER_IPC_CONNECT_TIMEOUT_SECONDS:-2}"
MAX_TIME_SECONDS="${BAXTER_IPC_MAX_TIME_SECONDS:-5}"
SMOKE_START_EPOCH="$(date +%s)"

LAUNCHCTL_DUMP_FILE="$(mktemp /tmp/baxter-launchctl-print.XXXXXX)"
STATUS_ERR_FILE="$(mktemp /tmp/baxter-smoke-status.err.XXXXXX)"
RUN_ERR_FILE="$(mktemp /tmp/baxter-smoke-run.err.XXXXXX)"
trap 'rm -f "$LAUNCHCTL_DUMP_FILE" "$STATUS_ERR_FILE" "$RUN_ERR_FILE"' EXIT

if [ -n "$RAW_IPC_TOKEN" ]; then
  IFS=',' read -r IPC_TOKEN _ <<< "$RAW_IPC_TOKEN"
  IPC_TOKEN="$(printf '%s' "$IPC_TOKEN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

CURL_ARGS=(-fsS --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$MAX_TIME_SECONDS")
if [ -n "$IPC_TOKEN" ]; then
  CURL_ARGS+=(-H "X-Baxter-Token: $IPC_TOKEN")
fi

echo "== launchd service =="
launchctl print "$SERVICE" >"$LAUNCHCTL_DUMP_FILE"
sed -n '1,20p' "$LAUNCHCTL_DUMP_FILE"

if ! grep -q "state = running" "$LAUNCHCTL_DUMP_FILE"; then
  echo "ERROR: $LABEL is not running"
  exit 1
fi

echo "== IPC status =="
STATUS_JSON=""
for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
  NOW_EPOCH="$(date +%s)"
  if [ "$((NOW_EPOCH - SMOKE_START_EPOCH))" -ge "$SMOKE_DEADLINE_SECONDS" ]; then
    echo "ERROR: smoke deadline exceeded (${SMOKE_DEADLINE_SECONDS}s) while waiting for IPC readiness"
    exit 1
  fi

  if STATUS_JSON=$(curl "${CURL_ARGS[@]}" "$IPC_URL/v1/status" 2>"$STATUS_ERR_FILE"); then
    if printf '%s' "$STATUS_JSON" | grep -q '"state"'; then
      break
    fi
  fi
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "ERROR: failed to reach $IPC_URL/v1/status after $MAX_ATTEMPTS attempts"
    cat "$STATUS_ERR_FILE"
    exit 1
  fi
  sleep "$SLEEP_SECONDS"
done
echo "$STATUS_JSON"

echo "== IPC run trigger =="
RUN_BODY=$(curl "${CURL_ARGS[@]}" -X POST "$IPC_URL/v1/backup/run" 2>"$RUN_ERR_FILE")
if ! printf '%s' "$RUN_BODY" | grep -q '"status":"started"'; then
  echo "ERROR: unexpected run trigger response: $RUN_BODY"
  if [ -s "$RUN_ERR_FILE" ]; then
    echo "== run trigger stderr =="
    cat "$RUN_ERR_FILE"
  fi
  exit 1
fi
echo "$RUN_BODY"

echo "smoke check passed"
