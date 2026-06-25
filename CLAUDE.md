# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

kb-kill disables/enables a target keyboard (e.g. a laptop's built-in keyboard) on a
global hotkey, as a hardened root systemd daemon. "Disable" = an exclusive
`EVIOCGRAB` on the device so the kernel routes its events only to kb-kill, which drops
them. There is **no virtual device and no event re-injection**: kb-kill grabs *only
while killed*; when awake it merely monitors (reads, never grabs), so a crash can never
break your keyboard, and the kernel auto-releases grabs if the process dies.

The whole project is two Python scripts plus shell/systemd glue — no build system, no
dependency manifest, no test suite. Read `README.md` for the full user-facing manual.

## Files

| Path | Role |
|---|---|
| `kb-kill` | the daemon (Python, ~1000 lines, the bulk of the logic) → deployed to `/usr/local/bin/kb-kill` (root-owned) |
| `kb-kill-tray` | optional tray icon (Python / GTK3 / AppIndicator), an **unprivileged user** process |
| `kb-kill.service` | hardened **system** unit (`@CONFIG@` placeholder filled in at install) |
| `kb-kill-tray.service` | tray **user** unit |
| `install.sh` / `uninstall.sh` | deploy / reverse |
| `kb-kill.toml` | example/default config (TOML) |
| `icons/` | tray SVGs |

## Commands

```sh
./install.sh                  # deploy (and REDEPLOY) — see redeploy note below
sudo kb-kill detect           # list keyboards, which are targets, parsed combos — START HERE when debugging
sudo kb-kill monitor          # print raw key events + per-device/global combo matches
sudo systemctl restart kb-kill
journalctl -u kb-kill -f      # watch KILLED / WOKEN live (daemon logs only to stderr/journal)
systemctl --user restart kb-kill-tray
```

There is no lint/test/build step. To run the daemon unprivileged for ad-hoc testing,
run `./kb-kill run -c some.toml` directly (it falls back to a user runtime dir for the
control socket and warns that grabbing needs root / the `input` group).

### Redeploying after a code edit (critical)

The daemon runs from the **root-owned copy** at `/usr/local/bin/kb-kill`, not your
working tree. Editing `./kb-kill` does nothing until you **re-run `./install.sh`**
(idempotent) — that reinstalls the binary and restarts the service. `detect`/`monitor`
also run the installed copy. Forgetting this is the #1 "my change had no effect" trap.

## Architecture

**Single-threaded `selectors` event loop** in `KbKill.run()` (`kb-kill`). One loop
multiplexes: every monitored keyboard fd, the control socket's listen fd (`_LISTEN`
tag), and per-client connection fds (`("client", conn)` tags). Loop timeout =
`RESCAN_INTERVAL` (2s), which drives device hotplug rescans and config hot-reload.

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

**Config hot-reload:** the loop watches the config file's mtime (and `SIGHUP`). On
reload, each surviving group's `killed` state is preserved by name so a reload never
surprise-enables a disabled keyboard; a parse failure logs and keeps the old config.

### Control socket (daemon ↔ tray)

Optional (`control_socket = true`), off by default. Unix socket carrying a newline-
delimited JSON protocol — **group state only, never keystrokes**. Commands:
`{"cmd":"kill|wake|toggle|status","group":"<name>"}`; the daemon replies/broadcasts
`{"type":"state","groups":[{"name","killed","targets"}]}`. The daemon authenticates each
connection by kernel-verified peer uid (`SO_PEERCRED`) — only `control_uid`
(`control_user`, default = config-file owner) or root is accepted — and bounds clients
(`MAX_CLIENTS`) and per-line buffering (`MAX_LINE`) against DoS. The tray
(`kb-kill-tray`) is a thin GTK client that reconnects on drop and renders one menu entry
per group.

## Security model — treat as a hard constraint

kb-kill is keylogger-*capable*, and the design is built to contain that. When changing
anything, preserve these invariants (see README "Security model" and the systemd unit):

- **No keystroke ever persists or leaves the process.** Only the set of *currently
  held* keys is kept (for combo matching), discarded on key-up. No history, file, or
  network. The control socket must never carry key data. (`monitor` printing to a
  terminal is a manual debug tool; the *service* never does.)
- **The deployed daemon binary must stay root-owned and not user-writable** — a root
  service executing a user-writable script is a privesc hole. That's why `install.sh`
  copies to `/usr/local/bin` rather than symlinking the working tree.
- **The systemd sandbox is load-bearing**, not decoration: no network
  (`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`), only input devices
  (`DevicePolicy=closed` + `DeviceAllow=char-input`), `SystemCallFilter`,
  `MemoryDenyWriteExecute`, `ProtectSystem=strict`, etc. New daemon behavior that needs
  a syscall/capability/path outside this set means widening the sandbox — do that
  deliberately and minimally (e.g. the `CAP_DAC_READ_SEARCH`/`CAP_CHOWN` +
  `SystemCallFilter=@chown` carve-outs already there exist for specific, documented
  reasons).
