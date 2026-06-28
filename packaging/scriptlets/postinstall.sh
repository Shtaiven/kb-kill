#!/bin/sh
# kb-kill post-install (deb/rpm): register units, enable for all users + boot.
# Best-effort: a chroot/container build host may have no running systemd.
set -e

systemctl daemon-reload >/dev/null 2>&1 || true

# push/tray are GLOBAL user units — enable for every user (takes effect at each
# user's next login). The daemon follows the active seat user regardless.
systemctl --global enable kb-kill-push.service kb-kill-tray.service >/dev/null 2>&1 || true

# Refresh the app menu.
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# The root daemon: start now on first install, restart to pick up the new binary
# on upgrade. Skipped silently when systemd isn't running (build host/container).
if systemctl is-system-running >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
  if systemctl is-enabled kb-kill-daemon.service >/dev/null 2>&1; then
    systemctl restart kb-kill-daemon.service >/dev/null 2>&1 || true
  else
    systemctl enable --now kb-kill-daemon.service >/dev/null 2>&1 || true
  fi
fi

exit 0
