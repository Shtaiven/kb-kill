#!/bin/sh
# kb-kill pre-remove (deb/rpm): stop/disable on real removal, NOT on upgrade.
# Arg conventions differ: deb passes "remove"/"purge"/"upgrade"; rpm passes a
# count ("0" = final removal, "1" = upgrade). Act only on a genuine removal.
set -e

case "${1:-}" in
  remove | purge | 0)
    systemctl disable --now kb-kill-daemon.service >/dev/null 2>&1 || true
    systemctl --global disable kb-kill-push.service kb-kill-tray.service >/dev/null 2>&1 || true
    ;;
esac

exit 0
