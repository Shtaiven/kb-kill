#!/usr/bin/env bash
#
# Assert the installer and every package recipe agree on the payload.
# packaging/nfpm.yaml (deb/rpm, the primary install method) is canonical.
#
#   packaging/check-sync.sh        # exit 1 on any mismatch (run by release.yml)
#
# Checks: every payload file in the tree is packaged and every packaged src
# exists; each package dst has a /usr/local mapping that install.sh installs
# into and uninstall.sh removes from; the PKGBUILD covers each payload area;
# every script carries one VERSION line for bump-version.sh; every unit name
# appears in the scriptlets and the AUR .install; every ExecStart exists.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

fail=0
ok() { printf '  ok        %s\n' "$*"; }
bad() { printf '  MISMATCH  %s\n' "$*"; fail=1; }

# Package dst -> the directory install.sh/uninstall.sh use. Empty = not installed
# by install.sh on purpose (license/doc); "?" = unknown, teach both scripts.
map_local() {
  case "$1" in
    /usr/bin/*) echo /usr/local/bin ;;
    /usr/lib/systemd/system/*) echo /etc/systemd/system ;;
    /usr/lib/systemd/user/*) echo /etc/systemd/user ;;
    /usr/share/applications/*) echo /usr/share/applications ;;
    /usr/share/kb-kill/icons/*) echo /usr/local/share/kb-kill/icons ;;
    /usr/share/icons/hicolor/*) echo /usr/local/share/icons/hicolor/scalable/apps ;;
    /etc/kb-kill/*) echo /etc/kb-kill ;;
    /usr/share/licenses/* | /usr/share/doc/*) echo "" ;;
    *) echo "?" ;;
  esac
}

payload=(); for f in scripts/* services/*.service desktop/*.desktop icons/*.svg kb-kill.toml LICENSE; do [ -f "$f" ] && payload+=("$f"); done
mapfile -t srcs < <(sed -nE 's/^ *- src: *(.*)$/\1/p' packaging/nfpm.yaml | sed 's#^packaging/build/##')
mapfile -t dsts < <(sed -nE 's/^ *dst: *(.*)$/\1/p' packaging/nfpm.yaml)

echo "nfpm.yaml vs tree:"
for f in "${payload[@]}"; do
  if printf '%s\n' "${srcs[@]}" | grep -qx "$f"; then ok "$f"; else bad "nfpm.yaml does not package $f"; fi
done
for s in "${srcs[@]}"; do
  [ -e "$s" ] || bad "nfpm.yaml src missing from the tree: $s"
done

echo "nfpm.yaml vs install.sh / uninstall.sh:"
for d in "${dsts[@]}"; do
  local_dir="$(map_local "$d")"
  [ -z "$local_dir" ] && continue
  if [ "$local_dir" = "?" ]; then bad "no /usr/local mapping for $d"; continue; fi
  if grep -qF "$local_dir" install.sh; then ok "install.sh -> $local_dir ($d)"; else bad "install.sh never installs into $local_dir ($d)"; fi
  grep -qF "$local_dir" uninstall.sh || bad "uninstall.sh never removes from $local_dir ($d)"
done

echo "PKGBUILD:"
for area in 'scripts/*' 'services/*.service' 'desktop/*.desktop' 'icons/*.svg' kb-kill.toml LICENSE; do
  if grep -qF "$area" packaging/aur/PKGBUILD; then ok "PKGBUILD installs $area"; else bad "PKGBUILD does not install $area"; fi
done

echo "scripts:"
for s in scripts/*; do
  [ -f "$s" ] || continue
  if [ "$(grep -cE '^VERSION = "' "$s")" = 1 ]; then ok "$s has one VERSION line"; else bad "$s must have exactly one VERSION line"; fi
done

echo "units:"
for u in services/*.service; do
  n="$(basename "$u")"
  bin="$(sed -nE 's#^ExecStart=/usr/local/bin/([^ ]+).*#\1#p' "$u")"
  if [ -e "scripts/$bin" ]; then ok "$n -> scripts/$bin"; else bad "$n ExecStart points at missing scripts/$bin"; fi
  [[ "$n" == *-daemon.service ]] && continue
  for f in packaging/scriptlets/postinstall.sh packaging/scriptlets/preremove.sh packaging/aur/kb-kill.install; do
    grep -qF "$n" "$f" || bad "$f does not mention $n"
  done
done

if [ "$fail" -eq 0 ]; then
  echo "in sync"
else
  echo "error: installer/packaging out of sync" >&2
  exit 1
fi
