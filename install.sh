#!/usr/bin/env bash
#
# kb-kill installer: the daemon (system unit) plus the per-user push/tray units.
# Prefer the .deb/.rpm from the releases page; this script is for a git checkout.
#
#   ./install.sh                 # daemon (sudo) + push/tray for ALL users
#   ./install.sh --no-tray       # skip the optional GTK tray
#   ./install.sh --current-user  # daemon (sudo) + push/tray for the current user only
#   ./install.sh --user-only     # ONLY push/tray for the current user; no sudo
#
# Idempotent: re-run it to redeploy after editing the code. The payload is
# derived from scripts/, services/, desktop/ and icons/; packaging/check-sync.sh
# asserts it matches the deb/rpm (packaging/nfpm.yaml).
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  printf '\033[0;31m[error]\033[0m Run as your normal user, not root; the script calls sudo itself.\n' >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG="$HOME/.config/kb-kill/kb-kill.toml"
BIN_DIR=/usr/local/bin
ICON_DIR=/usr/local/share/kb-kill/icons
THEME_ICON_DIR=/usr/local/share/icons/hicolor/scalable/apps

say() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--no-tray] [--current-user | --user-only]

  --no-tray       skip the optional GTK tray (binary, unit, launcher)
  --current-user  enable push/tray for the current user only (~/.config/systemd/user)
  --user-only     only push/tray for the current user; reuse the installed daemon; no sudo
  -h, --help      show this help
USAGE
}

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

# Payload, derived from the tree. "*tray*" files are skipped under --no-tray.
keep() { [ "$INSTALL_TRAY" -eq 1 ] || [[ "$(basename "$1")" != *tray* ]]; }
SCRIPTS=(); for f in "$PROJECT_DIR"/scripts/*; do [ -f "$f" ] && keep "$f" && SCRIPTS+=("$f"); done
USER_UNITS=(); for f in "$PROJECT_DIR"/services/*.service; do
  [[ "$f" == *-daemon.service ]] && continue
  keep "$f" && USER_UNITS+=("$f")
done
LAUNCHERS=(); for f in "$PROJECT_DIR"/desktop/*.desktop; do keep "$f" && LAUNCHERS+=("$f"); done
USER_SVCS=(); for f in "${USER_UNITS[@]}"; do USER_SVCS+=("$(basename "$f")"); done

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if [ "$INSTALL_DAEMON" -eq 1 ]; then
  say "Checking dependencies (needs sudo; one password prompt)"
  sudo -v
  problems=()
  if dep_report="$(sudo python3 - <<'PY' 2>/dev/null
import sys
out = []
if sys.version_info < (3, 11):
    out.append("kb-kill-daemon needs Python >= 3.11 (system python3 is %d.%d)" % sys.version_info[:2])
try:
    import evdev  # noqa: F401
except ImportError:
    out.append("kb-kill-daemon needs python-evdev (python3-evdev on Debian/Ubuntu/Fedora, python-evdev on Arch)")
print("\n".join(out))
PY
  )"; then
    while IFS= read -r line; do [ -n "$line" ] && problems+=("$line"); done <<<"$dep_report"
  else
    problems+=("python3 is not runnable as root")
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    warn "Dependency check found issue(s):"
    for p in "${problems[@]}"; do printf '       - %s\n' "$p" >&2; done
    printf '\033[1;33m[warn]\033[0m Continue anyway? [y/N] ' >&2
    read -r reply || reply=""
    case "$reply" in
      [yY] | [yY][eE][sS]) ;;
      *) err "Aborted."; exit 1 ;;
    esac
  fi
else
  say "User-only install: reusing the daemon in $BIN_DIR (no sudo)"
  for f in "${SCRIPTS[@]}"; do
    [ -x "$BIN_DIR/$(basename "$f")" ] || { err "$BIN_DIR/$(basename "$f") is missing; run a full install first"; exit 1; }
  done
fi

if ! systemctl is-active --quiet systemd-logind 2>/dev/null; then
  warn "systemd-logind is not active: the daemon will run but stay idle (no active seat)."
fi
if [ "$INSTALL_TRAY" -eq 1 ] && ! python3 - <<'PY' 2>/dev/null
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
  warn "kb-kill-tray needs PyGObject + GTK 3 + AppIndicator3; it will not start until they are installed (or use --no-tray)."
fi
if [ "$INSTALL_TRAY" -eq 1 ] && ! python3 - <<'PY' 2>/dev/null
import gi
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import GtkLayerShell  # noqa: F401
PY
then
  say "Tray OSD: GNOME and KDE supply their own; elsewhere install gtk-layer-shell (gir1.2-gtklayershell-0.1 on Debian/Ubuntu)."
fi

# --------------------------------------------------------------------------- #
# System-wide (sudo): binaries, icons, daemon unit, default config
# --------------------------------------------------------------------------- #
if [ "$INSTALL_DAEMON" -eq 1 ]; then
  say "Installing kb-kill system-wide (sudo)"
  # Root-owned copies on the global PATH: a service must never execute a
  # user-writable file, and every user needs to be able to run push/tray.
  for f in "${SCRIPTS[@]}"; do
    sudo install -D -m0755 -o root -g root "$f" "$BIN_DIR/$(basename "$f")"
  done
  sudo install -d -m0755 "$ICON_DIR"
  sudo install -m0644 "$PROJECT_DIR"/icons/*.svg "$ICON_DIR/"
  # Also into the icon theme: the GNOME/KDE on-screen display resolves the icon
  # name inside the shell's own process, which never sees $ICON_DIR.
  sudo install -d -m0755 "$THEME_ICON_DIR"
  sudo install -m0644 "$PROJECT_DIR"/icons/*.svg "$THEME_ICON_DIR/"
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    sudo gtk-update-icon-cache -qtf /usr/local/share/icons/hicolor >/dev/null 2>&1 || true
  for f in "$PROJECT_DIR"/services/*-daemon.service; do
    sudo install -m0644 -o root -g root "$f" "/etc/systemd/system/$(basename "$f")"
  done
  sudo install -d -m0755 /etc/kb-kill
  if [ ! -e /etc/kb-kill/kb-kill.toml ]; then
    sudo install -m0644 "$PROJECT_DIR/kb-kill.toml" /etc/kb-kill/kb-kill.toml
    say "Installed system default config -> /etc/kb-kill/kb-kill.toml"
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable kb-kill-daemon.service
  sudo systemctl restart kb-kill-daemon.service
  say "kb-kill-daemon: $(systemctl is-active kb-kill-daemon.service)"
fi

# --------------------------------------------------------------------------- #
# User units (push/tray): global for every user, or just the current one
# --------------------------------------------------------------------------- #
if [ "$USER_SCOPE" = global ]; then
  for f in "${USER_UNITS[@]}"; do
    sudo install -D -m0644 -o root -g root "$f" "/etc/systemd/user/$(basename "$f")"
  done
  for f in "${LAUNCHERS[@]}"; do
    sudo install -D -m0644 -o root -g root "$f" "/usr/share/applications/$(basename "$f")"
  done
  sudo update-desktop-database /usr/share/applications 2>/dev/null || true
  sudo systemctl --global enable "${USER_SVCS[@]}"
  say "Enabled push/tray for all users (takes effect at each user's next login)."
else
  say "Enabling push/tray for $USER only (~/.config/systemd/user)"
  for f in "${USER_UNITS[@]}"; do
    install -D -m0644 "$f" "$HOME/.config/systemd/user/$(basename "$f")"
  done
  for f in "${LAUNCHERS[@]}"; do
    install -D -m0644 "$f" "$HOME/.local/share/applications/$(basename "$f")"
  done
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable "${USER_SVCS[@]}"
  else
    warn "No user session bus; enable later with: systemctl --user enable ${USER_SVCS[*]}"
  fi
fi

# --------------------------------------------------------------------------- #
# This session: a personal config, and (re)start push/tray now
# --------------------------------------------------------------------------- #
say "Configuring your session"
mkdir -p "$(dirname "$CONFIG")"
if [ ! -e "$CONFIG" ]; then
  cp "$PROJECT_DIR/kb-kill.toml" "$CONFIG"
  say "Installed your config -> $CONFIG"
else
  say "Kept your existing config: $CONFIG"
fi
if systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  for svc in "${USER_SVCS[@]}"; do
    if systemctl --user restart "$svc"; then
      say "$svc: $(systemctl --user is-active "$svc")"
    else
      warn "Failed to (re)start $svc; see: systemctl --user status $svc"
    fi
  done
else
  warn "No user session bus; push/tray start at your next login."
fi

printf '\nDone. Check with: kb-kill-detect   (and: journalctl -u kb-kill-daemon -f)\n'
