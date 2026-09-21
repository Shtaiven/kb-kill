<p align="center">
  <img src="icons/kb-kill-killed.svg" alt="kb-kill" width="128" />
</p>

# kb-kill

Disable/enable a target keyboard, mouse, or touchpad with a global hotkey, as a
background service.

Press the **kill** hotkey on *any* keyboard to disable a target keyboard (e.g.
the laptop's built-in keyboard). While disabled, every key from the target is
swallowed **except** the **wake** hotkey, so a killed keyboard can always wake
itself. There is no way to lock yourself out.

It works for **mice and touchpads** too: a group can target pointing devices
(`pointers`) or any input device (`devices`), and even a keyboard and a mouse
together. A killed pointer self-wakes with a mouse-button combo, or you wake it
from the keyboard. See [Configuration](#configuration).

Typical use: your cat is sitting on your laptop keyboard while you work on an
external keyboard. Kill the laptop keyboard with a hotkey. Or disable the
touchpad so your palm stops moving the cursor while you type.

## Quick Start

Install the prebuilt package for your distro from the
[releases page](https://github.com/Shtaiven/kb-kill/releases). Log out and back
in once so the per-user services start.

**Debian / Ubuntu / Pop!\_OS** (`.deb`, needs Python ≥ 3.11, i.e. Ubuntu 24.04+):

```sh
sudo apt install ./kb-kill_*_all.deb
```

**Fedora / RHEL** (`.rpm`):

```sh
sudo dnf install ./kb-kill-*.noarch.rpm
```

kb-kill does nothing until you define a group: edit
`~/.config/kb-kill/kb-kill.toml` (created from `/etc/kb-kill/kb-kill.toml`) to
name a target device and a `kill_combo`/`wake_combo`. Then check:

```sh
kb-kill-detect                           # what the daemon matches and would grab
systemctl status kb-kill-daemon          # the shared daemon
systemctl --user status kb-kill-push     # your config pusher
```

Arch users: build from the AUR recipe in `packaging/aur/`
([packaging/README.md](packaging/README.md)). To install from a git checkout,
see [Install from a checkout](#install-from-a-checkout).

## A note on AI usage

This program is written mostly by agentic AI (Claude). Read the scripts before
installing this on your system; never run scripts you don't trust.

## How it works

- "Disable" means an exclusive `EVIOCGRAB` on the target device: the kernel
  routes its events only to kb-kill, which drops them.
- The grab happens **only while killed**. Awake, kb-kill merely *reads* devices
  (never grabs, never re-injects), so normal typing is 100% native and a crash of
  the service cannot break your keyboard. The kernel also releases every grab
  automatically if the process dies.
- Hotkeys are matched **globally** (the union of keys held across all monitored
  devices), not per device. See
  [input-remapper coexistence](#input-remapper-coexistence) for why.
- No virtual device, and **no root**: the daemon runs as a systemd dynamic user
  whose only privilege is group `input` (read/write on `/dev/input/event*`), inside
  a tight sandbox. See [Security model](#security-model).
- **It follows whoever is at the machine.** The daemon has no config of its own: a
  tiny per-user service (`kb-kill-push`) hands it your config, and the daemon uses
  the config of whoever currently controls the seat, graphical desktop **or** TTY,
  switching automatically on fast-user-switch or VT change.

## Requirements

- Python 3.11+ (for `tomllib`) and
  [`python-evdev`](https://python-evdev.readthedocs.io/), from your distro's
  packages. `pip` is not supported: the daemon runs against the system interpreter.
- `systemd` with **`systemd-logind`** and at least one seat (the normal desktop or
  TTY case). Without an active seat (headless, container) the daemon runs but stays
  **idle** and never grabs anything.
- The tray (optional) additionally needs PyGObject + GTK 3 + `AyatanaAppIndicator3`.
  Its on-screen display comes from the shell itself on GNOME and KDE; on COSMIC,
  sway and other wlroots compositors it needs `gtk-layer-shell` (GTK 3), and
  without it the menu entry is greyed out and nothing pops. The `.deb`/`.rpm`
  pull all of these in as weak dependencies; the commands below are for a
  checkout install.

```sh
# Ubuntu / Debian / Pop!_OS
sudo apt install python3 python3-evdev                                     # daemon
sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 # tray
sudo apt install gir1.2-gtklayershell-0.1                                  # tray OSD
# Fedora
sudo dnf install python3 python3-evdev                                     # daemon
sudo dnf install python3-gobject gtk3 libayatana-appindicator-gtk3         # tray
sudo dnf install gtk-layer-shell                                           # tray OSD
# Arch / Manjaro
sudo pacman -S python python-evdev                                         # daemon
sudo pacman -S python-gobject gtk3 libayatana-appindicator                 # tray
sudo pacman -S gtk-layer-shell                                             # tray OSD
```

## Install from a checkout

```sh
./install.sh              # daemon + push/tray for every user (uses sudo)
./install.sh --no-tray    # without the GTK tray
./uninstall.sh            # reverse it (keeps your config)
```

Everything installs system-wide: root-owned copies of the five scripts in
`/usr/local/bin`, the daemon unit in `/etc/systemd/system/`, the push/tray user
units in `/etc/systemd/user/` enabled for all users with `systemctl --global enable`, a system default config in `/etc/kb-kill/kb-kill.toml`, and a personal
copy in `~/.config/kb-kill/kb-kill.toml`. The installed binaries are copies, so
re-run `./install.sh` after editing the code. The installer's payload is checked
against the deb/rpm definition by `packaging/check-sync.sh`.

## Configuration

Config is [TOML](https://toml.io). `kb-kill-push` reads the first of
`$KB_KILL_CONFIG`, `~/.config/kb-kill/kb-kill.toml`, `/etc/kb-kill/kb-kill.toml`,
pushes it to the daemon, and re-pushes within ~1 s of every edit. The daemon never
reads a file itself.

The **shipped default is empty**: it defines no group, so kb-kill only monitors and
can never disable anything. There is **no built-in hotkey**; a keyboard can be
killed only by a combo you set, and both `kill_combo` and `wake_combo` are
**required** for every group.

A simple single-keyboard config:

```toml
keyboards  = "AT Translated Set 2 keyboard"   # exact name (kb-kill-detect shows it)
kill_combo = "ctrl+alt+shift+k"
wake_combo = "ctrl+alt+shift+u"
```

### Matching devices

A group picks its targets with up to three **name-matcher fields**, each a string
or a list of strings, matched case-insensitively against the **whole** device
name. An entry without a wildcard is an **exact** match; one with a bash-style glob
metacharacter is a **glob**:

| entry                           | matches                                                             |
| ------------------------------- | ------------------------------------------------------------------- |
| `"Logitech USB Keyboard"`       | that name and nothing else (exact, case-insensitive)                |
| `"*razer*"`                     | any name containing "razer"                                         |
| `"logitech mx*"`                | any name starting with "logitech mx"                                |
| `"Video Bu?"`                   | `?` is exactly one character                                        |
| `"*pcm=[37]"`                   | `[seq]` one character from the set; `[!seq]` and `[^seq]` negate it |
| `"Logitech {MX*,USB Keyboard}"` | `{a,b}` either alternative (braces may nest)                        |
| `"*"`                           | every device of that class                                          |

| field       | matches                                            |
| ----------- | -------------------------------------------------- |
| `keyboards` | keyboard-class devices only                        |
| `pointers`  | pointing devices only: mice, trackballs, touchpads |
| `devices`   | **any** input device, regardless of class          |

At least one field is required; set several to target them together. A pointer
group can **self-wake** if its `wake_combo` is a mouse-button combo; otherwise
wake it from the keyboard:

```toml
[groups.pointer]
pointers   = "*"
kill_combo = "ctrl+alt+shift+m"
wake_combo = "mouseleft+mouseright"   # the pointer wakes itself
```

Edits apply live. A group that is killed stays killed across a re-push from the
same user, and a config that fails to parse is rejected with the previous one kept.

### `virtual`

`"auto"` (default), `true`, or `false`. How the group treats a device that a
remapper **fronts** (grabs and re-emits through a virtual copy):

| value    | behaviour                                                                                                      |
| -------- | -------------------------------------------------------------------------------------------------------------- |
| `"auto"` | Per device: target the forwarded copy of anything input-remapper fronts, else the device itself.               |
| `true`   | Virtual devices only, never a physical one.                                                                    |
| `false`  | Literal: exactly what the matchers named, fronted or not. The only value that can fight a remapper for a grab. |

`"auto"` recognises input-remapper (2.2.1+ marks the copy's `phys` as
`input-remapper/<phys>`; older versions named it `input-remapper <name> forwarded`).
kanata, `keyd` and `evremap` leave no such link; match their output device by name
and use `virtual = false` if you deliberately want the hardware. The value is
group-wide; use two groups sharing a combo to kill a physical and a virtual target
together. The old name `virtual_keyboard` is accepted as a deprecated alias.

### Groups

- The **top-level** keys form the **default group** (when they include a matcher
  field) and supply `kill_combo`/`wake_combo` defaults for every `[groups.*]`.
- Each **`[groups.<name>]`** table adds a group. `virtual` is per group and not
  inherited. An optional `label = "…"` is the display name the tray shows.
- A group **name** is up to 32 characters of letters, digits, space, `.`, `_`, `-`
  (it appears in log lines). A label is up to 64 printable characters.
- TOML rule: top-level keys come **before** any `[groups.*]` table.
- Groups sharing a combo toggle together. `kill_combo == wake_combo` makes a
  single toggle hotkey.
- Hotkeys fire on the **press** that completes the combo, never while it is held,
  so you can keep the modifiers down and tap one group's key, then another's.

```toml
wake_combo = "ctrl+alt+shift+u"               # inherited below

keyboards  = "AT Translated Set 2 keyboard"   # default group (the laptop)
kill_combo = "ctrl+alt+shift+k"

[groups.externals]
label      = "External keyboard + mouse"
keyboards  = ["KBDfans*", "solaar-keyboard"]
pointers   = "Logitech*"
kill_combo = "ctrl+alt+shift+j"
wake_combo = "ctrl+alt+shift+m"               # overrides the default
```

Groups should target disjoint devices; an overlapping device stays disabled while
*any* group targeting it is killed.

### Hotkey syntax

Tokens joined by `+`. Each token is an "any-of" set; the combo fires when every
token has at least one key held.

| token                                                                | matches                           |
| -------------------------------------------------------------------- | --------------------------------- |
| `ctrl` / `control`                                                   | either Ctrl                       |
| `alt`                                                                | either Alt (`ralt` = AltGr)       |
| `shift`                                                              | either Shift                      |
| `super` / `meta` / `win` / `cmd`                                     | either Super                      |
| `lctrl`/`rctrl`, `lalt`/`ralt`, `lshift`/`rshift`, `lsuper`/`rsuper` | pin a side                        |
| `mouseleft` / `mouseright` / `mousemiddle`                           | mouse buttons (pointer self-wake) |
| `a`–`z`, a raw `KEY_*`/`BTN_*` name, or a numeric code               | that single key                   |

Keys are matched **as they arrive at kb-kill**. Under a remapper that means after
remapping: CapsLock mapped to Ctrl counts as `ctrl`; a physical Ctrl key that the
remapper maps to something else does not.

### Multiple users

push and tray run for every logged-in user, so each session feeds the shared
daemon its own config. Only the config of the user **currently controlling the
seat** governs the devices; others are held dormant. On a user switch the daemon
swaps configs and starts the incoming one **awake**, so a kill is never inherited
and the login greeter can never be disabled.

## Commands

```sh
kb-kill-detect                 # groups, every device, which one each group targets, grabs
sudo kb-kill-monitor           # raw key events + the daemon's real KILLED/AWAKE transitions
sudo kb-kill-monitor --debug   # ... plus the daemon's key-rate diagnostics (grab deferral, wake progress)
journalctl -u kb-kill-daemon -f
```

`kb-kill-detect` needs no privileges: it asks the daemon over its socket and works
for the active user (or root). `kb-kill-monitor` reads `/dev/input` itself, so it
needs `sudo`; nothing it prints is written anywhere but your terminal.

### Debugging a hotkey that won't fire

Run `sudo kb-kill-monitor` and press the combo one key at a time. Each key line
shows the device it came from; a `<<< kill combo held [group]` tag marks the
instant the held keys form the combo, and `>>> daemon: [group] -> KILLED` is the
daemon reporting that it acted. Then:

- **No tag ever appears:** the combo never completes on evdev. A remapper is
  consuming a key (input-remapper's `Ctrl` alone mapped to something else, or a
  `ctrl+k` mapping swallowing `k`), or the keyboard cannot report that chord
  (home-row mods on QMK/ZMK boards emit the modifier instead of the letter).
- **Tag but no `>>>` line:** the daemon did not see the same keys. Run
  `kb-kill-detect`: is the device monitored, and is the group's target the device
  you are typing on? A device grabbed by input-remapper shows no events in monitor,
  and neither does one kb-kill has grabbed; the daemon still reads both.
- **`--debug`** streams the daemon's own view while a group is killed: which wake
  tokens are held, which device delivered the last event, and why a grab is being
  deferred. It goes only to your terminal, never to the journal.

## Tray icon

`kb-kill-tray` shows whether any group is KILLED and toggles groups from its menu
(checked = AWAKE). It uses the AppIndicator / StatusNotifierItem protocol, native on
KDE and COSMIC, and on GNOME with the AppIndicator extension. It runs as your
user and only talks to the daemon over the control socket.

On every toggle it also flashes an on-screen display near the bottom of the screen
— the volume / airplane-mode kind, not a notification that lands in your history.
One hotkey can flip several groups at once, and each gets its own card, stacked
(the daemon announces every edge separately, so the tray holds them together for
a moment to show them as one stack).
There is no shared protocol for this, so the tray picks a backend at runtime:
`org.gnome.Shell.ShowOSD` on GNOME, `org.kde.osdService` on KDE, and everywhere
else a `gtk-layer-shell` surface it draws itself (mutter does not support
layer-shell, hence the split). With no backend available the menu entry is
greyed out and nothing pops.

**On-screen display** in the menu turns it on and off — on by default. The tray
writes that choice to `~/.config/kb-kill/tray.toml`, which is its own file, not
the config pushed to the daemon — hence two separate menu entries: **Edit groups
& hotkeys…** opens `kb-kill.toml` (what `kb-kill-push` sends to the daemon) and
**Edit tray settings…** opens `tray.toml`, creating it from the current values
if it does not exist yet:

```toml
osd = true          # the menu writes this one
osd_margin = 96     # px above the bottom of the screen
osd_opacity = 0.92  # 0.0 clear .. 1.0 solid
```

Colours, font and (on COSMIC) corner radius come from the desktop, so only the
geometry is here. Edited values apply the next time the tray starts; the menu
toggle leaves them alone, and anything missing, malformed or out of range falls
back to the defaults above.

The socket is a small newline-delimited JSON protocol if you want to script it:
`{"cmd":"kill|wake|toggle","group":"<name>"}`, `{"cmd":"status"}`,
`{"cmd":"devices","all":true}`; the daemon replies and broadcasts
`{"type":"state","groups":[{name,label,killed,targets,kill,wake,kill_codes,wake_codes}]}`
to the active user's clients on every change. Config is delivered the same way
(`{"cmd":"set_config","toml":"…"}`, what `kb-kill-push` sends). `{"cmd":"debug"}`
(root only) subscribes to key-rate diagnostics.

## input-remapper coexistence

input-remapper grabs the **physical** keyboard and re-emits through two virtual
devices: a per-keyboard **forwarded** copy for un-remapped keys, and the shared
`input-remapper keyboard` for the output of mappings.

With `virtual = "auto"` you name the hardware and kb-kill targets the forwarded
copy, so input-remapper keeps the physical device. When the copy disappears (a
preset apply or an input-remapper restart) kb-kill leaves the hardware alone for
ten seconds rather than grabbing it, because input-remapper gives up on a device it
cannot grab. If input-remapper is not running at all, the same group grabs the
hardware directly.

Two consequences:

1. **Combos are matched globally**, because one keyboard's keys are split across
   two virtual devices (a remapped modifier on `input-remapper keyboard`, the rest
   on the forwarded copy).
1. **Remapped keys are not eaten while killed.** kb-kill grabs the forwarded copy,
   not the shared output device, so anything input-remapper *remaps* (CapsLock as
   Ctrl, `ctrl+h` as Left, mouse-button macros) still passes. To eat those too, add
   `devices = "input-remapper keyboard"` to the group; the cost is that macros from
   every other remapped device are eaten as well while the group is killed.

Press hotkeys with the keys as they exist **after** remapping. If your preset maps
the physical Ctrl key away, that key can never be part of a kb-kill combo; use the
key that produces Ctrl (CapsLock, say). `kb-kill-monitor` shows exactly which
keycodes arrive.

## Security model

kb-kill reads all keyboard input (and mouse buttons, for pointer groups), so it
is keylogger-*capable*. The design minimizes and contains that:

- **No keystroke content is ever stored or transmitted.** The daemon keeps only
  the set of keys *currently held*, discarded on release. Pointer motion never
  reaches the process: every device fd carries an `EVIOCSMASK` so the kernel
  delivers key events only. The control socket carries config text and group
  state, never key data; the root-only `debug` stream names combo tokens and
  devices, not typed keys.
- **Nothing keystroke-paced reaches the journal.** The journal is readable by
  group adm/wheel, and any local uid may push a config, so a hostile config (one
  group per key) could otherwise turn `KILLED`/`AWAKE` lines into a keylogger.
  State lines pass a global token bucket (burst 4, then one per 5 s); logged text
  is flattened to one printable line; group names and labels are charset-checked
  so a TOML key containing `\n` cannot forge journal records.
- **Not root.** The daemon runs as a systemd `DynamicUser` with
  `SupplementaryGroups=input`; that is the whole privilege. Do **not** add your
  login user to group `input`: that would give every process you run the same
  access, which this single sandboxed daemon exists to avoid.
- **Sandbox** (`kb-kill-daemon.service`): no capabilities, no network
  (`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`), only input device nodes
  (`DevicePolicy=closed` + `DeviceAllow=char-input`), `SystemCallFilter`,
  `MemoryDenyWriteExecute`, `ProtectSystem=strict`, `ProtectHome=true`.
- **Control socket: any local user may connect, every command is authenticated**
  by the kernel-verified peer uid (`SO_PEERCRED`). A pushed config governs the
  devices only while that user is the active seat user; only that user (or root)
  may kill/wake/toggle or read state. Connections, per-user connections, and
  buffered bytes are bounded; idle connections are dropped. Scope is a single seat.
- **A grab never outlives its config**, and a user switch always starts awake.
