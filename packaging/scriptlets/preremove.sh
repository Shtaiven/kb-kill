#!/bin/sh
# kb-kill pre-remove (deb/rpm): stop/disable on real removal, NOT on upgrade.
# Arg conventions differ: deb passes "remove"/"purge"/"upgrade"; rpm passes a
# count ("0" = final removal, "1" = upgrade). Act only on a genuine removal.
set -e

case "${1:-}" in
  remove | purge | 0)
    systemctl disable --now kb-kill-daemon.service >/dev/null 2>&1 || true
    systemctl --global disable kb-kill-push.service kb-kill-tray.service >/dev/null 2>&1 || true
    # --global disable only affects future logins; stop the units in the running
    # sessions of already-logged-in users too, so they don't linger after the
    # binaries are deleted. Best-effort (mirrors postinstall's per-session start).
    if command -v loginctl >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
      for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '$1>=1000{print $1}'); do
        run="/run/user/$uid"
        [ -d "$run" ] || continue
        runuser -u "#$uid" -- env XDG_RUNTIME_DIR="$run" \
          systemctl --user stop kb-kill-push.service kb-kill-tray.service >/dev/null 2>&1 || true
      done
    fi
    ;;
esac

exit 0
