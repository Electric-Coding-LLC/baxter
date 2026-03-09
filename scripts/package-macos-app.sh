#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/package-macos-app.sh --output-dir /path/to/dist [--artifact-name Baxter-darwin-arm64.zip]

Builds Baxter.app in Release configuration, embeds baxter helper binaries,
and packages it as a zip artifact.
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR=""
ARTIFACT_NAME="Baxter-darwin-arm64.zip"
DERIVED_DATA_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --artifact-name)
      ARTIFACT_NAME="${2:-}"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="${2:-}"
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

if [ -z "$OUTPUT_DIR" ]; then
  usage
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "package-macos-app.sh must run on macOS" >&2
  exit 1
fi

if [ -z "$DERIVED_DATA_PATH" ]; then
  DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/baxter-app-package.XXXXXX")"
  CLEAN_DERIVED_DATA=1
else
  mkdir -p "$DERIVED_DATA_PATH"
  CLEAN_DERIVED_DATA=0
fi

cleanup() {
  if [ "${CLEAN_DERIVED_DATA}" = "1" ]; then
    rm -rf "$DERIVED_DATA_PATH"
  fi
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

pushd "$ROOT_DIR" >/dev/null
xcodebuild \
  -project apps/macos/BaxterApp.xcodeproj \
  -scheme BaxterApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build
popd >/dev/null

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Baxter.app"
ZIP_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"
HELPER_DIR="$APP_PATH/Contents/Resources/bin"

if [ ! -d "$APP_PATH" ]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$HELPER_DIR"
pushd "$ROOT_DIR" >/dev/null
GOOS=darwin GOARCH=arm64 go build -o "$HELPER_DIR/baxter" ./cmd/baxter
GOOS=darwin GOARCH=arm64 go build -o "$HELPER_DIR/baxterd" ./cmd/baxterd
popd >/dev/null
chmod 0755 "$HELPER_DIR/baxter" "$HELPER_DIR/baxterd"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Packaged app artifact: $ZIP_PATH"
