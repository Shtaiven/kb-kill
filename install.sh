#!/usr/bin/env bash
#
# kb-kill installer — system-wide install of the root daemon + the per-user
# push/tray services (available to every user on the machine).
#
# Run as your normal user; it uses sudo for the root parts:
#   ./install.sh
#
# Idempotent — re-run it to redeploy after editing the code.
set -euo pipefail

# Run as the normal user, NOT under sudo. Almost everything is installed system-
# wide (sudo), but the script also touches the *current* user's session
# (`systemctl --user`, your ~/.config), which must run as you — under `sudo`,
# `systemctl --user` would target root's bus, not yours. So refuse and point at
# the right command.
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
# System-wide install (sudo): binaries, icons, units, default config
# --------------------------------------------------------------------------- #
say "Installing kb-kill system-wide (sudo)"

# Migration: stop + remove the pre-rename daemon (kb-kill.service / kb-kill) so we
# don't end up with two grabbers fighting over the keyboard.
sudo systemctl disable --now kb-kill.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/kb-kill.service /usr/local/bin/kb-kill

# Binaries: root-owned copies on the global PATH, so EVERY user can run push/tray
# (a ~/.local/bin symlink into one user's home is unreadable by others). The
# daemon stays root-owned for the security model; push/tray run unprivileged.
sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-daemon" /usr/local/bin/kb-kill-daemon
sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-push"   /usr/local/bin/kb-kill-push
sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-tray"   /usr/local/bin/kb-kill-tray

# Icons (global; the tray finds them under /usr/local/share for any user).
sudo install -d -m0755 /usr/local/share/kb-kill/icons
sudo install -m0644 "$PROJECT_DIR"/icons/*.svg /usr/local/share/kb-kill/icons/

# Units: the system daemon, plus GLOBAL user units in /etc/systemd/user so every
# user's `systemd --user` instance sees push/tray. (The unit no longer embeds a
# config path — config is pushed at runtime — so it installs verbatim.)
sudo install -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-daemon.service" \
  /etc/systemd/system/kb-kill-daemon.service
sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-push.service" \
  /etc/systemd/user/kb-kill-push.service
sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-tray.service" \
  /etc/systemd/user/kb-kill-tray.service

# System-wide default config: a fallback for any user without their own
# ~/.config/kb-kill/kb-kill.toml (the push search checks the user's home first,
# then /etc). Installed only if absent, so it never clobbers a customised default.
sudo install -d -m0755 /etc/kb-kill
if [ ! -e /etc/kb-kill/kb-kill.toml ]; then
  sudo install -m0644 "$PROJECT_DIR/kb-kill.toml" /etc/kb-kill/kb-kill.toml
  say "Installed system default config -> /etc/kb-kill/kb-kill.toml"
fi

# Enable + (re)start the system daemon. restart (not enable --now) so a redeploy
# replaces a running daemon with the fresh binary, clearing any duplicate process.
sudo systemctl daemon-reload
sudo systemctl enable kb-kill-daemon.service
sudo systemctl restart kb-kill-daemon.service
say "kb-kill system service: $(systemctl is-active kb-kill-daemon.service)"

# Enable the user services for ALL users; takes effect on each user's next login.
sudo systemctl --global enable kb-kill-push.service kb-kill-tray.service

# --------------------------------------------------------------------------- #
# Your session ($USER_NAME): start now + a personal config you can edit
# --------------------------------------------------------------------------- #
say "Configuring your session"

# Migration: drop the old per-user install (symlinks + ~/.config user units) from
# before kb-kill went system-wide, so they don't shadow the global copies.
rm -f "$USER_HOME/.local/bin/kb-kill" "$USER_HOME/.local/bin/kb-kill-daemon" \
      "$USER_HOME/.local/bin/kb-kill-push" "$USER_HOME/.local/bin/kb-kill-tray"
for u in kb-kill kb-kill-push kb-kill-tray; do
  systemctl --user disable "$u.service" 2>/dev/null || true
  rm -f "$USER_HOME/.config/systemd/user/$u.service"
done

# A personal config you can edit without sudo (overrides the /etc default). Other
# users get the /etc default until they create their own here.
mkdir -p "$USER_HOME/.config/kb-kill"
if [ ! -e "$CONFIG" ]; then
  cp "$PROJECT_DIR/kb-kill.toml" "$CONFIG"
  say "Installed your config -> $CONFIG"
else
  say "Kept your existing config: $CONFIG"
fi

# Start the user services in THIS session now (--global enable only affects new
# logins). restart so a redeploy picks up the freshly-installed binaries. Errors
# are shown (not swallowed) and the resulting state is reported, so a failed
# restart is never silent.
if systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  for svc in kb-kill-push kb-kill-tray; do
    if systemctl --user restart "$svc.service"; then
      say "$svc: $(systemctl --user is-active "$svc.service")"
    else
      warn "Failed to (re)start $svc — see: systemctl --user status $svc"
    fi
  done
else
  warn "No user session bus here; push/tray will start on your next login."
fi

# --------------------------------------------------------------------------- #
# Follow-ups
# --------------------------------------------------------------------------- #
cat <<EOF

Done — installed system-wide. Other users get push/tray on their next login.

Manual follow-ups for the full security benefit:

  1) Remove yourself from the 'input' group so no ordinary user process can read
     keyboards anymore (only the sandboxed root daemon):
         sudo gpasswd -d $USER_NAME input
     Then log out and back in. (Verify nothing else you use needs it first.)

  2) After editing the code, re-run this installer to redeploy:
         sudo true && $PROJECT_DIR/install.sh

Note: 'kb-kill-daemon detect' / 'monitor' now need sudo (you've left the input group).
EOF
