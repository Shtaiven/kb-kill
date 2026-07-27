#!/usr/bin/env bash
#
# Keep every version literal in the repo in sync. The VERSION file at the repo
# root is the single source of truth; everything else is rewritten from it.
#
#   packaging/bump-version.sh 0.3.0           # rewrite all locations to 0.3.0
#   packaging/bump-version.sh --patch         # 0.3.0 -> 0.3.1
#   packaging/bump-version.sh --minor         # 0.3.1 -> 0.4.0
#   packaging/bump-version.sh --major         # 0.4.0 -> 1.0.0
#   packaging/bump-version.sh --check         # do all locations match VERSION?
#   packaging/bump-version.sh --check 0.3.0   # ... match 0.3.0? (CI tag check)
#
# Synced locations:
#   VERSION                    the source of truth
#   scripts/kb-kill-daemon     VERSION = "..."   (--version output)
#   scripts/kb-kill-push       VERSION = "..."
#   scripts/kb-kill-tray       VERSION = "..."
#   packaging/aur/PKGBUILD     pkgver=  (pkgrel reset to 1, sha256sums to SKIP)
#
# The release workflow runs `--check "${GITHUB_REF_NAME#v}"` before building,
# so a tag that disagrees with any location fails the release instead of
# shipping mismatched artifacts. README install commands deliberately use
# wildcards instead of version literals so the docs can't rot.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

SCRIPTS=(scripts/kb-kill-daemon scripts/kb-kill-push scripts/kb-kill-tray)
PKGBUILD=packaging/aur/PKGBUILD

die() { echo "error: $*" >&2; exit 1; }

script_ver() { sed -nE 's/^VERSION = "([^"]+)".*$/\1/p' "$1"; }

check() {
  local want="$1" fail=0 loc got
  for loc in VERSION "${SCRIPTS[@]}" "$PKGBUILD"; do
    case "$loc" in
      VERSION)     got="$(tr -d '[:space:]' < VERSION)" ;;
      "$PKGBUILD") got="$(sed -n 's/^pkgver=//p' "$PKGBUILD")" ;;
      *)           got="$(script_ver "$loc")" ;;
    esac
    if [[ "$got" == "$want" ]]; then
      printf '  ok        %-26s %s\n' "$loc" "$got"
    else
      printf '  MISMATCH  %-26s %s (want %s)\n' "$loc" "${got:-<missing>}" "$want"
      fail=1
    fi
  done
  return "$fail"
}

# A leading "v" is accepted anywhere a version is (tags are vX.Y.Z) and
# stripped — the VERSION file and the synced literals never carry it.
if [[ "${1:-}" == "--check" ]]; then
  want="${2:-$(tr -d '[:space:]' < VERSION)}"
  want="${want#v}"
  check "$want" || die "version literals out of sync — run packaging/bump-version.sh $want"
  exit 0
fi

ver="${1:-}"
ver="${ver#v}"
if [[ "$ver" == --major || "$ver" == --minor || "$ver" == --patch ]]; then
  cur="$(tr -d '[:space:]' < VERSION)"
  [[ "$cur" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
    || die "VERSION file holds '$cur', not X.Y.Z — can't auto-bump"
  case "$ver" in
    --major) ver="$((BASH_REMATCH[1] + 1)).0.0" ;;
    --minor) ver="${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0" ;;
    --patch) ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))" ;;
  esac
fi
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "usage: $0 X.Y.Z | --major | --minor | --patch | --check [X.Y.Z]   (got '${ver:-<none>}')"

printf '%s\n' "$ver" > VERSION
for s in "${SCRIPTS[@]}"; do
  [[ "$(grep -cE '^VERSION = "' "$s")" == 1 ]] \
    || die "$s: expected exactly one 'VERSION = \"...\"' line"
  sed -i -E "s/^VERSION = \"[^\"]+\"/VERSION = \"$ver\"/" "$s"
done
# New version -> new upstream tarball: pkgrel restarts at 1 and the checksum is
# stale until `updpkgsums` runs against the published v$ver tag.
sed -i \
  -e "s/^pkgver=.*/pkgver=$ver/" \
  -e "s/^pkgrel=.*/pkgrel=1/" \
  -e "s/^sha256sums=.*/sha256sums=('SKIP')/" \
  "$PKGBUILD"

echo "bumped to $ver:"
check "$ver" || die "internal error: bump left locations out of sync"

cat <<EOF

next steps:
  git commit -am "chore: release $ver"
  git tag "v$ver" && git push origin main "v$ver"   # CI re-checks, builds, attaches .deb/.rpm
  # AUR (after the tag is published):
  #   cd packaging/aur && updpkgsums && makepkg --printsrcinfo > .SRCINFO
EOF
