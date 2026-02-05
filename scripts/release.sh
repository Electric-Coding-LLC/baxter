#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh v0.1.0"
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist/$VERSION"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

pushd "$ROOT_DIR" >/dev/null

go test ./...

GOOS=darwin GOARCH=arm64 go build -o "$DIST_DIR/baxter-darwin-arm64" ./cmd/baxter
GOOS=darwin GOARCH=arm64 go build -o "$DIST_DIR/baxterd-darwin-arm64" ./cmd/baxterd
GOOS=linux GOARCH=amd64 go build -o "$DIST_DIR/baxter-linux-amd64" ./cmd/baxter
GOOS=linux GOARCH=amd64 go build -o "$DIST_DIR/baxterd-linux-amd64" ./cmd/baxterd

popd >/dev/null

(cd "$DIST_DIR" && shasum -a 256 * > SHA256SUMS)

echo "Release artifacts created in $DIST_DIR"
ls -1 "$DIST_DIR"
