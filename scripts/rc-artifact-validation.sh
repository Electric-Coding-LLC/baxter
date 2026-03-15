#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/rc-artifact-validation.sh --artifact-dir /path/to/artifacts --version vX.Y.Z-rcN --evidence /path/to/evidence.md [--summary-json /path/to/summary.json]

Validates RC artifacts through install, first backup, upgrade, and rollback paths.
EOF
}

artifact_dir=""
version=""
evidence_path=""
summary_json_path=""

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
    --summary-json)
      summary_json_path="${2:-}"
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

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
run_root="$(mktemp -d "${TMPDIR:-/tmp}/baxter-rc-validation.XXXXXX")"
home_dir="$run_root/home"
backup_root="$run_root/backup-root"
validation_date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
validation_host="$(sw_vers -productVersion 2>/dev/null || uname -a)"
install_status="pending"
upgrade_status="pending"
rollback_status="pending"
overall_status="pending"
failed_step=""
active_phase=""

mkdir -p "$home_dir" "$backup_root" "$(dirname "$evidence_path")"
if [ -n "$summary_json_path" ]; then
  mkdir -p "$(dirname "$summary_json_path")"
fi

export HOME="$home_dir"
export BAXTER_PASSPHRASE="rc-validation-passphrase"
export BAXTER_IPC_TOKEN="rc-validation-current,rc-validation-next"
export BAXTER_HOME_DIR="$HOME"
export BAXTER_LAUNCHD_LABEL="com.electriccoding.baxterd.rc.$$"
export BAXTER_IPC_ADDR="127.0.0.1:$((43000 + ($$ % 1000)))"
export BAXTER_IPC_URL="http://$BAXTER_IPC_ADDR"

app_support_dir="$HOME/Library/Application Support/baxter"
bin_dir="$app_support_dir/bin"
baxter_installed="$bin_dir/baxter"
baxterd_installed="$bin_dir/baxterd"

cleanup() {
  (cd "$repo_root" && ./scripts/uninstall-launchd.sh) >/dev/null 2>&1 || true
  rm -rf "$run_root"
}

write_summary_json() {
  if [ -z "$summary_json_path" ]; then
    return
  fi

  SUMMARY_JSON_PATH="$summary_json_path" \
  VERSION="$version" \
  VALIDATION_DATE_UTC="$validation_date_utc" \
  VALIDATION_HOST="$validation_host" \
  INSTALL_STATUS="$install_status" \
  UPGRADE_STATUS="$upgrade_status" \
  ROLLBACK_STATUS="$rollback_status" \
  OVERALL_STATUS="$overall_status" \
  FAILED_STEP="$failed_step" \
  python3 <<'PY'
import json
import os
from pathlib import Path

summary = {
    "version": os.environ["VERSION"],
    "validation_date_utc": os.environ["VALIDATION_DATE_UTC"],
    "environment": os.environ["VALIDATION_HOST"],
    "install_and_first_backup": os.environ["INSTALL_STATUS"],
    "upgrade_path": os.environ["UPGRADE_STATUS"],
    "rollback_path": os.environ["ROLLBACK_STATUS"],
    "overall_result": os.environ["OVERALL_STATUS"],
    "failed_step": os.environ["FAILED_STEP"],
}

path = Path(os.environ["SUMMARY_JSON_PATH"])
path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY
}

finalize() {
  status="$1"
  if [ "$overall_status" = "pending" ]; then
    if [ "$status" -eq 0 ]; then
      overall_status="pass"
    else
      overall_status="fail"
    fi
  fi
  write_summary_json
  cleanup
}
trap 'finalize $?' EXIT

run_logged_step() {
  local title="$1"
  shift

  echo "== $title =="
  {
    printf '## %s\n\n```text\n' "$title"
  } >>"$evidence_path"

  if ! "$@" 2>&1 | tee -a "$evidence_path"; then
    failed_step="$title"
    overall_status="fail"
    case "$active_phase" in
      install)
        install_status="fail"
        ;;
      upgrade)
        upgrade_status="fail"
        ;;
      rollback)
        rollback_status="fail"
        ;;
    esac
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
  printf -- '- Version: `%s`\n' "$version"
  printf -- '- Date (UTC): `%s`\n' "$validation_date_utc"
  printf -- '- Host: `%s`\n\n' "$validation_host"
} >"$evidence_path"

run_logged_step "Verify launchd GUI domain availability" launchctl print "gui/$(id -u)"
run_logged_step "Verify artifact checksums" bash -lc "cd '$artifact_dir' && shasum -a 256 -c SHA256SUMS"
chmod 0755 "$baxter_artifact" "$baxterd_artifact"

mkdir -p "$bin_dir"
install -m 0755 "$baxter_artifact" "$baxter_installed"

active_phase="install"
run_logged_step "Initialize config for first backup" bash -lc "cd '$repo_root' && ./scripts/init-config.sh '$backup_root'"
run_logged_step "Install and start launchd daemon (initial install)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$baxterd_artifact' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (initial install)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Run first backup from installed CLI" "$baxter_installed" backup run
run_logged_step "Read backup status from installed CLI" "$baxter_installed" backup status
install_status="pass"

active_phase="upgrade"
run_logged_step "Stop daemon before upgrade" bash -lc "cd '$repo_root' && ./scripts/uninstall-launchd.sh"
cp "$baxter_installed" "$bin_dir/baxter.prev"
cp "$baxterd_installed" "$bin_dir/baxterd.prev"
install -m 0755 "$baxter_artifact" "$baxter_installed"

run_logged_step "Install and start launchd daemon (upgrade path)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$baxterd_artifact' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (post-upgrade)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Read backup status after upgrade" "$baxter_installed" backup status
upgrade_status="pass"

active_phase="rollback"
run_logged_step "Stop daemon before rollback" bash -lc "cd '$repo_root' && ./scripts/uninstall-launchd.sh"
install -m 0755 "$bin_dir/baxter.prev" "$baxter_installed"

run_logged_step "Install and start launchd daemon (rollback path)" bash -lc "cd '$repo_root' && BAXTERD_BINARY_PATH='$bin_dir/baxterd.prev' ./scripts/install-launchd.sh"
run_logged_step "Run launchd IPC smoke check (post-rollback)" bash -lc "cd '$repo_root' && ./scripts/smoke-launchd-ipc.sh"
run_logged_step "Read backup status after rollback" "$baxter_installed" backup status
rollback_status="pass"
overall_status="pass"

{
  printf '## Result\n\n'
  printf 'PASS\n'
} >>"$evidence_path"

echo "RC artifact validation passed. Evidence: $evidence_path"
