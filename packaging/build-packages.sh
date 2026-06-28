#!/usr/bin/env bash
#
# Build kb-kill .deb and .rpm packages with nfpm.
#
#   packaging/build-packages.sh [VERSION]   # default version: 0.1.0
#
# Output lands in packaging/dist/. Requires `nfpm` on PATH (a single static Go
# binary — https://nfpm.goreleaser.com/install/). No root, no Docker needed.
#
# Why a build step instead of nfpm alone: the systemd units and .desktop files
# in the repo point at /usr/local/* (where install.sh deploys). Packages own
# /usr, not /usr/local, so we stage rewritten copies under packaging/build/ and
# nfpm packages those.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO_DIR"

export KB_KILL_VERSION="${1:-0.1.0}"
BUILD="packaging/build"
DIST="packaging/dist"

if ! command -v nfpm >/dev/null 2>&1; then
  echo "error: nfpm not found on PATH — see https://nfpm.goreleaser.com/install/" >&2
  exit 1
fi

echo "==> Staging path-rewritten units + launchers (/usr/local -> /usr)"
rm -rf "$BUILD"
mkdir -p "$BUILD/services" "$BUILD/desktop" "$DIST"

# /usr/local/bin -> /usr/bin and /usr/local/share -> /usr/share.
for f in services/*.service; do
  sed -e 's#/usr/local/bin#/usr/bin#g' -e 's#/usr/local/share#/usr/share#g' \
    "$f" > "$BUILD/services/$(basename "$f")"
done
for f in desktop/*.desktop; do
  sed -e 's#/usr/local/bin#/usr/bin#g' -e 's#/usr/local/share#/usr/share#g' \
    "$f" > "$BUILD/desktop/$(basename "$f")"
done

echo "==> Building .deb (version $KB_KILL_VERSION)"
nfpm package -f packaging/nfpm.yaml -p deb -t "$DIST"

echo "==> Building .rpm (version $KB_KILL_VERSION)"
nfpm package -f packaging/nfpm.yaml -p rpm -t "$DIST"

echo
echo "Done. Packages in $DIST/:"
ls -1 "$DIST"
