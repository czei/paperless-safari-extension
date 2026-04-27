#!/usr/bin/env zsh
# Builds the TypeScript Web Extension bundle and syncs the output into
# extension/Resources/ so Xcode's "Copy Bundle Resources" phase picks it up.
#
# Wired into Xcode as a Run Script build phase that runs BEFORE
# "Copy Bundle Resources" on the Web Extension target. See SETUP.md.
set -euo pipefail

REPO_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

cd "${REPO_ROOT}/web"

# Use pnpm if available; fall back to npm.
if command -v pnpm >/dev/null 2>&1; then
  pnpm install --frozen-lockfile=false
  pnpm run build
else
  npm install --no-audit --no-fund
  npm run build
fi

# Mirror dist/ -> extension/Resources/. Use rsync --delete so removed files
# don't linger in the bundle (which would invalidate the signature).
rsync -a --delete "${REPO_ROOT}/web/dist/" "${REPO_ROOT}/extension/Resources/"

# Copy the static manifest.json from src/ alongside the bundled JS, since
# vite doesn't emit it as an entry.
cp "${REPO_ROOT}/web/src/manifest.json" "${REPO_ROOT}/extension/Resources/manifest.json"

# Copy icon PNGs (rendered from resources/logo/web/svg/square.svg in the
# paperless-ngx repo) into the bundle. Vite doesn't process them. Placed
# at the bundle root rather than icons/ because Xcode's Copy Bundle
# Resources phase flattens group references, breaking subdirectory paths
# in manifest.json.
rm -rf "${REPO_ROOT}/extension/Resources/icons"
cp "${REPO_ROOT}"/web/src/icons/icon-*.png "${REPO_ROOT}/extension/Resources/"
