#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh v0.1.0"
  exit 1
fi

if [ "$(uname -s)" = "Darwin" ] && command -v xcodebuild >/dev/null 2>&1; then
  if [ -z "${BAXTER_CODESIGN_IDENTITY:-}" ]; then
    echo "Refusing to package unsigned Baxter.app. Set BAXTER_CODESIGN_IDENTITY or use ./scripts/release-signed.sh." >&2
    exit 1
  fi
fi

DIST_DIR="$ROOT_DIR/dist/$VERSION"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

pushd "$ROOT_DIR" >/dev/null

if [ "${BAXTER_RELEASE_SKIP_TESTS:-0}" != "1" ]; then
  go test ./...
else
  echo "Skipping go test ./... (BAXTER_RELEASE_SKIP_TESTS=1)"
fi

GOOS=darwin GOARCH=arm64 go build -o "$DIST_DIR/baxter-darwin-arm64" ./cmd/baxter
GOOS=darwin GOARCH=arm64 go build -o "$DIST_DIR/baxterd-darwin-arm64" ./cmd/baxterd
GOOS=linux GOARCH=amd64 go build -o "$DIST_DIR/baxter-linux-amd64" ./cmd/baxter
GOOS=linux GOARCH=amd64 go build -o "$DIST_DIR/baxterd-linux-amd64" ./cmd/baxterd

if [ "$(uname -s)" = "Darwin" ] && command -v xcodebuild >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/package-macos-app.sh" --output-dir "$DIST_DIR"
else
  echo "Skipping macOS app packaging (requires macOS with Xcode)."
fi

popd >/dev/null

(cd "$DIST_DIR" && shasum -a 256 * > SHA256SUMS)

echo "Release artifacts created in $DIST_DIR"
ls -1 "$DIST_DIR"
