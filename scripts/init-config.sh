#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./scripts/init-config.sh [--force] <backup-root-1> [backup-root-2 ...]"
}

force=0
roots=()
for arg in "$@"; do
  case "$arg" in
    --force)
      force=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      roots+=("$arg")
      ;;
  esac
done

if [ "${#roots[@]}" -lt 1 ]; then
  usage
  exit 1
fi

HOME_DIR="${BAXTER_HOME_DIR:-${HOME:?HOME is required}}"
APP_DIR="${BAXTER_APP_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/baxter}"
CONFIG_PATH="${BAXTER_CONFIG_PATH:-$APP_DIR/config.toml}"

mkdir -p "$APP_DIR"

if [ -f "$CONFIG_PATH" ]; then
  if [ "$force" -ne 1 ]; then
    echo "Refusing to overwrite existing config at $CONFIG_PATH"
    echo "Re-run with --force to replace it."
    exit 1
  fi

  backup_path="$CONFIG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONFIG_PATH" "$backup_path"
  echo "Backed up existing config to $backup_path"
fi

{
  echo "backup_roots = ["
  for root in "${roots[@]}"; do
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
