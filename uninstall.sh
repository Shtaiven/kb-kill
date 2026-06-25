#!/usr/bin/env bash
#
# kb-kill uninstaller — reverses install.sh.
#
# Run as your normal user; it uses sudo for the root parts:
#   ./uninstall.sh
#
# It does NOT delete your config or the project files. It only removes what
# install.sh placed (binaries, units, icons) and stops the services.
set -euo pipefail

# Run as the normal user, NOT under sudo. This script does the user-side teardown
# (your ~/.local/bin symlinks, the tray *user* service) as you and self-elevates
# with sudo only for the root daemon parts. Under `sudo`, `systemctl --user`
# would target root's bus, not yours, so the tray wouldn't actually be stopped —
# refuse and point at the right command.
if [ "$(id -u)" -eq 0 ]; then
  printf '\033[0;31m[error]\033[0m Do not run this uninstaller as root / with sudo.\n' >&2
  if [ -n "${SUDO_USER:-}" ]; then
    printf '  Run it as your normal user; it calls sudo itself when needed:\n' >&2
    printf '      ./uninstall.sh\n' >&2
  fi
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
CONFIG="$USER_HOME/.config/kb-kill/kb-kill.toml"

say()  { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# --------------------------------------------------------------------------- #
# User side
# --------------------------------------------------------------------------- #
say "Removing user-side components for $USER_NAME"

systemctl --user disable --now kb-kill-tray.service 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/kb-kill-tray.service"
# also clear any stale old per-user daemon unit symlink
systemctl --user disable --now kb-kill.service 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/kb-kill.service"
systemctl --user daemon-reload 2>/dev/null || true

for b in kb-kill kb-kill-tray; do
  link="$USER_HOME/.local/bin/$b"
  [ -L "$link" ] && rm -f "$link" && say "Removed ~/.local/bin/$b"
done

# --------------------------------------------------------------------------- #
# Root side (sudo): stop + remove the daemon, unit, icons
# --------------------------------------------------------------------------- #
say "Removing the root daemon (sudo)"

sudo systemctl disable --now kb-kill.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/kb-kill.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/kb-kill
sudo rm -rf /usr/local/share/kb-kill

# --------------------------------------------------------------------------- #
# Config — never delete silently
# --------------------------------------------------------------------------- #
if [ -L "$CONFIG" ]; then
  say "Left your config in place (stow/dotfiles symlink): $CONFIG"
elif [ -e "$CONFIG" ]; then
  printf 'Also remove your config %s? [y/N] ' "$CONFIG"
  read -r reply
  if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    rm -f "$CONFIG"
    say "Removed config."
  else
    say "Kept config: $CONFIG"
  fi
fi

cat <<EOF

Done — kb-kill uninstalled. Project files in $PROJECT_DIR are untouched.

If you had removed yourself from the 'input' group for kb-kill and want device
access back (e.g. for other tools):
    sudo gpasswd -a $USER_NAME input        # then log out and back in
EOF
