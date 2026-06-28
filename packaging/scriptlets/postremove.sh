#!/bin/sh
# kb-kill post-remove (deb/rpm): reload systemd so the removed units disappear.
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
exit 0
