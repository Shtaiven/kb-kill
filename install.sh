#!/usr/bin/env bash
#
# kb-kill installer — sets up the root daemon + the user tray.
#
# Run as your normal user; it uses sudo for the root parts:
#   ./install.sh
#
# Idempotent — re-run it to redeploy after editing the daemon code.
set -euo pipefail

# Run as the normal user, NOT under sudo. This script does the user-side setup
# (symlinks in ~/.local/bin, config in ~/.config, the tray *user* service) as you
# and self-elevates with sudo only for the root daemon parts. Under `sudo`, those
# user files would be created root-owned in your home and `systemctl --user`
# would target root's bus, not yours — so refuse and point at the right command.
if [ "$(id -u)" -eq 0 ]; then
  printf '\033[0;31m[error]\033[0m Do not run this installer as root / with sudo.\n' >&2
  if [ -n "${SUDO_USER:-}" ]; then
    printf '  Run it as your normal user; it calls sudo itself when needed:\n' >&2
    printf '      ./install.sh\n' >&2
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
# User side (no root)
# --------------------------------------------------------------------------- #
say "Installing user-side components for $USER_NAME"

mkdir -p "$USER_HOME/.local/bin"
# The daemon isn't symlinked here: the root install puts it at
# /usr/local/bin/kb-kill-daemon (already on PATH), so `sudo kb-kill-daemon detect`
# finds it. Remove any stale links a previous installer left, which would shadow it.
rm -f "$USER_HOME/.local/bin/kb-kill" "$USER_HOME/.local/bin/kb-kill-daemon"
# -n (no-dereference): replace an existing symlink itself rather than following
# it (e.g. an old link pointing at the project dir).
# kb-kill-push (mandatory): feeds the daemon this user's config.
ln -sfn "$PROJECT_DIR/scripts/kb-kill-push" "$USER_HOME/.local/bin/kb-kill-push"
# kb-kill-tray (optional UI).
ln -sfn "$PROJECT_DIR/scripts/kb-kill-tray" "$USER_HOME/.local/bin/kb-kill-tray"

# Config: install the example only if absent; otherwise ask before overwriting.
mkdir -p "$USER_HOME/.config/kb-kill"
if [ ! -e "$CONFIG" ]; then
  cp "$PROJECT_DIR/kb-kill.toml" "$CONFIG"
  say "Installed default config -> $CONFIG"
else
  printf 'kb-kill.toml already exists at %s. Overwrite? [y/N] ' "$CONFIG"
  read -r reply
  if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    if [ -L "$CONFIG" ]; then
      warn "Overwriting a symlink detaches it from your dotfiles (stow)."
    fi
    cp "$PROJECT_DIR/kb-kill.toml" "$CONFIG"
    say "Overwrote config -> $CONFIG"
  else
    say "Kept existing config."
  fi
fi

# User services: kb-kill-push (mandatory — pushes config) + kb-kill-tray (optional UI).
mkdir -p "$USER_HOME/.config/systemd/user"
ln -sfn "$PROJECT_DIR/services/kb-kill-push.service" \
        "$USER_HOME/.config/systemd/user/kb-kill-push.service"
ln -sfn "$PROJECT_DIR/services/kb-kill-tray.service" \
        "$USER_HOME/.config/systemd/user/kb-kill-tray.service"
systemctl --user daemon-reload 2>/dev/null || true
# enable (on boot) + restart so a redeploy actually picks up new code / repointed
# symlinks (enable --now would NOT restart an already-running unit).
for svc in kb-kill-push kb-kill-tray; do
  systemctl --user enable "$svc.service" 2>/dev/null || true
  systemctl --user restart "$svc.service" 2>/dev/null \
    || warn "Could not start $svc (no user session bus here?). Start later: systemctl --user enable --now $svc"
done

# --------------------------------------------------------------------------- #
# Root side (sudo): daemon binary, icons, hardened system unit
# --------------------------------------------------------------------------- #
say "Installing the root daemon (sudo)"

# Migration: stop + remove the pre-rename daemon (kb-kill.service / kb-kill) so we
# don't end up with two grabbers fighting over the keyboard.
sudo systemctl disable --now kb-kill.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/kb-kill.service /usr/local/bin/kb-kill

sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-daemon" /usr/local/bin/kb-kill-daemon
sudo install -d -m0755 /usr/local/share/kb-kill/icons
sudo install -m0644 "$PROJECT_DIR"/icons/*.svg /usr/local/share/kb-kill/icons/

# The system unit no longer embeds a config path (config is pushed at runtime),
# so it installs verbatim.
sudo install -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-daemon.service" \
  /etc/systemd/system/kb-kill-daemon.service

# Replace any old per-user kb-kill daemon unit to avoid two grabbers (and clean up
# the stale unit symlink left by a previous stow-managed install).
systemctl --user disable --now kb-kill.service 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/kb-kill.service"
systemctl --user daemon-reload 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable kb-kill-daemon.service
# restart (not just enable --now) so a redeploy replaces a running daemon with the
# freshly-installed binary, and any duplicate process is cleared with the cgroup.
sudo systemctl restart kb-kill-daemon.service
say "kb-kill system service: $(systemctl is-active kb-kill-daemon.service)"

# --------------------------------------------------------------------------- #
# Follow-ups
# --------------------------------------------------------------------------- #
cat <<EOF

Done. Two manual follow-ups for the full security benefit:

  1) Remove yourself from the 'input' group so no ordinary user process can read
     keyboards anymore (only the sandboxed root daemon):
         sudo gpasswd -d $USER_NAME input
     Then log out and back in. (Verify nothing else you use needs it first.)

  2) After editing the daemon code, re-run this installer to redeploy:
         sudo true && $PROJECT_DIR/install.sh

Note: 'kb-kill-daemon detect' / 'monitor' now need sudo (you've left the input group).
EOF
