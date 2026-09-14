# CLAUDE.md

Guidance for Claude Code when working in this repository. Read `README.md` for
the user-facing manual; this file covers what is not obvious from the code.

## What this is

kb-kill disables/enables target input devices (keyboards and pointers) on a
global hotkey. "Disable" is an exclusive `EVIOCGRAB` held only while a group is
killed; awake, devices are only read. No virtual device, no re-injection, so a
crash cannot break input. Config is **pushed**: each user's `kb-kill-push` sends
their TOML to the daemon over a control socket, and the daemon applies only the
config of the user who currently controls the seat (logind `ACTIVE_UID`).

Pure Python + shell + systemd units. No build step, no test suite. The primary
install method is the `.deb`/`.rpm`; `install.sh` is for a git checkout.

## Files

| Path                          | Role                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------- |
| `scripts/kb-kill-daemon`      | the daemon. Runs as a systemd `DynamicUser` with `SupplementaryGroups=input`, not root |
| `scripts/kb-kill-push`        | per-user config pusher (stdlib), mandatory                                             |
| `scripts/kb-kill-tray`        | optional GTK3/AppIndicator tray                                                        |
| `scripts/kb-kill-detect`      | unprivileged socket client: what the daemon matches and grabs                          |
| `scripts/kb-kill-monitor`     | privileged raw key-event viewer + daemon state (`sudo`)                                |
| `services/*.service`          | `*-daemon.service` is the system unit; the others are global user units                |
| `install.sh` / `uninstall.sh` | git-checkout deploy; payload derived from `scripts/ services/ desktop/ icons/`         |
| `packaging/`                  | nfpm (deb/rpm), AUR recipe, `bump-version.sh`, `check-sync.sh`                         |
| `kb-kill.toml`                | shipped default config (inert: no groups)                                              |

## Commands

```sh
kb-kill-detect                    # groups, devices, targets, grabs (as the active user)
sudo kb-kill-monitor [--debug]    # raw key events + daemon state (+ key-rate diagnostics)
journalctl -u kb-kill-daemon -f   # live config, KILLED / AWAKE (rate-limited)
./scripts/kb-kill-daemon -c some.toml   # dev run: pins a file config, socket in $XDG_RUNTIME_DIR
packaging/check-sync.sh           # installer vs deb/rpm vs AUR payload agreement
packaging/bump-version.sh X.Y.Z   # the only way to change version literals
```

Installed binaries are root-owned copies (`/usr/bin` from a package,
`/usr/local/bin` from `install.sh`); editing `scripts/` does nothing until you
rebuild the package or re-run `./install.sh`.

## Invariants (keep these)

- **Journal is attacker-shapeable.** Any local uid may push a config, and the
  journal is readable by group adm/wheel. Nothing may reach the journal at key
  rate (timing alone leaks typing); state lines go through the global
  `STATE_LOG` bucket, config/device lines through `CTRL_LOG`; all text passes
  `_safe()`; group names/labels are charset-checked. Key-rate diagnostics go
  only to a root client that sent `{"cmd":"debug"}`.
- **Edge-triggered combos.** `_toggle_groups` fires on not-held -> held only and
  `_sync_latches` is the single place latches are written. `_release_stale_keys`
  only ever drops keys (re-arms, never fires).
- **Grab deferral.** `_reconcile_grabs` never grabs a device with keys held.
- **A grab never outlives its config; a user switch starts awake.**
  `_install_groups` ungrabs first and takes killed state only from `preserve`.
- **No root.** Everything needs only group `input`. Never suggest adding a
  login user to `input`. Any new syscall/path/capability widens the sandbox in
  `services/kb-kill-daemon.service`; do it deliberately.
- **input-remapper.** `auto` targets the forwarded copy (paired in
  `fronting_map` by phys `input-remapper/<phys>` or the pre-2.2.1 name) and
  leaves hardware whose copy just vanished alone for `FRONTED_GRACE`, because
  input-remapper gives up on a device it cannot grab. Keys input-remapper
  *remaps* leave through its shared output device and are not eaten unless the
  group also targets `"input-remapper keyboard"`.
- **Device identity is path + inode** (`_stale`); rescans are driven by inotify
  on `/dev/input`, the 10 s tick is a backstop. Each fd carries an EVIOCSMASK so
  only EV_KEY/EV_SYN arrive.
- **Vocabulary:** group state is `KILLED` or `AWAKE`, upper-case, everywhere
  (journal, tray title, monitor, detect).

## Packaging

`packaging/nfpm.yaml` is the canonical payload list. Adding a file means: place
it in the right directory, add it to `nfpm.yaml`, run `packaging/check-sync.sh`
(release.yml runs it too). Version literals live in `VERSION` and are copied by
`bump-version.sh`; never edit them by hand.
