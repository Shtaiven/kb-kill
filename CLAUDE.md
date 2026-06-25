# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

kb-kill disables/enables a target keyboard (e.g. a laptop's built-in keyboard) on a
global hotkey, as a hardened root systemd daemon. "Disable" = an exclusive
`EVIOCGRAB` on the device so the kernel routes its events only to kb-kill, which drops
them. There is **no virtual device and no event re-injection**: kb-kill grabs *only
while killed*; when awake it merely monitors (reads, never grabs), so a crash can never
break your keyboard, and the kernel auto-releases grabs if the process dies.

**Config is pushed, not read from a path (pure-push model).** The daemon starts
config-less and is *told* what to do over its control socket, like input-remapper's
daemon. Each logged-in user runs `kb-kill-push`, which sends that user's config (TOML
text) to the daemon. The daemon honours only the config of whoever currently controls
the seat — logind's `ACTIVE_UID`, graphical **or** TTY — and swaps when the active user
switches. So it always follows the person actually at the machine, with no per-installer
config baked in.

The whole project is a few Python scripts plus shell/systemd glue — no build system, no
dependency manifest, no test suite. Read `README.md` for the full user-facing manual.

## Files

| Path | Role |
|---|---|
| `scripts/kb-kill-daemon` | the daemon (Python, the bulk of the logic) → `/usr/local/bin/kb-kill-daemon` (root-owned) |
| `scripts/kb-kill-push` | **mandatory** per-user pusher (stdlib only): feeds the daemon this user's config. Unprivileged **user** process → `/usr/local/bin/kb-kill-push` |
| `scripts/kb-kill-tray` | optional tray icon (Python / GTK3 / AppIndicator), unprivileged **user** process → `/usr/local/bin/kb-kill-tray` |
| `services/kb-kill-daemon.service` | hardened **system** unit → `/etc/systemd/system/` (no config path; config arrives by push) |
| `services/kb-kill-push.service` | pusher **global user** unit → `/etc/systemd/user/` (`WantedBy=default.target` — runs for TTY too) |
| `services/kb-kill-tray.service` | tray **global user** unit → `/etc/systemd/user/` |
| `install.sh` / `uninstall.sh` | deploy / reverse (project root) |
| `kb-kill.toml` | example/default config (TOML) → installed as the `/etc/kb-kill/kb-kill.toml` system default |
| `icons/` | tray SVGs → `/usr/local/share/kb-kill/icons/` |

The three executables live in `scripts/`, the three systemd units in `services/`;
`install.sh`/`uninstall.sh` stay at the project root. **Everything installs system-wide**
so all users share it: binaries (incl. the unprivileged push/tray) are root-owned copies
in `/usr/local/bin`, and push/tray are **global user units** in `/etc/systemd/user`
enabled for every user via `systemctl --global enable` (a `~/.local/bin` symlink into one
user's home would be unreadable by others). Config is per-user (`~/.config/kb-kill/`) with
a system default at `/etc/kb-kill/kb-kill.toml`. The suite name / runtime paths stay
`kb-kill` (`/run/kb-kill/control.sock`, `/usr/local/share/kb-kill/`); only the daemon
binary and its unit carry the `-daemon` suffix.

## Commands

```sh
./install.sh                       # deploy (and REDEPLOY) — see redeploy note below
sudo kb-kill-daemon detect         # list keyboards, which are targets, parsed combos — START HERE when debugging
sudo kb-kill-daemon monitor        # print raw key events + per-device/global combo matches
sudo systemctl restart kb-kill-daemon
journalctl -u kb-kill-daemon -f    # watch live: "live config", KILLED / WOKEN (daemon logs only to stderr/journal)
systemctl --user restart kb-kill-push    # the mandatory config pusher
systemctl --user restart kb-kill-tray    # optional UI
```

There is no lint/test/build step. To run the daemon unprivileged for ad-hoc testing,
run `./scripts/kb-kill-daemon run -c some.toml` directly: `-c` pins that file live
(bypassing seat arbitration, so you don't need a pusher), falls back to a user runtime
dir for the control socket, and warns that grabbing needs root / the `input` group. Plain
`./scripts/kb-kill-daemon run` starts config-less and waits for a push.

### Redeploying after a code edit (critical)

All three binaries run from **root-owned copies** in `/usr/local/bin`, not your working
tree. Editing anything under `scripts/` does nothing until you **re-run `./install.sh`**
(idempotent) — that reinstalls all three binaries, restarts the system daemon, and
restarts push/tray in your session. `detect`/`monitor` run the installed copy. Forgetting
this is the #1 "my change had no effect" trap.

## Architecture

**Single-threaded `selectors` event loop** in `KbKill.run()` (`kb-kill-daemon`). One loop
multiplexes: every monitored keyboard fd, the control socket's listen fd (`_LISTEN`
tag), per-client connection fds (`("client", conn)` tags), and the seats-dir inotify fd
(`_SEATWATCH` tag). Loop timeout = `RESCAN_INTERVAL` (2s), which drives device hotplug
rescans and is the backstop for re-checking the active seat user.

**Groups are the core abstraction.** A `Group` = a set of target keyboards + its own
kill/wake combo + a `killed` flag + `virtual_keyboard` flag. Config produces a list of
`Group`s: top-level keys form the "default" group (and supply combo defaults inherited
by `[groups.*]` tables). Each group kills/wakes independently; `_reconcile_grabs()`
makes the grabbed-device set equal the union of every *killed* group's targets.

**Combos match globally, not per-device.** `_global_pressed()` unions held keys across
*all* monitored devices. This is deliberate: input-remapper fans one physical
keyboard's keys across multiple virtual devices, so per-device matching would never see
a whole combo. Combo syntax is parsed in `_parse_combo`/`_parse_token` into
`list[frozenset[int]]` (each token = an "any-of" set of keycodes; combo fires when every
set has ≥1 key held).

**input-remapper coexistence** (`_resolve_targets` + `virtual_keyboard`): a
`virtual_keyboard = true` group targets *only* the input-remapper "forwarded" virtual
device (`is_virtual()`), never the physical keyboard, so input-remapper can always
re-grab the physical device. Ordinary groups grab matching physical devices directly.

**Grab-deferral invariant:** grabbing a device with keys currently held would swallow
their key-ups and leave them stuck down at the OS. So `_reconcile_grabs()` defers
grabbing a device until it is idle; each key-up re-runs reconciliation, which is what
eventually performs a deferred grab. Don't break this.

**Pure-push config + active-session arbitration** (replaces file hot-reload): the daemon
keeps `pushed[uid] -> Config` (one per uid, set by `set_config`, dropped on disconnect)
and reads logind's `/run/systemd/seats/*` `ACTIVE_UID` via `active_uids()`. The **live**
config is `pushed[active_uid]` (or none → idle). `_reevaluate_live()` swaps the live
config when the active uid changes; a `SeatWatch` inotify on the seats dir makes that
near-instant (the 2s tick is a backstop). Two invariants matter:
- **A grab never outlives its config.** `_install_groups()` ungrabs everything before
  switching, and a pusher disconnect reverts to idle — so you can never be left grabbed
  by a config that is no longer live (the kernel also auto-releases on death).
- **Kills are never inherited across a session switch.** A config that becomes live via a
  user switch starts **awake** (all `killed=False`), so a backgrounded user can't pre-arm
  a kill that fires on the incoming user or the login greeter. A re-push from the *live*
  uid (a config edit) does preserve killed state by name. A parse failure is rejected and
  the live config is untouched.

`-c PATH` (dev only) pins a file config live via `forced`, bypassing arbitration.

### Control socket (config push + tray)

**Mandatory** now — it is how config arrives. Unix socket at `/run/kb-kill/control.sock`,
**mode 0666** (any local user may connect: a pusher must bootstrap the daemon before any
config/allowed-uid exists). Newline-delimited JSON — **config text + group state, never
keystrokes**. Commands:
- `{"cmd":"set_config","toml":"<text>"}` — accepted from any uid, stored under that uid;
  governs the keyboard only while that uid is the active seat user.
- `{"cmd":"kill|wake|toggle|status","group":"<name>"}` — only from the **live** uid (or
  root). The daemon replies/broadcasts `{"type":"state","groups":[…]}` only to the live
  uid/root.

Authorization is per-command by kernel-verified peer uid (`SO_PEERCRED`), moved from
connect-time to command-time. DoS bounds: `MAX_CLIENTS` (global) + `MAX_CONNS_PER_UID`
(so one user can't starve the pool) + `HANDSHAKE_SECONDS` idle-drop + `MAX_LINE` (64 KiB,
sized for a TOML payload). `kb-kill-push` (mandatory, stdlib) pushes config and re-pushes
on file change; `kb-kill-tray` (optional GTK) renders/toggles groups. Both reconnect on
drop.

## Security model — treat as a hard constraint

kb-kill is keylogger-*capable*, and the design is built to contain that. When changing
anything, preserve these invariants (see README "Security model" and the systemd unit):

- **No keystroke ever persists or leaves the process.** Only the set of *currently
  held* keys is kept (for combo matching), discarded on key-up. No history, file, or
  network. The control socket carries config text + group state only, **never key data**
  (config TOML is not key data). (`monitor` printing to a terminal is a manual debug
  tool; the *service* never does.)
- **The deployed daemon binary must stay root-owned and not user-writable** — a root
  service executing a user-writable script is a privesc hole. That's why `install.sh`
  copies to `/usr/local/bin` rather than symlinking the working tree.
- **The systemd sandbox is load-bearing**, not decoration: no network
  (`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`), only input devices
  (`DevicePolicy=closed` + `DeviceAllow=char-input`), `SystemCallFilter`,
  `MemoryDenyWriteExecute`, `ProtectSystem=strict`, etc. The pure-push model lets the
  sandbox be **smaller** than before: config no longer touches the filesystem, so there
  are **no capabilities** (`CapabilityBoundingSet=`/`AmbientCapabilities=` empty — the old
  `CAP_DAC_READ_SEARCH`/`CAP_CHOWN` + `SystemCallFilter=@chown` are gone) and
  `ProtectHome=true`. The only new reads are `/run/systemd/seats/*` and `inotify_*` (both
  inside the existing `@system-service` set / readable `/run`). Reading `ACTIVE_UID` is a
  **defensive file parse** — do **not** switch to `sd_seat_get_active` via ctypes/dlopen
  (risks tripping `MemoryDenyWriteExecute`). Any new behavior needing a syscall/capability/
  path outside this set means widening the sandbox — do that deliberately and minimally.
- **The 0666 socket is gated by `SO_PEERCRED`, not file permissions.** A non-active user
  can push a config but it never governs the keyboard (only the active seat uid's does),
  and only the live uid may kill/wake/toggle. Treat "a grab never outlives its live
  config" and "no killed-state inherited across a session switch" as hard invariants
  (see the live-config notes above) — they are what keep the no-lockout / self-wake
  guarantee across user-switching. Scope is **seat0 / single-seat**; any process of the
  active uid (not only `kb-kill-push`) can command the daemon — within that user's own
  trust boundary.
