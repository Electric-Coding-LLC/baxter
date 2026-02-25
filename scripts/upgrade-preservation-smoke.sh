#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/upgrade-preservation-smoke.sh --before /path/to/baxter-before --after /path/to/baxter-after

Runs a local upgrade smoke check that verifies config/state files do not drift across a binary replacement.
EOF
}

before_bin=""
after_bin=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --before)
      before_bin="${2:-}"
      shift 2
      ;;
    --after)
      after_bin="${2:-}"
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

if [ -z "$before_bin" ] || [ -z "$after_bin" ]; then
  usage
  exit 1
fi

if [ ! -x "$before_bin" ]; then
  echo "before binary is not executable: $before_bin" >&2
  exit 1
fi
if [ ! -x "$after_bin" ]; then
  echo "after binary is not executable: $after_bin" >&2
  exit 1
fi

run_root="$(mktemp -d "${TMPDIR:-/tmp}/baxter-upgrade-preserve.XXXXXX")"
cleanup() {
  rm -rf "$run_root"
}
trap cleanup EXIT

home_dir="$run_root/home"
xdg_config_home="$home_dir/.config"
backup_root="$run_root/source"
restore_target="$run_root/restore-target"

if [ "$(uname -s)" = "Darwin" ]; then
  app_dir="$home_dir/Library/Application Support/baxter"
else
  app_dir="$xdg_config_home/baxter"
fi
bin_dir="$app_dir/bin"

mkdir -p "$home_dir" "$app_dir" "$bin_dir" "$backup_root" "$restore_target"

export HOME="$home_dir"
export XDG_CONFIG_HOME="$xdg_config_home"
export BAXTER_PASSPHRASE="upgrade-preservation-smoke-passphrase"

seed_file="$backup_root/notes.txt"
printf 'upgrade preservation seed %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" >"$seed_file"

config_path="$app_dir/config.toml"
cat >"$config_path" <<EOF
backup_roots = ["$backup_root"]
schedule = "manual"

[s3]
endpoint = ""
region = ""
bucket = ""
prefix = "baxter/"

[encryption]
keychain_service = "baxter"
keychain_account = "default"
EOF

state_digest() {
  local output_path="$1"
  (
    cd "$app_dir"
    find . -type f ! -path './bin/*' | LC_ALL=C sort | while IFS= read -r rel; do
      hash="$(shasum -a 256 "$rel" | awk '{print $1}')"
      size="$(wc -c <"$rel" | tr -d ' ')"
      printf '%s %s %s\n' "$rel" "$size" "$hash"
    done
  ) >"$output_path"
}

install_binary() {
  local source="$1"
  install -m 0755 "$source" "$bin_dir/baxter"
}

echo "== seed state using before binary =="
install_binary "$before_bin"
"$bin_dir/baxter" backup run
"$bin_dir/baxter" backup status
"$bin_dir/baxter" snapshot list --limit 1

if [ ! -f "$app_dir/manifest.json" ]; then
  echo "manifest was not created at $app_dir/manifest.json" >&2
  exit 1
fi
if [ ! -d "$app_dir/objects" ]; then
  echo "object store directory missing at $app_dir/objects" >&2
  exit 1
fi
if [ ! -d "$app_dir/manifests" ]; then
  echo "snapshot directory missing at $app_dir/manifests" >&2
  exit 1
fi

baseline_digest="$run_root/baseline.digest"
after_digest="$run_root/after.digest"
state_digest "$baseline_digest"

echo "== upgrade to after binary and verify read paths =="
cp "$bin_dir/baxter" "$bin_dir/baxter.prev"
install_binary "$after_bin"
"$bin_dir/baxter" backup status
"$bin_dir/baxter" snapshot list --limit 1
"$bin_dir/baxter" restore --dry-run --to "$restore_target" "$seed_file"

state_digest "$after_digest"

if ! diff -u "$baseline_digest" "$after_digest"; then
  echo "ERROR: config/state drift detected after upgrade" >&2
  exit 1
fi

echo "upgrade-preservation smoke check passed"
