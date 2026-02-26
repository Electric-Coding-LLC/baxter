#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_SWIFT_TARGETS=(
  "$ROOT_DIR/apps/macos/BaxterApp"
  "$ROOT_DIR/apps/macos/BaxterAppTests"
)
CHANGED_ONLY=0
RESOLVED_TARGETS=()

install_hint() {
  echo "Install required tools with: brew bundle --file \"$ROOT_DIR/Brewfile\" --no-upgrade" >&2
  echo "Upgrade to latest tools with: brew bundle --file \"$ROOT_DIR/Brewfile\" --upgrade" >&2
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    install_hint
    exit 1
  fi
}

collect_changed_swift_files() {
  (
    cd "$ROOT_DIR"
    {
      git diff --name-only --diff-filter=ACMR HEAD
      git diff --name-only --diff-filter=ACMR --cached
      git ls-files --others --exclude-standard
    } \
      | sort -u \
      | grep -E '^apps/macos/(BaxterApp|BaxterAppTests)/.*\.swift$' || true
  )
}

resolve_targets() {
  RESOLVED_TARGETS=()
  if [ "$CHANGED_ONLY" -eq 0 ]; then
    RESOLVED_TARGETS=("${ALL_SWIFT_TARGETS[@]}")
    return 0
  fi

  local changed_files=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    changed_files+=("$ROOT_DIR/$file")
  done < <(collect_changed_swift_files)

  if [ "${#changed_files[@]}" -eq 0 ]; then
    echo "No changed Swift files found in apps/macos/BaxterApp or apps/macos/BaxterAppTests."
    return 1
  fi

  RESOLVED_TARGETS=("${changed_files[@]}")
}

ensure_tools_installed() {
  require_tool swiftlint
  require_tool swiftformat
}

run_lint_check() {
  ensure_tools_installed
  if ! resolve_targets; then
    return 0
  fi

  if [ "$CHANGED_ONLY" -eq 0 ]; then
    (
      cd "$ROOT_DIR"
      swiftlint lint --config "$ROOT_DIR/.swiftlint.yml"
    )
    return 0
  fi

  local count="${#RESOLVED_TARGETS[@]}"
  local i
  export SCRIPT_INPUT_FILE_COUNT="$count"
  for (( i = 0; i < count; i++ )); do
    export "SCRIPT_INPUT_FILE_${i}=${RESOLVED_TARGETS[$i]}"
  done
  (
    cd "$ROOT_DIR"
    swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --use-script-input-files
  )
}

run_format_check() {
  ensure_tools_installed
  if ! resolve_targets; then
    return 0
  fi
  swiftformat --lint "${RESOLVED_TARGETS[@]}" --config "$ROOT_DIR/.swiftformat"
}

run_format_apply() {
  ensure_tools_installed
  if ! resolve_targets; then
    return 0
  fi
  swiftformat "${RESOLVED_TARGETS[@]}" --config "$ROOT_DIR/.swiftformat"
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/swift-style.sh lint-check [--changed]
  ./scripts/swift-style.sh format-check [--changed]
  ./scripts/swift-style.sh format-apply [--changed]
USAGE
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

if [ "$#" -eq 2 ]; then
  if [ "$2" != "--changed" ]; then
    usage
    exit 1
  fi
  CHANGED_ONLY=1
fi

case "$1" in
  lint-check)
    run_lint_check
    ;;
  format-check)
    run_format_check
    ;;
  format-apply)
    run_format_apply
    ;;
  *)
    usage
    exit 1
    ;;
esac
