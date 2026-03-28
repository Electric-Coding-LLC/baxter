#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/package-macos-app.sh --output-dir /path/to/dist [options]

Builds Baxter.app in Release configuration, embeds baxter helper binaries,
codesigns the app bundle, and packages it as a zip artifact.

Options:
  --artifact-name NAME            Zip file name (default: Baxter-darwin-arm64.zip)
  --derived-data-path PATH        Reuse an existing Xcode DerivedData path
  --signing-identity NAME         Required Developer ID Application identity for codesign
  --notarytool-profile PROFILE    Keychain profile name for xcrun notarytool

Environment:
  BAXTER_CODESIGN_IDENTITY        Required default signing identity if flag is omitted
  BAXTER_NOTARYTOOL_PROFILE       Default notarytool profile if flag is omitted
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR=""
ARTIFACT_NAME="Baxter-darwin-arm64.zip"
DERIVED_DATA_PATH=""
SIGNING_IDENTITY="${BAXTER_CODESIGN_IDENTITY:-}"
NOTARYTOOL_PROFILE="${BAXTER_NOTARYTOOL_PROFILE:-}"

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
    --signing-identity)
      SIGNING_IDENTITY="${2:-}"
      shift 2
      ;;
    --notarytool-profile)
      NOTARYTOOL_PROFILE="${2:-}"
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

create_zip() {
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
}

if [ -z "$SIGNING_IDENTITY" ]; then
  echo "Baxter.app packaging requires --signing-identity (or BAXTER_CODESIGN_IDENTITY)." >&2
  echo "Use the Xcode project for debug runs, or build a signed packaged app for installation." >&2
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
APP_LAUNCH_AGENTS_DIR="$APP_PATH/Contents/Library/LaunchAgents"

if [ ! -d "$APP_PATH" ]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$HELPER_DIR"
mkdir -p "$APP_LAUNCH_AGENTS_DIR"
pushd "$ROOT_DIR" >/dev/null
GOOS=darwin GOARCH=arm64 go build -o "$HELPER_DIR/baxter" ./cmd/baxter
GOOS=darwin GOARCH=arm64 go build -o "$HELPER_DIR/baxterd" ./cmd/baxterd
popd >/dev/null
cp "$ROOT_DIR/launchd/baxterd-launch.sh" "$HELPER_DIR/baxterd-launch.sh"
cp "$ROOT_DIR/launchd/com.electriccoding.baxterd.bundle.plist" \
  "$APP_LAUNCH_AGENTS_DIR/com.electriccoding.baxterd.plist"
chmod 0755 "$HELPER_DIR/baxter" "$HELPER_DIR/baxterd" "$HELPER_DIR/baxterd-launch.sh"

require_command codesign

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$SIGNING_IDENTITY" \
  "$HELPER_DIR/baxter"
codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$SIGNING_IDENTITY" \
  "$HELPER_DIR/baxterd"
codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

create_zip

if [ -n "$NOTARYTOOL_PROFILE" ]; then
  require_command xcrun

  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
  create_zip
fi

echo "Packaged app artifact: $ZIP_PATH"
