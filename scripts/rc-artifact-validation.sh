#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/rc-artifact-validation.sh --artifact-dir /path/to/artifacts --version vX.Y.Z-rcN --evidence /path/to/evidence.md

Validates RC artifacts through install, first backup, upgrade, and rollback paths.
EOF
}

artifact_dir=""
version=""
evidence_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-dir)
      artifact_dir="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --evidence)
      evidence_path="${2:-}"
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

if [ -z "$artifact_dir" ] || [ -z "$version" ] || [ -z "$evidence_path" ]; then
  usage
  exit 1
fi

if [ ! -d "$artifact_dir" ]; then
  echo "artifact directory not found: $artifact_dir" >&2
  exit 1
fi

baxter_artifact="$artifact_dir/baxter-darwin-arm64"
baxterd_artifact="$artifact_dir/baxterd-darwin-arm64"
checksums="$artifact_dir/SHA256SUMS"

for file in "$baxter_artifact" "$baxterd_artifact" "$checksums"; do
  if [ ! -f "$file" ]; then
    echo "required artifact file missing: $file" >&2
    exit 1
  fi
done

if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  echo "launchd gui domain unavailable on host; cannot validate artifact install/upgrade/rollback path" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
run_root="$(mktemp -d "${TMPDIR:-/tmp}/baxter-rc-validation.XXXXXX")"
home_dir="$run_root/home"
backup_root="$run_root/backup-root"

mkdir -p "$home_dir" "$backup_root" "$(dirname "$evidence_path")"

export HOME="$home_dir"
export BAXTER_PASSPHRASE="rc-validation-passphrase"
export BAXTER_IPC_TOKEN="rc-validation-current,rc-validation-next"

app_support_dir="$HOME/Library/Application Support/baxter"
bin_dir="$app_support_dir/bin"
baxter_installed="$bin_dir/baxter"
baxterd_installed="$bin_dir/baxterd"

cleanup() {
  (cd "$repo_root" && ./scripts/uninstall-launchd.sh) >/dev/null 2>&1 || true
  rm -rf "$run_root"
}
trap cleanup EXIT

run_logged_step() {
  local title="$1"
  shift

  echo "== $title =="
  {
    printf '## %s\n\n```text\n' "$title"
  } >>"$evidence_path"

  if ! "$@" 2>&1 | tee -a "$evidence_path"; then
    {
      printf '\n```\n\nResult: FAIL\n\n'
    } >>"$evidence_path"
    return 1
  fi

  {
    printf '\n```\n\n'
  } >>"$evidence_path"
}

{
  printf '# RC Artifact Validation Evidence\n\n'
  printf '- Version: `%s`\n' "$version"
  printf '- Date (UTC): `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '- Host: `%s`\n\n' "$(sw_vers -productVersion 2>/dev/null || uname -a)"
} >"$evidence_path"

run_logged_step "Verify artifact checksums" bash -lc "cd '$artifact_dir' && shasum -a 256 -c SHA256SUMS"

mkdir -p "$bin_dir"
install -m 0755 "$baxter_artifact" "$baxter_installed"
install -m 0755 "$baxterd_artifact" "$baxterd_installed"

run_logged_step "Initialize config for first backup" bash -lc "cd '$repo_root' && ./scripts/init-config.sh '$backup_root'"
run_logged_step "Install and start launchd daemon (initial install)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$baxterd_installed' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (initial install)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Run first backup from installed CLI" "$baxter_installed" backup run
run_logged_step "Read backup status from installed CLI" "$baxter_installed" backup status

run_logged_step "Stop daemon before upgrade" bash -lc "cd '$repo_root' && ./scripts/uninstall-launchd.sh"
cp "$baxter_installed" "$bin_dir/baxter.prev"
cp "$baxterd_installed" "$bin_dir/baxterd.prev"
install -m 0755 "$baxter_artifact" "$baxter_installed"
install -m 0755 "$baxterd_artifact" "$baxterd_installed"

run_logged_step "Install and start launchd daemon (upgrade path)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$baxterd_installed' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (post-upgrade)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Read backup status after upgrade" "$baxter_installed" backup status

run_logged_step "Stop daemon before rollback" bash -lc "cd '$repo_root' && ./scripts/uninstall-launchd.sh"
install -m 0755 "$bin_dir/baxter.prev" "$baxter_installed"
install -m 0755 "$bin_dir/baxterd.prev" "$baxterd_installed"

run_logged_step "Install and start launchd daemon (rollback path)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$baxterd_installed' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (post-rollback)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Read backup status after rollback" "$baxter_installed" backup status

{
  printf '## Result\n\n'
  printf 'PASS\n'
} >>"$evidence_path"

echo "RC artifact validation passed. Evidence: $evidence_path"
