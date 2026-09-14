#!/usr/bin/env bash
#
# kb-kill uninstaller: reverses install.sh.
#
#   ./uninstall.sh              # remove the system daemon + your user services
#   ./uninstall.sh --user-only  # remove ONLY your user services (no sudo)
#
# Removes what install.sh placed (binaries, units, icons, launchers) and stops
# the services. Never deletes a config without asking.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  printf '\033[0;31m[error]\033[0m Run as your normal user, not root; the script calls sudo itself.\n' >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG="$HOME/.config/kb-kill/kb-kill.toml"
BIN_DIR=/usr/local/bin

say() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

REMOVE_SYSTEM=1
for arg in "$@"; do
  case "$arg" in
    --user-only) REMOVE_SYSTEM=0 ;;
    -h | --help)
      echo "Usage: $(basename "$0") [--user-only]"
      exit 0
      ;;
    *) err "Unknown argument: $arg (try --help)"; exit 1 ;;
  esac
done

# Same payload derivation as install.sh (plus launchers older versions shipped).
USER_SVCS=(); for f in "$PROJECT_DIR"/services/*.service; do
  [[ "$f" == *-daemon.service ]] || USER_SVCS+=("$(basename "$f")")
done
LAUNCHERS=(kb-kill-push.desktop); for f in "$PROJECT_DIR"/desktop/*.desktop; do LAUNCHERS+=("$(basename "$f")"); done
BINS=(); for f in "$PROJECT_DIR"/scripts/*; do [ -f "$f" ] && BINS+=("$(basename "$f")"); done

say "Stopping and disabling your push/tray user services"
systemctl --user stop "${USER_SVCS[@]}" 2>/dev/null || true
systemctl --user disable "${USER_SVCS[@]}" 2>/dev/null || true
for u in "${USER_SVCS[@]}"; do rm -f "$HOME/.config/systemd/user/$u"; done
for d in "${LAUNCHERS[@]}"; do rm -f "$HOME/.local/share/applications/$d"; done
systemctl --user daemon-reload 2>/dev/null || true
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

if [ "$REMOVE_SYSTEM" -eq 1 ]; then
  say "Removing the system-wide install (sudo)"
  sudo systemctl --global disable "${USER_SVCS[@]}" 2>/dev/null || true
  sudo systemctl disable --now kb-kill-daemon.service 2>/dev/null || true
  for u in "${USER_SVCS[@]}"; do sudo rm -f "/etc/systemd/user/$u"; done
  sudo rm -f /etc/systemd/system/kb-kill-daemon.service
  sudo systemctl daemon-reload
  for b in "${BINS[@]}"; do sudo rm -f "$BIN_DIR/$b"; done
  sudo rm -rf /usr/local/share/kb-kill/icons /usr/local/share/kb-kill
  for d in "${LAUNCHERS[@]}"; do sudo rm -f "/usr/share/applications/$d"; done
  sudo update-desktop-database /usr/share/applications 2>/dev/null || true
else
  say "User-only uninstall: the shared daemon stays in place"
fi

if [ -L "$CONFIG" ]; then
  say "Left your config in place (symlink): $CONFIG"
elif [ -e "$CONFIG" ]; then
  printf 'Also remove your config %s? [y/N] ' "$CONFIG"
  read -r reply
  if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    rm -f "$CONFIG" && say "Removed config."
  else
    say "Kept config: $CONFIG"
  fi
fi
if [ "$REMOVE_SYSTEM" -eq 1 ] && [ -e /etc/kb-kill/kb-kill.toml ]; then
  say "Left the system default config: /etc/kb-kill/kb-kill.toml (sudo rm -rf /etc/kb-kill to remove)"
fi
printf '\nDone.\n'
