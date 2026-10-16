"""When a group's killed/awake state resets, and when it is kept.

State resets only at a login, on a save, or by a hotkey/control call (and a
kill is refused when nothing can type the wake hotkey); sleep, lid close,
lock and switching back keep it (unless a group sets wake_on_lock: then the
lock wakes it and the unlock kills it again), and a kill never passes from
one user to another. Drives the real daemon logic with logind, evdev devices
and the control socket faked out. Run: python3 -m unittest discover tests
"""

import importlib.machinery
import importlib.util
import os
import types
import unittest
from pathlib import Path
from unittest import mock

try:
    from evdev import ecodes  # pyright: ignore[reportMissingImports]
except ImportError:
    raise unittest.SkipTest("python-evdev is required") from None

DAEMON = Path(__file__).resolve().parent.parent / "scripts" / "kb-kill-daemon"
_loader = importlib.machinery.SourceFileLoader("kb_kill_daemon", str(DAEMON))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
assert _spec is not None
d = importlib.util.module_from_spec(_spec)
_loader.exec_module(d)

ALICE, BOB, GREETER = 1000, 1001, 42
LAPTOP, USB = "/dev/input/event2", "/dev/input/event5"
KEYS = [
    ecodes.KEY_A,
    ecodes.KEY_Z,
    ecodes.KEY_ENTER,
    ecodes.KEY_K,
    ecodes.KEY_U,
    ecodes.KEY_J,
    ecodes.KEY_LEFTCTRL,
    ecodes.KEY_LEFTALT,
]
ABS_XY = {ecodes.EV_ABS: [ecodes.ABS_X, ecodes.ABS_Y]}  # touch, joystick, tilt
KILL_A = (ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTALT, ecodes.KEY_K)
WAKE = (ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTALT, ecodes.KEY_U)

# Group a is awake at start; group b is start_killed. Distinct kill combos,
# a shared wake combo (it wakes whichever is killed).
CONFIG = """\
wake_combo = "ctrl+alt+u"

[groups.a]
keyboards = "Laptop Keyboard"
kill_combo = "ctrl+alt+k"

[groups.b]
keyboards = "USB Keyboard"
kill_combo = "ctrl+alt+j"
start_killed = true
"""

# Bob's own group "a" targets the same keyboard as Alice's: same name, his state.
BOB_CONFIG = """\
kill_combo = "ctrl+alt+k"
wake_combo = "ctrl+alt+u"

[groups.a]
keyboards = "Laptop Keyboard"
"""


class FakeDev:
    """An evdev InputDevice as far as the daemon uses one."""

    def __init__(
        self,
        name: str,
        keys: list[int] = KEYS,
        rel: bool = False,
        axes: dict[int, list[int]] | None = None,
    ) -> None:
        self.name, self.phys = name, f"phys/{name}"
        self._keys = list(keys)
        self._rel = rel  # relative motion: a mouse
        self._axes = axes or {}  # any other axes, by event type (ABS_XY, ...)
        self._r, self._w = os.pipe()  # a real fd, so the selector accepts it
        self.fd = self._r
        self.held: set[int] = set()
        self.grabbed = False

    def fileno(self) -> int:
        return self._r

    def capabilities(self, absinfo: bool = True) -> dict[int, list[int]]:
        caps = {ecodes.EV_KEY: self._keys}
        if self._rel:
            caps[ecodes.EV_REL] = [ecodes.REL_X, ecodes.REL_Y]
        caps.update(self._axes)
        return caps

    def active_keys(self) -> list[int]:
        return sorted(self.held)

    def grab(self) -> None:
        self.grabbed = True

    def ungrab(self) -> None:
        self.grabbed = False

    def close(self) -> None:
        self.grabbed = False  # the kernel drops a grab with its fd

    def dispose(self) -> None:
        os.close(self._r)
        os.close(self._w)


class Conn:
    """A control-socket peer; the daemon only ever writes to it here."""

    def close(self) -> None:
        pass


class DaemonTest(unittest.TestCase):
    def setUp(self) -> None:
        self.world: dict[str, FakeDev] = {}  # /dev/input as the kernel has it
        self.made: list[FakeDev] = []
        self.seat: dict[str, int] = {}  # logind: active session -> uid
        self.sessions: set[str] = set()  # logind: every session that exists
        self.young: set[str] = set()  # sessions created moments ago
        self.states: list[str] = []  # killed/awake journal lines
        self.ctrl: list[str] = []  # config/device/warning journal lines

        def open_dev(path: str) -> FakeDev:
            if path not in self.world:
                raise OSError(2, "gone")
            return self.world[path]

        patches = [
            mock.patch.object(d, "list_devices", lambda: sorted(self.world)),
            mock.patch.object(d, "InputDevice", open_dev),
            mock.patch.object(d, "mask_to_keys", lambda fd: None),
            mock.patch.object(d, "active_sessions", lambda: dict(self.seat)),
            mock.patch.object(d, "_existing_sessions", lambda: set(self.sessions)),
            mock.patch.object(d, "_is_new_session", lambda sid: sid in self.young),
            mock.patch.object(d, "log_state", lambda m, pri=0: self.states.append(m)),
            mock.patch.object(d.CTRL_LOG, "emit", lambda m, pri=0: self.ctrl.append(m)),
            # Same path, other object: the node was re-created (a replug).
            mock.patch.object(
                d.KbKill,
                "_stale",
                staticmethod(lambda path, dev: self.world.get(path) is not dev),
            ),
            mock.patch.object(
                d.KbKill,
                "_send",
                lambda self_, conn, obj: self.sent.append((conn, obj)),
            ),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.plug(LAPTOP, "Laptop Keyboard")
        self.plug(USB, "USB Keyboard")
        self.conns: dict[int, Conn] = {}
        self.sent: list[tuple[Conn, dict]] = []  # what the daemon wrote, to whom
        self.k = d.KbKill()
        self.addCleanup(self._teardown)

    def _teardown(self) -> None:
        self.k.sel.close()
        for dev in self.made:
            dev.dispose()

    # -- the world ------------------------------------------------------------ #
    def plug(
        self,
        path: str,
        name: str,
        keys: list[int] = KEYS,
        rel: bool = False,
        axes: dict[int, list[int]] | None = None,
    ) -> FakeDev:
        dev = FakeDev(name, keys, rel, axes)
        self.made.append(dev)
        self.world[path] = dev
        return dev

    def unplug(self, path: str) -> None:
        self.world.pop(path).close()

    def boot(self) -> None:
        """What KbKill.run does before its loop."""
        self.k._reevaluate_live()
        self.k.rescan()

    def activate(self, sid: str, uid: int, new: bool = True) -> None:
        """logind makes `sid` the seat's foreground session (a login if new)."""
        if new:
            self.sessions.add(sid)
        self.seat = {sid: uid}
        self.k._reevaluate_live()

    def seat_idle(self) -> None:
        """logind reports no foreground session, as across suspend and lock."""
        self.seat = {}
        self.k._reevaluate_live()

    def push(self, uid: int, text: str = CONFIG) -> None:
        conn = self.conns.setdefault(uid, Conn())
        self.k.clients.setdefault(
            conn,  # type: ignore[arg-type]
            {"buf": b"", "uid": uid, "born": 0.0, "hello": True, "debug": False},
        )
        self.k._on_set_config(uid, text, conn)  # type: ignore[arg-type]

    def disconnect(self, uid: int) -> None:
        self.k._drop_client(self.conns.pop(uid))  # type: ignore[arg-type]

    def command(self, uid: int, cmd: str, group: str) -> None:
        self.k._apply_command({"cmd": cmd, "group": group}, Conn(), uid)  # type: ignore[arg-type]

    def locked(self, uid: int) -> None:
        """kb-kill-push saw `uid`'s screen lock."""
        self.k._apply_command({"cmd": "locked"}, Conn(), uid)  # type: ignore[arg-type]

    def unlocked(self, uid: int) -> None:
        """kb-kill-push saw `uid`'s screen unlock."""
        self.k._apply_command({"cmd": "unlocked"}, Conn(), uid)  # type: ignore[arg-type]

    def key(self, path: str, code: int, value: int) -> None:
        """One key event on one device (1 down, 0 up)."""
        (self.world[path].held.add if value else self.world[path].held.discard)(code)
        self.k._process(
            path, types.SimpleNamespace(type=ecodes.EV_KEY, code=code, value=value)
        )

    def press(self, path: str, keys: tuple[int, ...]) -> None:
        """Hold `keys` in order on one device, then let go in reverse."""
        dev = self.world[path]
        for value, order in ((1, keys), (0, tuple(reversed(keys)))):
            for code in order:
                (dev.held.add if value else dev.held.discard)(code)
                self.k._process(
                    path,
                    types.SimpleNamespace(type=ecodes.EV_KEY, code=code, value=value),
                )

    def login_alice(self) -> None:
        """Alice logs in after the daemon is up and pushes her config."""
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE)

    # -- assertions ----------------------------------------------------------- #
    def assertState(self, **want: bool) -> None:
        self.assertEqual({g.name: g.killed for g in self.k.groups}, want)

    def assertGrabbed(self, *paths: str) -> None:
        grabbed = {p for p, dev in self.world.items() if dev.grabbed}
        self.assertEqual(grabbed, set(paths))
        self.assertEqual(self.k.grabbed, set(paths))


class Login(DaemonTest):
    def test_login_after_boot_starts_start_killed_groups_killed(self) -> None:
        self.login_alice()
        self.assertEqual(self.k.live_uid, ALICE)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)
        self.assertIn("[b] killed (1 device(s)) (start_killed)", self.states)

    def test_login_already_active_at_daemon_start_counts(self) -> None:
        """The daemon comes up at boot while the session is seconds old."""
        self.sessions.add("2")
        self.young.add("2")
        self.seat = {"2": ALICE}
        self.boot()
        self.push(ALICE)
        self.assertState(a=False, b=True)

    def test_daemon_restart_mid_session_starts_awake(self) -> None:
        """An old session at daemon start is a restart, not a login."""
        self.sessions.add("2")
        self.seat = {"2": ALICE}
        self.boot()
        self.push(ALICE)
        self.assertState(a=False, b=False)
        self.assertGrabbed()

    def test_second_session_of_the_same_user_is_a_login(self) -> None:
        self.login_alice()
        self.command(ALICE, "wake", "b")
        self.assertState(a=False, b=False)
        self.activate("3", ALICE)  # another login, e.g. on a second VT
        self.assertState(a=False, b=True)

    def test_start_killed_refused_when_no_device_can_type_the_wake_hotkey(self) -> None:
        self.unplug(USB)
        self.unplug(LAPTOP)
        no_u = [c for c in KEYS if c != ecodes.KEY_U]
        self.plug(LAPTOP, "Laptop Keyboard", no_u)
        self.plug(USB, "USB Keyboard", no_u)
        self.login_alice()
        self.assertState(a=False, b=False)
        self.assertGrabbed()


class Save(DaemonTest):
    def test_save_while_live_is_a_restart(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.command(ALICE, "wake", "b")
        self.assertState(a=True, b=False)
        self.push(ALICE, CONFIG + "\n")  # kb-kill-push re-sends on every edit
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)

    def test_save_while_another_user_holds_the_seat_restarts_on_return(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.command(ALICE, "wake", "b")
        self.activate("4", BOB)  # Bob has no config: the seat idles
        self.push(ALICE, CONFIG + "\n")
        self.activate("2", ALICE, new=False)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)


class SleepAndLock(DaemonTest):
    def test_seat_idle_across_sleep_keeps_state(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)
        self.seat_idle()
        self.assertEqual(self.k.live_uid, None)
        self.assertGrabbed()  # a grab never outlives its (live) config
        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)
        self.assertIn("[a] killed (kept)", self.states)

    def test_an_awake_group_stays_awake_after_sleep(self) -> None:
        """start_killed is not re-applied: waking b by hand sticks."""
        self.login_alice()
        self.command(ALICE, "wake", "b")
        self.seat_idle()
        self.activate("2", ALICE, new=False)
        self.assertState(a=False, b=False)
        self.assertGrabbed()

    def test_lock_screen_in_a_greeter_session_keeps_state(self) -> None:
        """A lock that hands the seat to the greeter (no config) and back."""
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.activate("c1", GREETER)
        self.assertGrabbed()
        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)

    def test_keyboard_replugged_across_sleep_is_grabbed_again(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.seat_idle()
        self.unplug(LAPTOP)  # USB re-enumerates on resume
        self.k.rescan()
        self.plug(LAPTOP, "Laptop Keyboard")
        self.k.rescan()
        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)

    def test_seat_back_before_the_keyboard_keeps_the_kill(self) -> None:
        """No lockout check on resume: the kill waits for its device."""
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.seat_idle()
        self.unplug(LAPTOP)
        self.unplug(USB)
        self.k.rescan()
        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.plug(LAPTOP, "Laptop Keyboard")
        self.plug(USB, "USB Keyboard")
        self.k.rescan()
        self.assertGrabbed(LAPTOP, USB)

    def test_keyboard_lost_while_live_is_grabbed_on_return(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.unplug(LAPTOP)
        self.k.rescan()
        self.assertState(a=True, b=True)
        self.plug(LAPTOP, "Laptop Keyboard")
        self.k.rescan()
        self.assertGrabbed(LAPTOP, USB)


class UserSwitch(DaemonTest):
    def test_each_user_gets_back_only_their_own_state(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.assertGrabbed(LAPTOP, USB)

        self.activate("4", BOB)
        self.push(BOB, BOB_CONFIG)
        self.assertEqual(self.k.live_uid, BOB)
        self.assertState(a=False)  # Alice's kill of "a" is not Bob's
        self.assertGrabbed()
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True)

        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)
        self.command(ALICE, "wake", "a")

        self.activate("4", BOB, new=False)
        self.assertState(a=True)  # Bob's own kill, kept while he was away
        self.assertGrabbed(LAPTOP)

    def test_a_dormant_user_cannot_kill_or_wake(self) -> None:
        self.login_alice()
        self.push(BOB, BOB_CONFIG)
        self.command(BOB, "kill", "a")
        self.assertState(a=False, b=True)


class Explicit(DaemonTest):
    def test_hotkey_kills_and_wakes(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)
        self.press(LAPTOP, WAKE)  # the shared wake hotkey wakes both
        self.assertState(a=False, b=False)
        self.assertGrabbed()

    def test_control_kill_wake_toggle(self) -> None:
        self.login_alice()
        self.command(ALICE, "kill", "a")
        self.assertState(a=True, b=True)
        self.command(ALICE, "toggle", "b")
        self.assertState(a=True, b=False)
        self.command(ALICE, "wake", "a")
        self.assertState(a=False, b=False)
        self.assertGrabbed()


# Alice's config with wake_on_lock on group a only.
LOCK_CONFIG = CONFIG.replace(
    'kill_combo = "ctrl+alt+k"\n', 'kill_combo = "ctrl+alt+k"\nwake_on_lock = true\n'
)


class WakeOnLock(DaemonTest):
    def test_lock_wakes_only_wake_on_lock_groups(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True, b=True)
        self.locked(ALICE)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)
        self.assertIn("[a] awake (screen locked)", self.states)

    def test_lock_without_wake_on_lock_keeps_state(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)

    def test_lock_while_dormant_wakes_on_return(self) -> None:
        """A switch to another user locks the session left behind."""
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.activate("4", BOB)
        self.locked(ALICE)
        self.activate("2", ALICE, new=False)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)

    def test_another_users_lock_leaves_the_live_user_alone(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.push(BOB, BOB_CONFIG)
        self.locked(BOB)
        self.locked(GREETER)  # no config at all
        self.assertState(a=True, b=True)

    def test_unlock_kills_again_what_the_lock_woke(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.unlocked(ALICE)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)
        self.assertIn("[a] killed (1 device(s)) (screen unlocked)", self.states)

    def test_unlock_without_a_lock_changes_nothing(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.unlocked(ALICE)
        self.assertState(a=False, b=True)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.unlocked(ALICE)
        self.unlocked(ALICE)  # a second unlock signal for the same unlock
        self.assertState(a=True, b=True)

    def test_unlock_keeps_a_group_that_was_awake_at_lock_awake(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.locked(ALICE)
        self.unlocked(ALICE)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)

    def test_a_choice_made_while_locked_stands(self) -> None:
        """Killed again, or killed and woken with the hotkey, while locked:
        the unlock leaves it as chosen."""
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.command(ALICE, "kill", "a")
        self.command(ALICE, "wake", "a")
        self.unlocked(ALICE)
        self.assertState(a=False, b=True)

    def test_save_while_locked_forgets_the_lock(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.push(
            ALICE, LOCK_CONFIG.replace("start_killed = true", "start_killed = false")
        )
        self.unlocked(ALICE)
        self.assertState(a=False, b=False)

    def test_unlock_waits_for_the_enter_key(self) -> None:
        """The key that submits the password is still down when the locker
        lets go: the grab waits for its release."""
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.key(LAPTOP, ecodes.KEY_ENTER, 1)
        self.unlocked(ALICE)
        self.assertState(a=True, b=True)
        self.assertGrabbed(USB)
        self.key(LAPTOP, ecodes.KEY_ENTER, 0)
        self.assertGrabbed(LAPTOP, USB)

    def test_unlock_while_dormant_kills_on_return(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.activate("4", BOB)
        self.locked(ALICE)
        self.unlocked(ALICE)
        self.activate("2", ALICE, new=False)
        self.assertState(a=True, b=True)
        self.assertGrabbed(LAPTOP, USB)

    def test_save_while_locked_waits_for_the_unlock(self) -> None:
        """A background save behind the lock screen must not take the keyboard
        the password is typed on: start_killed waits for the unlock."""
        self.login_alice()
        self.push(
            ALICE, LOCK_CONFIG.replace("[groups.b]", "[groups.b]\nwake_on_lock = true")
        )
        self.locked(ALICE)
        self.push(
            ALICE, LOCK_CONFIG.replace("[groups.b]", "[groups.b]\nwake_on_lock = true")
        )
        self.assertState(a=False, b=False)
        self.assertGrabbed()
        self.unlocked(ALICE)
        self.assertState(a=False, b=True)
        self.assertGrabbed(USB)

    def test_save_while_locked_still_kills_other_groups(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.locked(ALICE)
        self.push(ALICE, LOCK_CONFIG)
        self.assertState(a=False, b=True)  # b has no wake_on_lock

    def test_a_dormant_users_lock_and_unlock_log_nothing(self) -> None:
        """Any uid with a config may send these; the journal bucket is shared."""
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.activate("4", BOB)
        self.states.clear()
        for _ in range(3):
            self.locked(ALICE)
            self.unlocked(ALICE)
        self.assertEqual(self.states, [])

    def test_unlock_while_dormant_checks_the_wake_hotkey_on_return(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.activate("4", BOB)
        self.unlocked(ALICE)
        for path in (LAPTOP, USB):  # every device that can type the wake hotkey
            self.unplug(path)
        self.k.rescan()
        self.activate("2", ALICE, new=False)
        self.assertState(a=False, b=True)  # b's kill is kept, not new: unchecked
        self.assertIn(
            "[a] not killed: no device can type its wake hotkey (screen unlocked)",
            self.states,
        )

    def test_lock_across_a_switch_then_unlock(self) -> None:
        """Locked when switching away, unlocked on the way back."""
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.activate("4", BOB)
        self.activate("2", ALICE, new=False)
        self.assertState(a=False, b=True)
        self.unlocked(ALICE)
        self.assertState(a=True, b=True)

    def test_another_users_unlock_leaves_the_live_user_alone(self) -> None:
        self.login_alice()
        self.push(ALICE, LOCK_CONFIG)
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.push(BOB, BOB_CONFIG)
        self.unlocked(BOB)
        self.unlocked(GREETER)
        self.assertState(a=False, b=True)

    def test_wake_on_lock_must_be_a_bool(self) -> None:
        with self.assertRaises(d.ConfigError):
            d.load_config_text(
                CONFIG.replace("start_killed = true", 'wake_on_lock = "yes"'), "t"
            )


MOUSE, MEDIA, VIDEO = "/dev/input/event9", "/dev/input/event6", "/dev/input/event7"

# A keyboard group woken with a mouse button: no group targets pointers.
MOUSE_WAKE = """\
[groups.a]
keyboards = "Laptop Keyboard"
kill_combo = "ctrl+alt+k"
wake_combo = "ctrl+alt+mouseleft"
"""

# Woken with a key only a keyboard's separate media node has.
MEDIA_WAKE = """\
[groups.a]
devices = "*"
kill_combo = "ctrl+alt+k"
wake_combo = "ctrl+mute"
"""


class NoKillWithoutWay(DaemonTest):
    """A kill needs a device the daemon reads that has every wake key."""

    def test_mouse_button_in_a_keyboard_groups_wake_hotkey(self) -> None:
        self.plug(MOUSE, "Some Mouse", [ecodes.BTN_LEFT, ecodes.BTN_RIGHT], rel=True)
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE)
        self.assertIn(MOUSE, self.k.devices)
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True)
        self.assertGrabbed(LAPTOP)  # read for its button, never a target
        self.key(LAPTOP, ecodes.KEY_LEFTCTRL, 1)
        self.key(LAPTOP, ecodes.KEY_LEFTALT, 1)
        self.key(MOUSE, ecodes.BTN_LEFT, 1)
        self.assertState(a=False)

    def test_wake_key_on_a_separate_media_node(self) -> None:
        self.plug(MEDIA, "USB Keyboard Consumer Control", [ecodes.KEY_MUTE])
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MEDIA_WAKE)
        self.assertIn(MEDIA, self.k.devices)
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True)
        self.assertGrabbed(LAPTOP, USB, MEDIA)  # killed, yet still read
        self.key(LAPTOP, ecodes.KEY_LEFTCTRL, 1)
        self.key(MEDIA, ecodes.KEY_MUTE, 1)
        self.assertState(a=False)

    def test_switch_is_not_read(self) -> None:
        self.plug(VIDEO, "Lid Switch", [])  # EV_SW only: no keys, no axes
        self.login_alice()
        self.assertNotIn(VIDEO, self.k.devices)

    def test_hotkey_kill_refused_when_the_wake_hotkey_cannot_be_typed(self) -> None:
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE)  # no mouse plugged in
        self.press(LAPTOP, KILL_A)
        self.assertState(a=False)
        self.assertGrabbed()
        self.assertIn("[a] not killed: no device can type its wake hotkey", self.states)

    def test_unlock_refuses_to_kill_again_once_the_wake_device_is_gone(self) -> None:
        self.plug(MOUSE, "Some Mouse", [ecodes.BTN_LEFT, ecodes.BTN_RIGHT], rel=True)
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE + "wake_on_lock = true\n")
        self.press(LAPTOP, KILL_A)
        self.locked(ALICE)
        self.unplug(MOUSE)
        self.k.rescan()
        self.unlocked(ALICE)
        self.assertState(a=False)
        self.assertGrabbed()
        self.assertIn(
            "[a] not killed: no device can type its wake hotkey (screen unlocked)",
            self.states,
        )

    def test_control_kill_refused_when_the_wake_hotkey_cannot_be_typed(self) -> None:
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE)
        self.command(ALICE, "kill", "a")
        self.command(ALICE, "toggle", "a")
        self.assertState(a=False)
        self.assertGrabbed()

    def test_refused_kill_tells_the_live_users_clients(self) -> None:
        """No state changes, so no state message: the tray needs its own
        word to show the warning OSD."""
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE)
        self.push(BOB, BOB_CONFIG)
        self.sent.clear()
        self.press(LAPTOP, KILL_A)
        refused = [(c, m) for c, m in self.sent if m["type"] == "refused"]
        self.assertEqual(
            refused,
            [
                (
                    self.conns[ALICE],
                    {
                        "type": "refused",
                        "group": "a",
                        "label": "a",
                        "reason": "no device can type its wake hotkey",
                    },
                )
            ],
        )

    def test_start_killed_refusal_tells_the_live_users_clients(self) -> None:
        """A refused start_killed warns like a refused hotkey: one rule."""
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, MOUSE_WAKE + "start_killed = true\n")
        self.assertState(a=False)
        self.assertIn(
            "[a] not killed: no device can type its wake hotkey (start_killed)",
            self.states,
        )
        self.assertIn(
            "refused", [m["type"] for c, m in self.sent if c is self.conns[ALICE]]
        )

    def test_preview_agrees_with_the_live_check(self) -> None:
        self.login_alice()
        cfg = d.load_config_text(MOUSE_WAKE, "t")
        self.assertEqual(self.k._preview(cfg)["wakeable"], {"a": False})
        self.plug(MOUSE, "Some Mouse", [ecodes.BTN_LEFT], rel=True)
        self.assertEqual(self.k._preview(cfg)["wakeable"], {"a": True})


class WakeHint(DaemonTest):
    """Someone keeps pressing a killed device: the tray is told how to wake it,
    rate-limited, and the journal hears nothing. Group b starts killed, so
    the USB keyboard is grabbed from login on."""

    def setUp(self) -> None:
        super().setUp()
        self.now = 1000.0
        clock = mock.patch.object(d.time, "monotonic", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.login_alice()
        self.assertGrabbed(USB)
        self.sent.clear()
        self.states.clear()
        self.ctrl.clear()

    def mash(
        self, path: str, presses: int, every: float = 0.1, key: int = ecodes.KEY_A
    ) -> None:
        for _ in range(presses):
            self.press(path, (key,))
            self.now += every

    def hints(self) -> list[dict]:
        return [m for _c, m in self.sent if m["type"] == "wake_hint"]

    def test_mashing_a_killed_device_tells_the_live_user_how_to_wake_it(self) -> None:
        self.mash(USB, d.WAKE_HINT_PRESSES)
        self.assertEqual(
            [(c, m) for c, m in self.sent if m["type"] == "wake_hint"],
            [
                (
                    self.conns[ALICE],
                    {
                        "type": "wake_hint",
                        "group": "b",
                        "label": "b",
                        "wake": "ctrl+alt+u",
                    },
                )
            ],
        )
        self.assertEqual((self.states, self.ctrl), ([], []))  # never journaled

    def test_too_few_or_too_slow_presses_say_nothing(self) -> None:
        self.mash(USB, d.WAKE_HINT_PRESSES - 1)
        self.now += d.WAKE_HINT_WINDOW
        self.mash(USB, d.WAKE_HINT_PRESSES, every=d.WAKE_HINT_WINDOW)
        self.assertEqual(self.hints(), [])

    def test_at_most_one_hint_per_cooldown(self) -> None:
        self.mash(USB, d.WAKE_HINT_PRESSES)
        self.mash(USB, d.WAKE_HINT_PRESSES)
        self.assertEqual(len(self.hints()), 1)
        self.now += d.WAKE_HINT_COOLDOWN
        self.mash(USB, d.WAKE_HINT_PRESSES)
        self.assertEqual(len(self.hints()), 2)

    def test_the_press_that_wakes_is_not_counted(self) -> None:
        self.mash(USB, d.WAKE_HINT_PRESSES - len(WAKE))
        self.press(USB, WAKE)  # its last key would be the hint's last press
        self.assertState(a=False, b=False)
        self.assertEqual(self.hints(), [])

    def test_tapping_a_killed_touchscreen_hints_too(self) -> None:
        """A tap arrives as BTN_TOUCH, so it counts like a key press."""
        self.plug(TOUCH, "Some Touchscreen", [ecodes.BTN_TOUCH], axes=ABS_XY)
        self.k.rescan()
        self.push(ALICE, POINTERS)
        self.press(LAPTOP, KILL_A)
        self.mash(TOUCH, d.WAKE_HINT_PRESSES, key=ecodes.BTN_TOUCH)
        self.assertEqual([h["group"] for h in self.hints()], ["a"])

    def test_awake_device_says_nothing(self) -> None:
        self.mash(LAPTOP, d.WAKE_HINT_PRESSES)
        self.assertEqual(self.hints(), [])

    def test_deferred_grab_says_nothing(self) -> None:
        """Its keys still reach the OS: it is not dead yet."""
        self.key(LAPTOP, ecodes.KEY_J, 1)
        self.command(ALICE, "kill", "a")
        self.assertGrabbed(USB)
        self.mash(LAPTOP, d.WAKE_HINT_PRESSES)
        self.assertEqual(self.hints(), [])


TOUCH, STICK, TILT = "/dev/input/event11", "/dev/input/event12", "/dev/input/event13"
DIAL, PEDALS, PAD = "/dev/input/event14", "/dev/input/event15", "/dev/input/event16"

POINTERS = """\
[groups.a]
pointers = "*"
kill_combo = "ctrl+alt+k"
wake_combo = "ctrl+alt+u"
"""


class Pointers(DaemonTest):
    """What `pointers` targets: relative or absolute X/Y motion."""

    def setUp(self) -> None:
        super().setUp()
        self.plug(MOUSE, "Some Mouse", [ecodes.BTN_LEFT], rel=True)
        self.plug(TOUCH, "Some Touchscreen", [ecodes.BTN_TOUCH], axes=ABS_XY)
        self.plug(VIDEO, "Buttonless Trackball", [], rel=True)
        self.plug(STICK, "Some Joystick", [ecodes.BTN_TRIGGER], axes=ABS_XY)
        self.plug(TILT, "Some Accelerometer", [], axes=ABS_XY)
        self.plug(
            DIAL, "Some Dial", [ecodes.BTN_0], axes={ecodes.EV_REL: [ecodes.REL_DIAL]}
        )
        self.plug(PEDALS, "Some Pedals", [], axes={ecodes.EV_ABS: [ecodes.ABS_Z]})
        self.plug(
            MEDIA,
            "USB Keyboard Consumer Control",
            [ecodes.KEY_MUTE],
            axes={
                ecodes.EV_REL: [ecodes.REL_HWHEEL],
                ecodes.EV_ABS: [ecodes.ABS_VOLUME],
            },
        )
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, POINTERS)

    def test_kill_grabs_everything_with_an_axis_but_media_keys(self) -> None:
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True)
        self.assertGrabbed(MOUSE, TOUCH, VIDEO, STICK, TILT, DIAL, PEDALS)
        self.press(LAPTOP, WAKE)
        self.assertState(a=False)
        self.assertGrabbed()

    def test_grab_waits_for_a_finger_to_lift(self) -> None:
        self.key(TOUCH, ecodes.BTN_TOUCH, 1)
        self.press(LAPTOP, KILL_A)
        self.assertGrabbed(MOUSE, VIDEO, STICK, TILT, DIAL, PEDALS)
        self.key(TOUCH, ecodes.BTN_TOUCH, 0)
        self.assertGrabbed(MOUSE, TOUCH, VIDEO, STICK, TILT, DIAL, PEDALS)

    def test_a_pointer_with_a_key_is_both_classes(self) -> None:
        """So the settings window offers it as a pointer, too."""
        mouse = self.plug(VIDEO, "Mouse With Mute", [ecodes.KEY_MUTE], rel=True)
        self.assertEqual(d.device_classes(mouse), ["kbd", "ptr"])
        self.assertEqual(d.device_classes(self.world[TOUCH]), ["ptr"])
        self.assertEqual(d.device_classes(self.world[LAPTOP]), ["kbd"])


KEYBOARDS = """\
[groups.a]
keyboards = "*"
kill_combo = "ctrl+alt+k"
wake_combo = "ctrl+alt+u"
"""


class Keyboards(DaemonTest):
    """What `keyboards` targets: anything with a KEY_* code, not only BTN_*."""

    def test_kill_grabs_every_device_with_keys(self) -> None:
        self.plug(PAD, "Some Numpad", [ecodes.KEY_KP1, ecodes.KEY_KPENTER])
        self.plug(MEDIA, "USB Keyboard Consumer Control", [ecodes.KEY_MUTE])
        self.plug(VIDEO, "Power Button", [ecodes.KEY_POWER])
        mouse_buttons = list(
            range(ecodes.BTN_LEFT, ecodes.BTN_LEFT + 16)
        )  # 0x110-0x11f
        self.plug(MOUSE, "Some Mouse", mouse_buttons, rel=True)
        self.plug(STICK, "Lid Switch", [])
        self.boot()
        self.activate("2", ALICE)
        self.push(ALICE, KEYBOARDS)
        self.press(LAPTOP, KILL_A)
        self.assertState(a=True)
        self.assertGrabbed(LAPTOP, USB, PAD, MEDIA, VIDEO)  # no mouse, no switch
        self.press(LAPTOP, WAKE)
        self.assertState(a=False)
        self.assertGrabbed()


class PushRestart(DaemonTest):
    def test_push_restart_drops_state_and_starts_awake(self) -> None:
        self.login_alice()
        self.press(LAPTOP, KILL_A)
        self.disconnect(ALICE)
        self.assertEqual(self.k.live_uid, None)
        self.assertGrabbed()
        self.push(ALICE)  # the restarted kb-kill-push, same session
        self.assertState(a=False, b=False)
        self.assertGrabbed()


if __name__ == "__main__":
    unittest.main()
