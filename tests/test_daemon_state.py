"""When a group's killed/awake state resets, and when it is kept.

State resets only at a login, on a save, or by a hotkey/control call; sleep,
lid close, lock and switching back keep it, and a kill never passes from one
user to another. Drives the real daemon logic with logind, evdev devices and
the control socket faked out. Run: python3 -m unittest discover tests
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

    def __init__(self, name: str, keys: list[int] = KEYS) -> None:
        self.name, self.phys = name, f"phys/{name}"
        self._keys = list(keys)
        self._r, self._w = os.pipe()  # a real fd, so the selector accepts it
        self.fd = self._r
        self.held: set[int] = set()
        self.grabbed = False

    def fileno(self) -> int:
        return self._r

    def capabilities(self) -> dict[int, list[int]]:
        return {ecodes.EV_KEY: self._keys}

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
            mock.patch.object(d.CTRL_LOG, "emit", lambda m, pri=0: None),
            # Same path, other object: the node was re-created (a replug).
            mock.patch.object(
                d.KbKill,
                "_stale",
                staticmethod(lambda path, dev: self.world.get(path) is not dev),
            ),
            mock.patch.object(d.KbKill, "_send", lambda self_, conn, obj: None),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.plug(LAPTOP, "Laptop Keyboard")
        self.plug(USB, "USB Keyboard")
        self.conns: dict[int, Conn] = {}
        self.k = d.KbKill()
        self.addCleanup(self._teardown)

    def _teardown(self) -> None:
        self.k.sel.close()
        for dev in self.made:
            dev.dispose()

    # -- the world ------------------------------------------------------------ #
    def plug(self, path: str, name: str, keys: list[int] = KEYS) -> FakeDev:
        dev = FakeDev(name, keys)
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
        self.assertIn("[b] killed (start_killed)", self.states)

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
