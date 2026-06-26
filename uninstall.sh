#!/usr/bin/env bash
#
# kb-kill uninstaller — reverses install.sh.
#
# Run as your normal user; it uses sudo for the root parts:
#   ./uninstall.sh              # remove the system daemon + your user services
#   ./uninstall.sh --user-only  # remove ONLY your user services; leave the shared
#                               #   system daemon in place (no sudo) — mirror of
#                               #   `install.sh --user-only`
#
# It does NOT delete your config or the project files. It only removes what
# install.sh placed (binaries, units, icons) and stops the services.
set -euo pipefail

# Run as the normal user, NOT under sudo. This script stops your push/tray user
# services as you and self-elevates with sudo only for the root daemon parts.
# Under `sudo`, `systemctl --user` would target root's bus, not yours, so the
# tray wouldn't actually be stopped — refuse and point at the right command.
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
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #
# REMOVE_SYSTEM: also remove the system-wide daemon/binaries/icons (needs sudo).
# --user-only clears it, for undoing a `install.sh --user-only` on a machine
# where the shared daemon must stay for other users.
REMOVE_SYSTEM=1
for arg in "$@"; do
  case "$arg" in
    --user-only) REMOVE_SYSTEM=0 ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [--user-only]
  --user-only  remove only your user services (push/tray); leave the shared
               system daemon/binaries in place (no sudo)
EOF
      exit 0
      ;;
    *) err "Unknown argument: $arg (try --help)"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Your session: stop, disable, and remove YOUR push/tray user units
# --------------------------------------------------------------------------- #
# Done in every mode: covers both a --current-user/--user-only install (units in
# ~/.config/systemd/user, enabled with `systemctl --user`) and the session-start
# of a global install. Disabling is what stops them coming back at next login;
# removing the unit files cleans up the per-user install. All best-effort so a
# missing unit / no session bus is not fatal.
say "Stopping and disabling your push/tray user services"
systemctl --user stop    kb-kill-push.service kb-kill-tray.service 2>/dev/null || true
systemctl --user disable kb-kill-push.service kb-kill-tray.service 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/kb-kill-push.service" \
      "$USER_HOME/.config/systemd/user/kb-kill-tray.service"
systemctl --user daemon-reload 2>/dev/null || true

# --------------------------------------------------------------------------- #
# System-wide removal (sudo) — skipped under --user-only
# --------------------------------------------------------------------------- #
if [ "$REMOVE_SYSTEM" -eq 1 ]; then
  say "Removing the system-wide install (sudo)"

  # Disable the global user units for all users, then the system daemon.
  sudo systemctl --global disable kb-kill-push.service kb-kill-tray.service 2>/dev/null || true
  sudo systemctl disable --now kb-kill-daemon.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/kb-kill-daemon.service \
             /etc/systemd/user/kb-kill-push.service /etc/systemd/user/kb-kill-tray.service
  sudo systemctl daemon-reload
  sudo rm -f /usr/local/bin/kb-kill-daemon \
             /usr/local/bin/kb-kill-push /usr/local/bin/kb-kill-tray
  sudo rm -rf /usr/local/share/kb-kill
else
  say "User-only uninstall — left the shared system daemon/binaries in place (no sudo)"
fi

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

# The system-wide default and other users' personal configs are left untouched.
# Only mention removing the /etc default when we actually touched the system
# install — under --user-only it belongs to the admin / other users.
if [ "$REMOVE_SYSTEM" -eq 1 ] && [ -e /etc/kb-kill/kb-kill.toml ]; then
  say "Left the system default config: /etc/kb-kill/kb-kill.toml (remove with: sudo rm -rf /etc/kb-kill)"
fi

if [ "$REMOVE_SYSTEM" -eq 1 ]; then
  printf '\nDone — kb-kill uninstalled. Project files in %s are untouched.\n' "$PROJECT_DIR"
else
  printf '\nDone — your user services removed; shared system daemon left in place.\n'
fi
