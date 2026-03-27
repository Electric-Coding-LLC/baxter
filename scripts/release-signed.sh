#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release-signed.sh <version>"
  echo "Example: ./scripts/release-signed.sh v0.4.0-rc1"
  exit 1
fi

export BAXTER_CODESIGN_IDENTITY="Developer ID Application: Electric Coding LLC (NFP7P6ZYW3)"
export BAXTER_NOTARYTOOL_PROFILE="baxter-notary"

"$ROOT_DIR/scripts/release.sh" "$VERSION"
