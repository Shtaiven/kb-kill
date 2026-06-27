#!/usr/bin/env bash
#
# kb-kill installer — installs the root daemon + the per-user push/tray services.
#
# Run as your normal user; it uses sudo for the root parts:
#   ./install.sh                 # daemon (sudo) + push/tray for ALL users
#   ./install.sh --no-tray       # skip the optional GTK tray (binary, unit, deps)
#   ./install.sh --current-user  # daemon (sudo) + push/tray for the CURRENT user only
#   ./install.sh --user-only     # ONLY push/tray for the current user; reuse an
#                                #   already-installed system daemon; no sudo
#
# Idempotent — re-run it to redeploy after editing the code.
set -euo pipefail

# Run as the normal user, NOT under sudo. Even the system-wide parts that need
# root call sudo themselves, while the script also touches the *current* user's
# session (`systemctl --user`, your ~/.config), which must run as you — under
# `sudo`, `systemctl --user` would target root's bus, not yours. So refuse and
# point at the right command.
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

usage() {
  cat <<EOF
Usage: $(basename "$0") [--no-tray] [--current-user | --user-only]

  --no-tray       skip the optional GTK tray (binary, unit, deps)
  --current-user  set up push/tray for the current user only (~/.config/systemd/user),
                  not globally for all users; daemon still installed system-wide (sudo)
  --user-only     install only the user services (push/tray) for the current user,
                  reusing an already-installed system daemon; no sudo, no system changes
  -h, --help      show this help
EOF
}

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #
# INSTALL_TRAY  : include the optional GTK tray.
# INSTALL_DAEMON: do the system-wide daemon/binaries/config install (needs sudo).
# USER_SCOPE    : where push/tray are enabled — "global" (all users, /etc/systemd/
#                 user) or "user" (current user only, ~/.config/systemd/user).
INSTALL_TRAY=1
INSTALL_DAEMON=1
USER_SCOPE=global
for arg in "$@"; do
  case "$arg" in
    --no-tray) INSTALL_TRAY=0 ;;
    --current-user) USER_SCOPE=user ;;
    --user-only) INSTALL_DAEMON=0; USER_SCOPE=user ;;
    -h | --help) usage; exit 0 ;;
    *) err "Unknown argument: $arg (try --help)"; exit 1 ;;
  esac
done

# The user services to manage, in every mode (tray omitted under --no-tray).
USER_SVCS=(kb-kill-push)
[ "$INSTALL_TRAY" -eq 1 ] && USER_SVCS+=(kb-kill-tray)

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if [ "$INSTALL_DAEMON" -eq 1 ]; then
  # There's no dependency manifest, so probe what the core service must have.
  # The daemon runs as a ROOT system service, so probe ROOT's python3 (the very
  # interpreter it will run under) for Python >= 3.11 (tomllib) and python-evdev.
  # Prime sudo once here so the whole install needs a SINGLE password prompt —
  # every sudo below reuses the cached credential. Distro packages are the
  # supported way to provide these (pip is not; see README).
  say "Checking dependencies (needs sudo — you'll be prompted for your password once)"
  sudo -v

  problems=()
  if dep_report="$(sudo python3 - <<'PY' 2>/dev/null
import sys
out = []
if sys.version_info < (3, 11):
    out.append("kb-kill-daemon needs Python >= 3.11 for tomllib (root python3 is %d.%d)" % sys.version_info[:2])
try:
    import evdev  # noqa: F401
except ImportError:
    out.append("kb-kill-daemon needs python-evdev (Debian/Ubuntu: python3-evdev, Fedora: python3-evdev, Arch: python-evdev)")
print("\n".join(out))
PY
  )"; then
    while IFS= read -r line; do
      [ -n "$line" ] && problems+=("$line")
    done <<< "$dep_report"
  else
    problems+=("python3 is not runnable as root — the daemon cannot start without it")
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    warn "Required daemon dependency check found issue(s):"
    for p in "${problems[@]}"; do printf '       - %s\n' "$p" >&2; done
    warn "Install from your distro's packages (NOT pip) — see README \"Dependencies\"."
    printf '\033[1;33m[warn]\033[0m Continue anyway? [y/N] ' >&2
    read -r reply || reply=""
    case "$reply" in
      [yY] | [yY][eE][sS]) say "Continuing despite the above." ;;
      *) err "Aborted — install the missing dependencies and re-run."; exit 1 ;;
    esac
  fi
else
  # --user-only reuses the already-installed system binaries (no sudo, no daemon
  # install), so verify they're actually there — otherwise the user units would
  # point at nothing. The daemon's own deps (python/evdev) are its concern and
  # were checked when it was installed, so we don't re-probe them here.
  say "User-only install — reusing the system daemon in /usr/local/bin (no sudo)"
  missing=()
  reuse=(kb-kill-daemon kb-kill-push)
  [ "$INSTALL_TRAY" -eq 1 ] && reuse+=(kb-kill-tray)
  for b in "${reuse[@]}"; do
    [ -x "/usr/local/bin/$b" ] || missing+=("/usr/local/bin/$b")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    err "--user-only needs the system install already present, but these are missing:"
    for m in "${missing[@]}"; do printf '       - %s\n' "$m" >&2; done
    err "Run a full install first (without --user-only), or have an admin run it."
    exit 1
  fi
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

# Tray (optional) deps, probed as the user (the tray is a --user service that
# runs under your python3 + your session). Warn-only: the tray is optional, so a
# missing dep never blocks the install — it just won't start until present.
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
    warn "Setting it up anyway; it will fail to start until those are present. Use --no-tray to skip."
  fi
fi

# --------------------------------------------------------------------------- #
# System-wide install (sudo): binaries, icons, daemon unit, default config
# --------------------------------------------------------------------------- #
if [ "$INSTALL_DAEMON" -eq 1 ]; then
  say "Installing kb-kill system-wide (sudo)"

  # Binaries: root-owned copies on the global PATH, so EVERY user can run
  # push/tray (a ~/.local/bin symlink into one user's home is unreadable by
  # others). The daemon stays root-owned for the security model; push/tray run
  # unprivileged.
  sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-daemon" /usr/local/bin/kb-kill-daemon
  sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-push"   /usr/local/bin/kb-kill-push
  if [ "$INSTALL_TRAY" -eq 1 ]; then
    sudo install -D -m0755 -o root -g root "$PROJECT_DIR/scripts/kb-kill-tray" /usr/local/bin/kb-kill-tray
  fi
  # Icons (global; the tray finds them under /usr/local/share for any user, and
  # both app-menu launchers reference them — so install unconditionally).
  sudo install -d -m0755 /usr/local/share/kb-kill/icons
  sudo install -m0644 "$PROJECT_DIR"/icons/*.svg /usr/local/share/kb-kill/icons/

  # The system daemon unit. (It no longer embeds a config path — config is
  # pushed at runtime — so it installs verbatim.)
  sudo install -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-daemon.service" \
    /etc/systemd/system/kb-kill-daemon.service

  # System-wide default config: a fallback for any user without their own
  # ~/.config/kb-kill/kb-kill.toml (push checks the user's home first, then
  # /etc). Installed only if absent, so it never clobbers a customised default.
  sudo install -d -m0755 /etc/kb-kill
  if [ ! -e /etc/kb-kill/kb-kill.toml ]; then
    sudo install -m0644 "$PROJECT_DIR/kb-kill.toml" /etc/kb-kill/kb-kill.toml
    say "Installed system default config -> /etc/kb-kill/kb-kill.toml"
  fi

  # Enable + (re)start the daemon. restart (not enable --now) so a redeploy
  # replaces a running daemon with the fresh binary, clearing any duplicate.
  sudo systemctl daemon-reload
  sudo systemctl enable kb-kill-daemon.service
  sudo systemctl restart kb-kill-daemon.service
  say "kb-kill-daemon: $(systemctl is-active kb-kill-daemon.service)"
fi

# --------------------------------------------------------------------------- #
# User services (push/tray): install + enable, scoped per USER_SCOPE
# --------------------------------------------------------------------------- #
if [ "$USER_SCOPE" = global ]; then
  # GLOBAL user units in /etc/systemd/user so every user's `systemd --user`
  # instance sees push/tray; enabled for ALL users (takes effect at next login).
  sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-push.service" \
    /etc/systemd/user/kb-kill-push.service
  # App-menu launcher for the push pusher, system-wide so every user's menu sees it.
  sudo install -D -m0644 -o root -g root "$PROJECT_DIR/kb-kill-push.desktop" \
    /usr/share/applications/kb-kill-push.desktop
  if [ "$INSTALL_TRAY" -eq 1 ]; then
    sudo install -D -m0644 -o root -g root "$PROJECT_DIR/services/kb-kill-tray.service" \
      /etc/systemd/user/kb-kill-tray.service
    # App-menu launcher for the tray, system-wide so every user's menu sees it.
    sudo install -D -m0644 -o root -g root "$PROJECT_DIR/kb-kill-tray.desktop" \
      /usr/share/applications/kb-kill-tray.desktop
  fi
  sudo update-desktop-database /usr/share/applications 2>/dev/null || true
  sudo systemctl --global enable "${USER_SVCS[@]/%/.service}"
  say "Enabled push/tray for all users (each user's next login)."
else
  # CURRENT-USER units in ~/.config/systemd/user (no sudo). Used by
  # --current-user and --user-only.
  say "Setting up push/tray for $USER_NAME only (~/.config/systemd/user)"
  install -D -m0644 "$PROJECT_DIR/services/kb-kill-push.service" \
    "$USER_HOME/.config/systemd/user/kb-kill-push.service"
  # App-menu launcher for the push pusher, for this user only (no sudo).
  install -D -m0644 "$PROJECT_DIR/kb-kill-push.desktop" \
    "$USER_HOME/.local/share/applications/kb-kill-push.desktop"
  if [ "$INSTALL_TRAY" -eq 1 ]; then
    install -D -m0644 "$PROJECT_DIR/services/kb-kill-tray.service" \
      "$USER_HOME/.config/systemd/user/kb-kill-tray.service"
    # App-menu launcher for the tray, for this user only (no sudo).
    install -D -m0644 "$PROJECT_DIR/kb-kill-tray.desktop" \
      "$USER_HOME/.local/share/applications/kb-kill-tray.desktop"
  fi
  update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable "${USER_SVCS[@]/%/.service}"
  else
    warn "No user session bus here; enable later with: systemctl --user enable ${USER_SVCS[*]/%/.service}"
  fi
fi

# --------------------------------------------------------------------------- #
# Your session ($USER_NAME): a personal config + start the services now
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

# Start the user services in THIS session now (enabling alone only affects new
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
if [ "$USER_SCOPE" = global ]; then
  printf '\nDone — installed system-wide. Other users get push/tray on their next login.\n'
elif [ "$INSTALL_DAEMON" -eq 1 ]; then
  printf '\nDone — daemon installed system-wide; push/tray set up for %s only.\n' "$USER_NAME"
else
  printf '\nDone — push/tray set up for %s only, reusing the existing system daemon.\n' "$USER_NAME"
fi
