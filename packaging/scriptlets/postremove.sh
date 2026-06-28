#!/bin/sh
# kb-kill post-remove (deb/rpm): reload systemd so the removed units disappear.
set -e
systemctl daemon-reload >/dev/null 2>&1 || true

# The system `daemon-reload` above doesn't touch users' `systemd --user`
# instances, which still hold the now-removed (or replaced) unit files. Reload
# each logged-in user's manager so the units refresh in their running sessions.
# Best-effort (mirrors postinstall/preremove's per-session handling).
if command -v loginctl >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
  for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '$1>=1000{print $1}'); do
    run="/run/user/$uid"
    [ -d "$run" ] || continue
    runuser -u "#$uid" -- env XDG_RUNTIME_DIR="$run" \
      systemctl --user daemon-reload >/dev/null 2>&1 || true
  done
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
