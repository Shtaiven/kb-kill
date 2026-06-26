#!/usr/bin/env bash
#
# kb-kill installer — system-wide install of the root daemon + the per-user
# push/tray services (available to every user on the machine).
#
# Run as your normal user; it uses sudo for the root parts:
#   ./install.sh            # daemon + push + tray
#   ./install.sh --no-tray  # skip the optional GTK tray (binary, unit, deps)
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
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #
INSTALL_TRAY=1
for arg in "$@"; do
  case "$arg" in
    --no-tray) INSTALL_TRAY=0 ;;
    -h | --help)
      printf 'Usage: %s [--no-tray]\n  --no-tray  skip the optional GTK tray (binary, unit, deps)\n' \
        "$(basename "$0")"
      exit 0
      ;;
    *) err "Unknown argument: $arg (try --help)"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Preflight: required daemon dependency
# --------------------------------------------------------------------------- #
# There's no dependency manifest, so probe the one thing the core service must
# have: Python >= 3.11 (tomllib). The optional tray's deps are checked later,
# right before the tray install (skipped entirely under --no-tray). Nothing is
# auto-installed — see README "Dependencies".
say "Checking dependencies"
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  warn "kb-kill-daemon needs Python >= 3.11 for tomllib (found: $(python3 -V 2>&1 || echo 'no python3'))"
  warn "See README \"Dependencies\" for the install command for your distro."
  printf '\033[1;33m[warn]\033[0m Continue anyway? [y/N] ' >&2
  read -r reply || reply=""
  case "$reply" in
    [yY] | [yY][eE][sS]) say "Continuing despite the above." ;;
    *) err "Aborted — install the missing dependencies and re-run."; exit 1 ;;
  esac
fi

# logind (required at runtime, warn-only): the daemon follows the active seat
# user via /run/systemd/seats/* (ACTIVE_UID). Without an active seat it runs but
# stays idle and never grabs the keyboard — so warn now rather than let that be
# a silent non-functional install. Not a hard failure: a headless redeploy is
# legitimate, and a seat can appear later at login.
if ! systemctl is-active --quiet systemd-logind 2>/dev/null; then
  warn "systemd-logind is not active — the daemon will run but never kill (no active seat). See README."
elif [ -z "$(ls -A /run/systemd/seats 2>/dev/null)" ]; then
  warn "No seats in /run/systemd/seats (likely headless) — the daemon will stay idle until a seat is active."
fi

# --------------------------------------------------------------------------- #
# System-wide install (sudo): binaries, icons, units, default config
# --------------------------------------------------------------------------- #
say "Installing kb-kill system-wide (sudo)"

# Binaries: root-owned copies on the global PATH, so EVERY user can run push/tray
# (a ~/.local/bin symlink into one user's home is unreadable by others). The
# daemon stays root-owned for the security model; push/tray run unprivileged.
sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-daemon" /usr/local/bin/kb-kill-daemon
sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-push"   /usr/local/bin/kb-kill-push

# Tray (optional): probe its deps and warn before installing it. The tray is
# optional, so a missing dep is a warning only (the daemon/push still work) —
# unlike the required daemon check above, it doesn't prompt. Skipped under
# --no-tray, which omits the tray binary, unit, and session start entirely.
if [ "$INSTALL_TRAY" -eq 1 ]; then
  if ! python3 - <<'PY' 2>/dev/null
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: F401
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3  # noqa: F401
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3  # noqa: F401
PY
  then
    warn "kb-kill-tray needs PyGObject + GTK 3 + AppIndicator3 (Ayatana or legacy) — see README."
    warn "Installing it anyway; it will fail to start until those are present. Use --no-tray to skip."
  fi
  sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-tray" /usr/local/bin/kb-kill-tray

  # Icons (global; the tray finds them under /usr/local/share for any user).
  sudo install -d -m0755 /usr/local/share/kb-kill/icons
  sudo install -m0644 "$PROJECT_DIR"/icons/*.svg /usr/local/share/kb-kill/icons/
else
  say "Skipping tray (--no-tray)"
fi

# Units: the system daemon, plus GLOBAL user units in /etc/systemd/user so every
# user's `systemd --user` instance sees push/tray. (The unit no longer embeds a
# config path — config is pushed at runtime — so it installs verbatim.)
sudo install -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-daemon.service" \
  /etc/systemd/system/kb-kill-daemon.service
sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-push.service" \
  /etc/systemd/user/kb-kill-push.service
if [ "$INSTALL_TRAY" -eq 1 ]; then
  sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-tray.service" \
    /etc/systemd/user/kb-kill-tray.service
fi

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
say "kb-kill-daemon: $(systemctl is-active kb-kill-daemon.service)"

# Enable the user services for ALL users; takes effect on each user's next login.
# (Tray omitted under --no-tray.)
USER_SVCS=(kb-kill-push)
[ "$INSTALL_TRAY" -eq 1 ] && USER_SVCS+=(kb-kill-tray)
sudo systemctl --global enable "${USER_SVCS[@]/%/.service}"

# --------------------------------------------------------------------------- #
# Your session ($USER_NAME): start now + a personal config you can edit
# --------------------------------------------------------------------------- #
say "Configuring your session"

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
  for svc in "${USER_SVCS[@]}"; do
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
EOF
