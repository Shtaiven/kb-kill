# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

kb-kill disables/enables target input devices — keyboards **and** pointers (mice,
trackballs, touchpads) — on a global hotkey, as a hardened root systemd daemon.
"Disable" = an exclusive `EVIOCGRAB` on the device so the kernel routes its events only
to kb-kill, which drops them. There is **no virtual device and no event re-injection**:
kb-kill grabs *only while killed*; when awake it merely monitors (reads, never grabs),
so a crash can never break your devices, and the kernel auto-releases grabs if the
process dies.

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

| Path                              | Role                                                                                                                                            |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/kb-kill-daemon`          | the daemon (Python, the bulk of the logic) → `/usr/local/bin/kb-kill-daemon` (root-owned)                                                       |
| `scripts/kb-kill-push`            | **mandatory** per-user pusher (stdlib only): feeds the daemon this user's config. Unprivileged **user** process → `/usr/local/bin/kb-kill-push` |
| `scripts/kb-kill-tray`            | optional tray icon (Python / GTK3 / AppIndicator), unprivileged **user** process → `/usr/local/bin/kb-kill-tray`                                |
| `services/kb-kill-daemon.service` | hardened **system** unit → `/etc/systemd/system/` (no config path; config arrives by push)                                                      |
| `services/kb-kill-push.service`   | pusher **global user** unit → `/etc/systemd/user/` (`WantedBy=default.target` — runs for TTY too)                                               |
| `services/kb-kill-tray.service`   | tray **global user** unit → `/etc/systemd/user/`                                                                                                |
| `install.sh` / `uninstall.sh`     | deploy / reverse (project root)                                                                                                                 |
| `kb-kill.toml`                    | example/default config (TOML) → installed as the `/etc/kb-kill/kb-kill.toml` system default                                                     |
| `icons/`                          | tray SVGs → `/usr/local/share/kb-kill/icons/`                                                                                                   |

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
sudo kb-kill-daemon detect         # list devices (kbd/ptr), which are targets, parsed combos — START HERE when debugging
sudo kb-kill-daemon monitor        # print raw key events + per-device/global combo matches
sudo systemctl restart kb-kill-daemon
journalctl -u kb-kill-daemon -f    # watch live: "live config", KILLED / WOKEN (rate-limited; daemon logs only to stderr/journal)
systemctl --user restart kb-kill-push    # the mandatory config pusher
systemctl --user restart kb-kill-tray    # optional UI

# Per-key diagnostics (wake progress, grab/defer detail) are OFF by default and
# need BOTH gates in a drop-in, then a restart (which releases all grabs, so
# re-arm the kill before reproducing). `systemctl revert` when done. Full
# procedure: README "Turning on the per-key diagnostics".
sudo systemctl edit kb-kill-daemon # [Service] Environment=KB_KILL_DEBUG_KEYS=1 + LogLevelMax=debug
```

There is no lint/test/build step. To run the daemon unprivileged for ad-hoc testing,
run `./scripts/kb-kill-daemon run -c some.toml` directly: `-c` pins that file live
(bypassing seat arbitration, so you don't need a pusher) and falls back to a user
runtime dir for the control socket; run unprivileged it can monitor but grabbing
fails until run as root. Plain `./scripts/kb-kill-daemon run` starts config-less and
waits for a push.

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

**Groups are the core abstraction.** A `Group` = a set of target devices + its own
kill/wake combo + a `killed` flag + `virtual` flag. Targets are chosen by up to three
name matcher fields, one per device class: `keyboards` (keyboard-class,
`is_keyboard()`), `pointers` (mice/trackballs/touchpads, `is_pointer()`), and `devices`
(any class). A group needs ≥1; several fields kill multiple classes together. Each entry
matches as a case-insensitive **substring OR glob** (`fnmatch`: `*`/`?`/`[seq]`) of the
whole name — substring kept for backward compat, so a bare `*` matches all (see
`_dev_matches`). Config produces a list of `Group`s: top-level keys form the "default"
group (and supply combo defaults inherited by `[groups.*]` tables). Each group
kills/wakes independently; `_reconcile_grabs()` makes the grabbed-device set equal the
union of every *killed* group's targets. Pointer devices are only *opened*
(`open_devices(want_pointers)`) when a live group references `pointers`/`devices`;
keyboards are always opened. Mouse buttons are `EV_KEY` like keys (so `btn_*`/`mouse*`
combos work and a killed pointer can self-wake); pointer motion is never processed.

**Combos match globally, not per-device.** `_global_pressed()` unions held keys across
*all* monitored devices. This is deliberate: input-remapper fans one physical
keyboard's keys across multiple virtual devices, so per-device matching would never see
a whole combo. Combo syntax is parsed in `_parse_combo`/`_parse_token` into
`list[frozenset[int]]` (each token = an "any-of" set of keycodes; combo fires when every
set has ≥1 key held).

**input-remapper coexistence** (`_resolve_targets` + `virtual`): a `virtual = true`
group targets *only* the input-remapper "forwarded" virtual device (`is_virtual()`),
never the physical device, so input-remapper can always re-grab the physical device.
Ordinary groups grab matching physical devices directly. The flag is group-wide and
applies after the class-matching in `_dev_matches`, so a single group can't mix physical
and virtual targets — use two groups sharing a combo (they toggle together). `virtual`
was renamed from `virtual_keyboard` (still accepted as a deprecated alias) since it now
applies to pointers too.

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
- `{"cmd":"devices"}` — live uid/root only: dump monitored devices (name, class,
  virtual, grabbed-by-us, held-key *count* — never keycodes). Debug aid; pairs with
  `_log_wake_progress` (while a group is killed, log which wake-combo *tokens* are held
  whenever that set changes) — but note that one is **off unless `KB_KILL_DEBUG_KEYS=1`**,
  because it fires at key-event rate. "Token names are only config data" was the old
  justification and it was **wrong**: at key rate the *timing* is the leak, regardless of
  what the text says. See the journal invariant below.

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
  held* keys/buttons is kept (for combo matching), discarded on release. Pointer motion
  (`EV_REL`/`EV_ABS`) is never processed — `_process` acts only on `EV_KEY`. No history,
  file, or network. The control socket carries config text + group state only, **never
  key data** (config TOML is not key data). (`monitor` printing to a terminal is a manual
  debug tool; the *service* never does.)
- **The journal is an untrusted-reader channel — treat every `log()` call as attacker-
  shapeable output.** The journal is readable by group `adm` and mirrored to
  `/var/log/syslog`, and `set_config` is accepted from **any** local uid, so a hostile
  config (one group per key, named after that key) can turn the daemon's own log into a
  keylogger readable by a process with no `/dev/input` access. Three rules, all enforced
  in the journal-hygiene block above `log()` rather than at the ~40 call sites:
  1. **Nothing may reach the journal at per-key-event rate.** Anything reachable from
     `_process` / `_reconcile_grabs` / `_toggle_groups` must go through `log_keys()`
     (writes nothing unless `KB_KILL_DEBUG_KEYS=1` — that env var is the real gate;
     the unit's `LogLevelMax=info` is belt-and-braces only, since journald was
     measured not to apply it to stderr-derived `<7>` priorities) or be deduped to a
     state transition
     (`_deferred` / `_grab_failed` / `_read_errored`). Stripping key *identity* is **not**
     sufficient — at key rate the timing alone is a password side channel.
  1. **State/config/control lines go through the rate limiters** (`log_state` /
     `CTRL_LOG`). The bucket must stay **global, never per-group**: it is the only bound
     on the `KILLED`/`WOKEN` channel, since there is deliberately no cap on group count.
     Keep `LOG_STATE_BURST` tight — the burst is what an attacker gets for free.
  1. **All logged text passes through `_safe()`** (control chars → `?`, length-capped),
     and group names/labels are validated (`GROUP_NAME_RE`, `LABEL_MAX_LEN`). TOML allows
     a quoted key containing `\n`, which would otherwise forge journal records under
     kb-kill's identifier.
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
  The unit's **journal block is part of the sandbox**: `SyslogLevelPrefix=yes` makes
  the `<N>` priorities meaningful, `LogLevelMax=info` is belt-and-braces (measured
  *not* to filter stderr-derived priorities on systemd 255 — never rely on it as a
  gate), and `StandardError=journal` must stay explicit (its default `inherit` would
  follow `StandardOutput=null` and silence the journal entirely).
- **The 0666 socket is gated by `SO_PEERCRED`, not file permissions.** A non-active user
  can push a config but it never governs the keyboard (only the active seat uid's does),
  and only the live uid may kill/wake/toggle. Treat "a grab never outlives its live
  config" and "no killed-state inherited across a session switch" as hard invariants
  (see the live-config notes above) — they are what keep the no-lockout / self-wake
  guarantee across user-switching. Scope is **seat0 / single-seat**; any process of the
  active uid (not only `kb-kill-push`) can command the daemon — within that user's own
  trust boundary.
