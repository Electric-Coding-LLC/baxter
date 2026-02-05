#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: ./scripts/init-config.sh <backup-root-1> [backup-root-2 ...]"
  exit 1
fi

HOME_DIR="${HOME:?HOME is required}"
APP_DIR="$HOME_DIR/Library/Application Support/baxter"
CONFIG_PATH="$APP_DIR/config.toml"

mkdir -p "$APP_DIR"

{
  echo "backup_roots = ["
  for root in "$@"; do
    echo "  \"$root\","
  done
  echo "]"
  echo
  echo "schedule = \"manual\""
  echo
  echo "[s3]"
  echo "endpoint = \"\""
  echo "region = \"\""
  echo "bucket = \"\""
  echo "prefix = \"baxter/\""
  echo
  echo "[encryption]"
  echo "keychain_service = \"baxter\""
  echo "keychain_account = \"default\""
} > "$CONFIG_PATH"

echo "Wrote $CONFIG_PATH"
