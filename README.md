<p align="center">
  <img src="icons/kb-kill-killed.svg" alt="kb-kill" width="128" />
</p>

# kb-kill

Disable/enable a target keyboard, mouse, or touchpad with a global hotkey, as a
background service.

Press the **kill** hotkey on *any* keyboard to disable a target keyboard (e.g.
the laptop's built-in keyboard). While disabled, every key from the target is
swallowed **except** the **wake** hotkey — so a killed keyboard can always
wake itself. There is no way to lock yourself out.

It works for **mice and touchpads** too: a group can target pointing devices
(`pointers`) or any input device (`devices`), and even a keyboard and a mouse
together. A killed pointer self-wakes with a mouse-button combo, or you wake it
from the keyboard — see [Configuration](#configuration).

Typical use: your cat is sitting on your laptop keyboard while you're working on
an external keyboard. Kill the laptop keyboard with a hotkey! Or disable the
touchpad so your palm stops moving the cursor while you type.

## Quick Start

Install the prebuilt package for your distro from the
[releases page](https://github.com/Shtaiven/kb-kill/releases). You make have to logout and login
again for services to start.

**Debian / Ubuntu / Pop!\_OS** (`.deb`, needs Python ≥ 3.11 — Ubuntu 24.04+):

```sh
sudo apt install ./kb-kill_*_all.deb
```

**Fedora / RHEL** (`.rpm`):

```sh
sudo dnf install ./kb-kill-*.noarch.rpm
```

After installing, kb-kill does nothing until you define a group: edit
`~/.config/kb-kill/kb-kill.toml` (or the `/etc/kb-kill/kb-kill.toml` default) to
set a target keyboard and a `kill_combo`/`wake_combo` — see
[Configuration](#configuration). Verify it's running:

```sh
systemctl status kb-kill-daemon          # the shared root daemon
systemctl --user status kb-kill-push     # your config pusher (after you log in)
```

Arch users: build from the AUR recipe in `packaging/aur/` (see
[packaging/README.md](packaging/README.md)). To install from a git checkout on
any distro instead of a package, see [Install](#install).

## A note on AI usage

This program is written mostly by agentic AI (Claude using Opus 4.8). Read the scripts before
installing this on your system! This has been tested and reviewed, but never run scripts that
you don't trust!

## How it works

- "Disable" means an exclusive `EVIOCGRAB` on the target device: the kernel
  routes its events only to kb-kill, which drops them.
- The grab happens **only while killed**. When awake, kb-kill merely *monitors*
  devices (reads, never grabs, never re-injects), so normal typing and pointing is
  100% native and a crash of the service cannot break your keyboard or mouse. The
  kernel also releases every grab automatically if the process dies.
- Hotkeys are matched **globally** (across the union of all monitored devices),
  not per-device — see [input-remapper](#input-remapper-coexistence) for why that
  matters.
- No virtual device. kb-kill runs as a **hardened root system daemon** so that no
  ordinary user process needs access to your keyboards or mice — see
  [Security model](#security-model).
- **It follows whoever is logged in.** The daemon has no config of its own: a tiny
  per-user service (`kb-kill-push`) hands it your config, and the daemon uses the
  config of whoever currently controls the seat — graphical desktop **or** TTY —
  switching automatically on fast-user-switch / VT change. Nothing is tied to the
  person who installed it.

## Requirements

- Python 3.11+ (for `tomllib`) and
  [`python-evdev`](https://python-evdev.readthedocs.io/).
- `systemd` and `sudo` (the daemon is a root system service).
- **`systemd-logind`** with at least one seat (the normal desktop/TTY case). The
  daemon reads `/run/systemd/seats/*` (`ACTIVE_UID`) to follow whoever currently
  controls the seat and apply only that user's pushed config. Without an active
  seat — e.g. headless or a container with no logind — the daemon still runs but
  stays **idle** (it never grabs the keyboard), since no user is ever "live".
- The tray (optional) additionally needs PyGObject + GTK 3 +
  `AyatanaAppIndicator3` — see [Tray icon](#tray-icon).

Install the dependencies from **your distro's packages** — the **daemon** line is
required, the **tray** line is only needed if you want the
[tray icon](#tray-icon). `pip` is **not** a supported install method: the daemon
runs as a root system service against the system Python interpreter, so it needs
the packages where that interpreter looks (and `sudo pip` into the system
environment risks clobbering distro-managed packages / is refused by PEP 668 on
recent distros).

**Ubuntu / Debian / Pop!\_OS** (`apt`) — needs Python ≥ 3.11 for `tomllib`
(Ubuntu 24.04+; on 22.04 install a newer Python):

```sh
sudo apt install python3 python3-evdev                                    # daemon
sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 # tray
```

**Fedora** (`dnf`):

```sh
sudo dnf install python3 python3-evdev                                    # daemon
sudo dnf install python3-gobject gtk3 libayatana-appindicator-gtk3        # tray
```

**Arch / Manjaro** (`pacman`):

```sh
sudo pacman -S python python-evdev                                        # daemon
sudo pacman -S python-gobject gtk3 libayatana-appindicator                # tray
```

## Install

kb-kill is self-contained — run its installer (it uses `sudo` for the root parts):

```sh
./install.sh
```

Everything installs **system-wide**, so every user on the machine gets it. The
installer:

- copies all three binaries to `/usr/local/bin` (root-owned): `kb-kill-daemon`,
  plus the unprivileged `kb-kill-push` and `kb-kill-tray`;
- installs the hardened **system** unit to `/etc/systemd/system/kb-kill-daemon.service`
  and the **global user** units to `/etc/systemd/user/` (so every user's
  `systemd --user` sees push/tray), enabling them for all users with
  `systemctl --global enable`;
- installs a **system default** config to `/etc/kb-kill/kb-kill.toml`, and a personal
  copy to your `~/.config/kb-kill/kb-kill.toml` you can edit without sudo;
- enables + starts the daemon, and starts push/tray in your current session;
- cleans up any pre-rename / per-user install (`kb-kill.service`, `~/.local/bin`
  symlinks) from earlier versions.

```sh
systemctl status kb-kill-daemon          # the shared root daemon
systemctl --user status kb-kill-push     # your config pusher (mandatory)
journalctl -u kb-kill-daemon -f          # watch "live config", KILLED / WOKEN (rate-limited)
```

Re-run `./install.sh` to redeploy after editing the code (the binaries run from the
root-owned copies, not your working tree).

**Multi-user:** push and tray are enabled for every user and start automatically on
each user's next login — no per-user install needed. The root daemon is shared and
always uses the config of whoever is **currently** at the seat; each user keeps their
own `~/.config/kb-kill/kb-kill.toml` (falling back to the `/etc` default).

To remove everything (binaries, units, icons; stops the services) while keeping
your config and the project files:

```sh
./uninstall.sh
```

## Configuration

Config is [TOML](https://toml.io). Your `kb-kill-push` service finds it from the
first of: `$KB_KILL_CONFIG`, `~/.config/kb-kill/kb-kill.toml`, `~/.kb-kill`,
`/etc/kb-kill/kb-kill.toml`, and pushes it to the daemon. (The daemon never reads
the file itself; `kb-kill-daemon detect`/`monitor` and `-c PATH` use the same search
for the invoking user.)

The **shipped default** (`/etc/kb-kill/kb-kill.toml`, and the copy placed in your
`~/.config`) is **empty** — it defines no group, so kb-kill does nothing until you
add one: it only monitors and can never disable a keyboard. There is **no
built-in hotkey** — a keyboard can be killed only by a combo you set yourself, and
both `kill_combo` and `wake_combo` are **required** for any group (a group with a
target keyboard but no combo is a config error).

A simple single-keyboard config:

```toml
keyboards  = "AT Translated Set 2 keyboard"
kill_combo = "ctrl+alt+shift+k"   # required — no default hotkey exists
wake_combo = "ctrl+alt+shift+u"   # required; always honored on the killed keyboard
virtual    = true                 # input-remapper-managed; see coexistence below
```

A group picks its targets with up to three **name-matcher fields**, each a string
or a list of strings, matched case-insensitively against device names
(`kb-kill-daemon detect` shows the names). Each entry matches as a **substring**
*or* a **glob** (`fnmatch`: `*`, `?`, `[seq]`) of the whole name — so `"razer"`
matches by substring, `"logitech mx*"` globs, and a bare `"*"` matches every
device of that class. **At least one** field is required:

| field       | matches                                                 |
| ----------- | ------------------------------------------------------- |
| `keyboards` | keyboard-class devices only                             |
| `pointers`  | pointing devices only — mice, trackballs, and touchpads |
| `devices`   | **any** input device, regardless of class               |

Set several fields to target them together — e.g. `keyboards` **and** `pointers`
in one group disables a keyboard and a mouse on the same hotkey. A pointer group
can **self-wake** if its `wake_combo` is a mouse-button combo (see
[Hotkey syntax](#hotkey-syntax)); otherwise wake it from the keyboard. Killing a
touchpad while typing on an external keyboard is a common use:

```toml
[groups.pointer]
pointers   = "*"
kill_combo = "ctrl+alt+shift+m"
wake_combo = "mouseleft+mouseright"   # the pointer wakes itself
```

The config is **applied live**: edit the file and `kb-kill-push` re-pushes it within
~1 s. A group that is currently killed keeps that state across an edit (so a re-push
never surprise-enables a disabled keyboard), and if the new file fails to parse the
error is logged and the previous config is kept. (Switching to a *different* user,
however, always starts that user's config **awake** — see
[Multiple users](#multiple-users).) The tray updates its menu automatically.

`virtual` (default `false`; the old name `virtual_keyboard` still works as a
deprecated alias): set `true` when the target is fronted by an input-remapper
"forwarded" virtual device — kb-kill then targets that virtual device and never
the physical one. Leave it `false` for an ordinary device, which kb-kill grabs
directly. The flag is **group-wide**, so a single group is either all-forwarded or
match-anything; to disable a *physical* target and a *virtual* one at once, use
two groups sharing the same `kill_combo`/`wake_combo` — they toggle together.

### Multiple users

push and tray are installed system-wide and enabled for **every** user, so each
user's session feeds the shared daemon its own config automatically (no per-user
setup). Only the config of the user **currently controlling the seat** governs the
keyboard (logind's active session, graphical or TTY); other logged-in users' configs
are held but dormant. On a user switch the daemon swaps to the now-active user's
config and starts it **awake** — a kill is never inherited across the switch, so you
can never land on a pre-disabled keyboard (or disable the login greeter). When no
active user has a config (e.g. the login screen), the daemon is idle and every
keyboard works normally. Each user's config is `~/.config/kb-kill/kb-kill.toml`,
falling back to the system default `/etc/kb-kill/kb-kill.toml`.

### Groups: per-device hotkeys

You can define several independent **groups**, each with its own target
devices and its own kill/wake hotkeys:

- The **top-level** keys (above) are the **default group** (when they include a
  matcher field) and also supply **defaults** that every `[groups.*]` inherits.
- Each **`[groups.<name>]`** table adds a group; it inherits `kill_combo` and
  `wake_combo` from the top-level unless it sets its own — but there is **no
  built-in default**, so each combo must be set *somewhere* (top-level or the
  group itself), else the group is rejected. `virtual` is per-group
  (default `false`) and is **not** inherited.
- An optional **`label = "…"`** per group sets a display name the tray shows
  instead of the group's table key (e.g. `label = "Mouse & touchpad"` for
  `[groups.pointer]`). Cosmetic only — logs, `detect`, and control commands
  keep using the table key. Up to 64 printable characters.
- A group **name** is an identifier: up to 32 characters of letters, digits,
  space, `.`, `_` or `-`. It appears in log lines, so it is charset-checked
  rather than free text (see [Security model](#security-model)).
- TOML rule: top-level keys must come **before** any `[groups.*]` table.
- Give each group a **distinct** combo — a shared combo toggles them together
  (handy for mixing a physical and a virtual target across two groups).
- Setting a group's `kill_combo` and `wake_combo` to the **same** hotkey turns it
  into a single toggle: press to disable, press again to re-enable.
- Hotkeys fire on the **press** — the moment the combo completes — not for as long
  as it is held. So holding a combo down while typing something else won't flip the
  group back, and you can keep the modifiers down and tap one group's key then
  another's (`ctrl+alt+shift` held, then `k`, then `p`) to disable both, even if you
  don't fully release the first key.

```toml
wake_combo = "ctrl+alt+shift+u"               # default, inherited below

keyboards  = "AT Translated Set 2 keyboard"   # default group (the laptop)
kill_combo = "ctrl+alt+shift+k"
virtual    = true                             # input-remapper-managed

[groups.externals]
keyboards  = ["KBDfans", "solaar-keyboard"]
pointers   = "Logitech"                       # kill this keyboard + mouse together
kill_combo = "ctrl+alt+shift+j"
wake_combo = "ctrl+alt+shift+m"               # overrides the default
# virtual defaults to false → grabbed directly
```

Any keyboard can trigger any group's hotkey, and each group kills/wakes
independently. Groups should target **disjoint** devices; if they overlap, a
device stays disabled while *any* group targeting it is killed.

### Hotkey syntax

Tokens joined by `+`. Each token is an "any-of" group; the combo fires when
every group has at least one key held.

| token                                                  | matches                           |
| ------------------------------------------------------ | --------------------------------- |
| `ctrl` / `control`                                     | either Ctrl                       |
| `lctrl` / `rctrl`                                      | left / right Ctrl only            |
| `alt`                                                  | either Alt (`ralt` = AltGr)       |
| `shift`                                                | either Shift                      |
| `super` / `meta` / `win` / `cmd`                       | either Super                      |
| `lalt`/`ralt`, `lshift`/`rshift`, `lsuper`/`rsuper`    | pin a side                        |
| `mouseleft` / `mouseright` / `mousemiddle`             | mouse buttons (pointer self-wake) |
| `a`–`z`, a raw `KEY_*`/`BTN_*` name, or a numeric code | that single key                   |

Mouse-button tokens (`mouseleft`, or any raw `BTN_*` name like `BTN_SIDE`) let a
killed pointer wake itself — a killed device is still read for combo matching, so
its own buttons can trigger the wake combo.

## Commands

```sh
kb-kill-daemon                # run the service (same as `... run`); systemd does this as root, config-less
sudo kb-kill-daemon detect    # list keyboards + which are targets + parsed combos
sudo kb-kill-daemon monitor   # print raw key events (debugging)
#                             # per-key daemon diagnostics are OFF by default:
#                             # see "Turning on the per-key diagnostics" below
kb-kill-daemon -c PATH run    # run with a specific config pinned live (ad-hoc testing, no pusher needed)
```

`detect` is the place to start. It needs `sudo` because reading input devices
requires root. The service itself (`kb-kill-daemon run` with no `-c`) starts
config-less and waits for `kb-kill-push`.

### Debugging a wake that won't fire

An exclusive grab routes a device's events to the grabber only, so **`monitor`
cannot show events from a device the daemon (or input-remapper) has grabbed** —
while a group is killed, its target devices look silent in `monitor` even though
the daemon is receiving every event. Both `detect` and `monitor` flag such
devices (`GRABBED by another process`). To see what the *daemon* sees instead:

- **Wake-progress lines (`KB_KILL_DEBUG_KEYS`) — off by default, see below.**
  While a group is killed, the daemon can log which part of the wake combo is
  currently held, every time that changes, plus which device delivered the event.

- **`devices` control command.** Ask the running daemon what it monitors/grabs:

  ```sh
  printf '{"cmd":"devices"}\n' | nc -U /run/kb-kill/control.sock -q1
  ```

  Each entry shows the device's class, whether it is a virtual (uinput) device,
  whether the daemon currently has it grabbed, and how many keys it currently
  holds down (counts only — never which keys).

### Turning on the per-key diagnostics (`KB_KILL_DEBUG_KEYS`)

**1. What this is, and why it ships off.** With `KB_KILL_DEBUG_KEYS=1` the daemon
logs a line every time the held portion of a killed group's wake combo changes,
naming the tokens that are still missing and the device the events came from
(plus `deferring grab` / `grabbed` / `released` detail). It is the only way to see
what the daemon sees while a device is grabbed, and it is **off by default
because it fires at key-event rate**. Those lines go to the system journal, which
group `adm` can read (your desktop user is usually in it) and which journald
mirrors into `/var/log/syslog`. Since *any* local process can push a config, a
hostile one — one group per key, each named after its key — would turn these
lines into a keylogger. See [Security model](#security-model).

**2. Enable it in a drop-in.** `KB_KILL_DEBUG_KEYS=1` is the switch — without it
the daemon never writes these lines at all. Raise `LogLevelMax` in the same
drop-in as well: the lines are emitted at syslog priority `debug` (`<7>`), the
shipped unit caps the unit at `info`, and whether that cap actually drops
stderr-derived priorities varies by systemd version. Setting both means it works
either way.

```sh
sudo systemctl edit kb-kill-daemon
```

```ini
[Service]
Environment=KB_KILL_DEBUG_KEYS=1
LogLevelMax=debug
```

**3. Restart — this releases every grab.** The restart wakes everything, so any
group that was killed is now awake:

```sh
sudo systemctl restart kb-kill-daemon
```

**Press your kill combo again to re-arm before you try to reproduce the
problem.** This is the step people trip on: the wake-progress lines only appear
while a group is actually killed.

**4. Watch, and reproduce.**

```sh
journalctl -u kb-kill-daemon -f -o short-precise
```

Press the wake combo one key at a time and watch the tokens register:

```
kb-kill: [laptop] wake progress: 3/4 tokens held (missing: ctrl) - last event from 'input-remapper keyboard'
```

A token that **never** appears, no matter how you press it, means that key is not
reaching kb-kill at all — suspect the keyboard's hardware matrix (some laptop
keyboards physically cannot report certain chords) or an input-remapper mapping
that consumes it, before suspecting kb-kill. Also check *which device* the events
arrive from: if they come from a `...forwarded` virtual device, the group probably
needs `virtual = true`.

**5. Turn it back off — this is a required step.** A drop-in survives reboots and
is invisible unless you go looking, so leaving it on silently keeps the channel
open:

```sh
sudo systemctl revert kb-kill-daemon
sudo systemctl restart kb-kill-daemon
systemctl show kb-kill-daemon -p Environment -p LogLevelMax   # confirm it's clean
```

**6. Consider the history it wrote.** While it was on, keystroke-paced lines were
written both to the journal and to `/var/log/syslog`. Neither is retracted by
turning the switch off. `journalctl --vacuum-time=1h` trims the journal; the
syslog copy is a separate file on its own logrotate schedule.

## Tray icon

`kb-kill-tray` is an optional tray icon (StatusNotifierItem) that shows whether
any group is **disabled** (no checkmark) or **active** (checkmark) and lets you toggle a group by
clicking its menu entry. It is an unprivileged **user** service that never sees
keystrokes and just talks to the root daemon over the control socket
(`/run/kb-kill/control.sock`) — the same socket `kb-kill-push` uses. The daemon
itself is a **root system service** (`systemctl … kb-kill-daemon`, no `--user`). No
config flag is needed (the socket is always on); the tray can only command the
daemon while you are the active user.

It's installed system-wide and enabled for all users by `install.sh`. To toggle it
just for your session:

```sh
systemctl --user start kb-kill-tray    # start now in this session
systemctl --user stop  kb-kill-tray    # or stop it; it returns on next login
```

- Works natively on **COSMIC** and **KDE Plasma**. On **GNOME** it needs the
  [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/)
  (GNOME has no native tray).
- Requires PyGObject with `Gtk 3.0` and `AyatanaAppIndicator3` — install the
  "tray" line for your distro in [Requirements](#requirements).
- The icons are installed to `/usr/local/share/kb-kill/icons/` and the menu lists
  every group from your config, so multiple groups each get their own toggle entry.
  A group's optional `label = "…"` config key sets the text shown here.

The control socket is also a small JSON line protocol if you want to script it:
send `{"cmd":"toggle","group":"<name>"}` (or `kill`/`wake`/`status`) — accepted only
while you are the active user; the service replies/broadcasts
`{"type":"state","groups":[{"name","label","killed","targets"}]}` (`label` is the
group's display label from the config, falling back to the group name).
(Config is delivered the
same way: `{"cmd":"set_config","toml":"<text>"}`, which is what `kb-kill-push` sends.)

## input-remapper coexistence

kb-kill is built to run alongside [input-remapper](https://github.com/sezanzeb/input-remapper).

When input-remapper manages a keyboard it grabs the **physical** device (e.g.
`/dev/input/event3`) and re-emits its events through **virtual** devices:

- a per-keyboard `…forwarded` device for **un-remapped** (passthrough) keys, and
- the shared `input-remapper keyboard` device for the **output of mappings**.

Mark such a group **`virtual = true`** and kb-kill targets the
**forwarded** (virtual) device and **never the physical one**, so input-remapper
can always (re)grab the physical keyboard — including across an input-remapper
restart (kb-kill re-attaches by name). If the forwarded device isn't present
(input-remapper not running), a `virtual` group simply grabs nothing
rather than risk fighting input-remapper for the physical device. (This applies to
pointers too — input-remapper can forward mice — so `virtual` is no longer
keyboard-specific; the old name `virtual_keyboard` remains a deprecated alias.)

Two consequences worth knowing:

1. **Combos are matched globally**, because a single physical keyboard's keys
   can be split across two virtual devices (a remapped modifier on
   `input-remapper keyboard`, the rest on the `…forwarded` device). Per-device
   matching would never see the whole combo.
1. **Remapped keys are not eaten while killed.** kb-kill grabs only the
   forwarded device, not input-remapper's *shared* output device (grabbing that
   would also suppress remapped output from every other device — e.g. mice doing
   workspace switching). So while killed, ordinary typing is eaten but anything
   input-remapper *remaps* still passes through. Use the hotkey's modifiers as
   they exist **after** remapping (e.g. if CapsLock is mapped to Ctrl, press
   CapsLock for the `ctrl` token).

For a keyboard that input-remapper doesn't manage, leave `virtual`
at its default (`false`) and kb-kill grabs the physical keyboard directly.

## Security model

kb-kill reads all keyboard input (and mouse buttons, for pointer groups), so it is
keylogger-*capable*. The design minimizes and contains that:

- **No keystroke content is ever stored or transmitted.** The daemon keeps only
  the set of keys/buttons *currently held* (for combo matching) and discards them
  on release — no history, no file, no network. Pointer **motion** is never
  processed at all (only `EV_KEY` button events are). The control socket carries
  config text + group state (`{name, label, killed, targets}`), **never key
  data**.
  (`kb-kill-daemon monitor` is a manual debug tool that prints to the terminal; the
  service never does.)

- **Nothing keystroke-paced reaches the system journal.** This one needs spelling
  out, because the journal is *not* private: group `adm` can read it (your desktop
  user usually is in it) and journald mirrors it into `/var/log/syslog`. Config
  arrives over a mode-0666 socket and is accepted from any local uid, so the
  daemon's own log is a surface an attacker can shape — a config with one group per
  key, each named after its key, would otherwise make `KILLED`/`WOKEN` a
  timestamped record of everything you type, readable by a process that has no
  access to `/dev/input` at all. Three bounds:

  - Lines that fire at key-event rate are not written at all unless a root
    operator sets `KB_KILL_DEBUG_KEYS=1` on the unit
    ([how, and how to turn it off](#turning-on-the-per-key-diagnostics-kb_kill_debug_keys)).
    Note that removing key *identity* would not have been enough on its own: at
    key rate, the timing alone is a password side channel.
  - State, config and control lines pass through a global token bucket (burst 4,
    then one line per 5 s), so they cannot carry typing regardless of how many
    groups a config defines.
  - Logged text is flattened to one printable, length-capped line, and group
    names/labels are charset-checked — TOML permits a quoted key containing `\n`,
    which would otherwise let any local user forge journal records under
    kb-kill's identifier.

  The deliberate residual is a `suppressed N log line(s)` count at most once a
  minute: coarse evidence that *something* is toggling, with no key identity and
  no per-key timing.

- **Reading input is confined to one process.** Device access lives entirely in
  this single audited, sandboxed root daemon — no ordinary user process needs (or
  is granted) access to your keyboards or mice. Pointer devices are only opened when
  a live config references them (`pointers`/`devices`); a keyboard-only config never
  touches them.

- **The daemon binary is root-owned** (`/usr/local/bin/kb-kill-daemon`), never your
  user-writable working tree — a root service running a user-writable script
  would be a privilege-escalation hole. (Config never executes — it is parsed as
  TOML, and arrives over the socket rather than being read from disk.)

- **systemd sandbox** (`/etc/systemd/system/kb-kill-daemon.service`): no network
  (`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`), only input devices
  (`DevicePolicy=closed` + `DeviceAllow=char-input`), `SystemCallFilter`,
  `MemoryDenyWriteExecute`, `ProtectSystem=strict`, etc. The push model makes the
  sandbox **tighter** than before: config never touches the filesystem, so **all
  capabilities are dropped** (`CapabilityBoundingSet=` empty) and home is invisible
  (`ProtectHome=true`). Even a hypothetical code-injection can't exfiltrate or touch
  other devices.

- **Control socket: always on, per-command authenticated.** It is how config is
  delivered, so it accepts connections from any local user (mode 0666) — but the
  kernel-verified peer uid (`SO_PEERCRED`) gates every command: a pushed config only
  governs the keyboard while that user is the **active** seat user, and only that
  user may kill/wake/toggle. It bounds per-client buffering, total connections, and
  connections per user against DoS, and drops idle connections. Scope is a single
  seat (`seat0`); any process of the active user (not only `kb-kill-push`) can
  command the daemon, which is within that user's own trust boundary.
