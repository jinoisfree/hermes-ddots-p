"""The remote-session window: find it, capture only that window, and reopen the saved device.

Every call goes through `run`, a subprocess.run-shaped function, so tests observe the exact commands. No call
captures the whole screen, and no call types a credential or accepts a certificate."""
import contextlib
import json
from time import sleep
import subprocess
from pathlib import Path

APP = 'Windows App'
OSASCRIPT = '/usr/bin/osascript'
SCREENCAPTURE = '/usr/sbin/screencapture'
OPEN = '/usr/bin/open'
OPEN_TIMEOUT = 30
LIST_TIMEOUT = 30
CAPTURE_TIMEOUT = 30
RECONNECT_GRACE = 60  # starting the app (up to 20 s), the library window (15 s) and the desktop painting (12 s) come on top of the wait
HERE = Path(__file__).resolve().parent


class CaptureFailed(Exception):
    pass


def list_windows(run=subprocess.run):
    done = run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'windows.js'), APP],
               capture_output=True, text=True, timeout=LIST_TIMEOUT)
    if done.returncode != 0:
        raise CaptureFailed('WINDOW_LIST_FAILED')
    return json.loads(done.stdout)


def pick(windows, device, min_width, min_height):
    """The largest regular window whose title names the device. Small dialogs and the device list never match."""
    named = [w for w in windows if w['layer'] == 0 and device.lower() in w['name'].lower()
             and w['width'] >= min_width and w['height'] >= min_height]
    return max(named, key=lambda w: w['width'] * w['height'], default=None)


def capture(window, path, run=subprocess.run):
    """Save one window's image (`screencapture -l`, never the full screen); the file must exist and be non-empty."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    done = run([SCREENCAPTURE, '-x', '-o', '-l', str(window['number']), str(path)],
               capture_output=True, text=True, timeout=CAPTURE_TIMEOUT)
    if done.returncode != 0 or not path.exists() or path.stat().st_size == 0:
        raise CaptureFailed('CAPTURE_FAILED')
    return path


def reconnect(device, wait_seconds, min_width, min_height, run=subprocess.run):
    """Open the saved device and report one of: connected, prompt (a certificate or login window was cancelled),
    timeout, no_device, no_app. The app may have been quit, not just its session window closed, so it is started
    first (in the background; opening an app that already runs does nothing)."""
    opened = run([OPEN, '-g', '-a', APP], capture_output=True, text=True, timeout=OPEN_TIMEOUT)
    if opened.returncode != 0:
        return {'state': 'no_app', 'text': opened.stderr.strip()[-200:]}
    done = run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'reconnect.js'), device, str(wait_seconds),
                str(min_width), str(min_height)],
               capture_output=True, text=True, timeout=wait_seconds + RECONNECT_GRACE)
    if done.returncode != 0:
        return {'state': 'error', 'text': done.stderr.strip()[-200:]}
    return json.loads(done.stdout)


def input(window, command, box=None, *, dry=False, run=subprocess.run):
    """One allowed input, in window points (independent of capture/Retina pixels). Dry runs never invoke JXA.

    Recheck the window immediately before each input: a gone, moved or resized session cannot receive stale coordinates.
    The script checks the foreground application/window; Session owns activation and restoration for the wake-up.
    """
    from math import isfinite
    if command not in ('right', 'left', 'double', 'escape'):
        raise CaptureFailed('INPUT_COMMAND_INVALID')
    args = [command]
    if command != 'escape':
        if (not isinstance(box, dict) or any(type(box.get(k)) not in (int, float) or not isfinite(box[k]) for k in ('x', 'y', 'w', 'h'))
                or min(box['x'], box['y']) < 0 or min(box['w'], box['h']) <= 0
                or box['x'] + box['w'] > 1 or box['y'] + box['h'] > 1):
            raise CaptureFailed('INPUT_BOX_INVALID')
        x = window['x'] + (box['x'] + box['w'] / 2) * window['width']
        y = window['y'] + (box['y'] + box['h'] / 2) * window['height']
        if not isfinite(x) or not isfinite(y):
            raise CaptureFailed('INPUT_POINT_INVALID')
        args += [str(x), str(y)]
    result = {'command': command, 'point': [float(v) for v in args[1:]], 'dry': dry}
    if dry:
        return result
    current = next((w for w in list_windows(run) if w['number'] == window['number']), None)
    if current is None or current.get('onscreen') is not True or any(current.get(k) != window.get(k) for k in ('x', 'y', 'width', 'height')):
        raise CaptureFailed('INPUT_WINDOW_CHANGED')
    done = run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'click.js'), *args],
               capture_output=True, text=True, timeout=LIST_TIMEOUT)
    if done.returncode != 0:
        raise CaptureFailed('INPUT_FAILED:' + done.stderr.strip()[-200:])
    return result


def dry_control(ask, capture, window, kind, site):
    """Real model location and calculated coordinates, with no mouse/keyboard command or app activation."""
    from . import vision
    located = vision.control(ask, capture, kind, site_label=site['site_label'], channel_label=site['channel_label'], app_icon_label=site.get('app_icon_label'), channel_index=site.get('channel_index'))
    return {**located, 'input': input(window, 'right' if kind == 'item' else ('double' if kind == 'launch' else 'left'), located['box'], dry=True)
            if located['ok'] else None}


class FocusFailed(CaptureFailed):
    pass


class Session:
    """One wake-up owns the focus lease: lazy activation, then exactly one restoration in finally."""
    wait = staticmethod(sleep)

    def __init__(self, site, policy, run=subprocess.run):
        self.site, self.policy, self.run = site, policy, run
        self.previous, self.active, self.data = None, False, None

    @contextlib.contextmanager
    def session(self, data):
        self.data = data
        try:
            yield self
        finally:
            if self.previous is not None:
                try:
                    done = self.run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'focus.js'), 'restore', str(self.previous)],
                                    capture_output=True, text=True, timeout=LIST_TIMEOUT)
                    restored = json.loads(done.stdout) if done.returncode == 0 else {'ok': False, 'reason': 'RESTORE_SCRIPT_FAILED'}
                    data['last_focus']['restored'] = restored.get('ok') is True
                    if not restored.get('ok'):
                        data['last_focus']['restore_error'] = restored.get('reason', 'RESTORE_FAILED')
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    data['last_focus']['restored'] = False
                    data['last_focus']['restore_error'] = type(error).__name__
            self.previous, self.active = None, False

    def windows(self):
        return list_windows(self.run)

    def activate(self):
        if self.active:
            return
        self.data['last_focus'] = {'focused': False, 'restored': False}
        try:
            remembered = self.run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'focus.js'), 'remember'],
                                  capture_output=True, text=True, timeout=LIST_TIMEOUT)
            if remembered.returncode != 0:
                raise FocusFailed('FOCUS_REMEMBER_FAILED')
            self.previous = json.loads(remembered.stdout).get('pid')
            if type(self.previous) is not int or self.previous <= 0:
                self.previous = None
                raise FocusFailed('FOCUS_REMEMBER_INVALID')
            done = self.run([OSASCRIPT, '-l', 'JavaScript', str(HERE / 'focus.js'), 'focus', self.site['rdp_device'],
                             str(self.policy['min_window_width']), str(self.policy['min_window_height'])],
                            capture_output=True, text=True, timeout=LIST_TIMEOUT)
            result = json.loads(done.stdout) if done.returncode == 0 else {'ok': False, 'reason': 'FOCUS_SCRIPT_FAILED'}
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise FocusFailed('FOCUS_FAILED:' + type(error).__name__) from error
        self.previous = result.get('previous', {}).get('pid', self.previous)
        self.data['last_focus'] = {'focused': result.get('ok') is True, 'restored': False}
        if not result.get('ok'):
            raise FocusFailed(str(result.get('reason', 'FOCUS_FAILED')))
        self.active = True

    def prepare(self, window):
        self.activate()
        found = next((w for w in self.windows() if w['number'] == window['number']), None)
        if found is None or found.get('onscreen') is not True:
            raise FocusFailed('SESSION_NOT_VISIBLE')
        return found

    def capture(self, window, path):
        return capture(window, path, run=self.run)

    def input(self, window, command, box=None):
        self.activate()
        return input(window, command, box, run=self.run)


if __name__ == '__main__':
    import argparse
    from . import settings, vision
    parser = argparse.ArgumentParser(description='CCTV control location only: never sends input')
    parser.add_argument('--dry', choices=('item', 'live', 'plus', 'launch', 'expand'), required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--window', type=Path, required=True, help='Saved window metadata JSON')
    options = parser.parse_args()
    print(json.dumps(dry_control(vision.model_caller(), options.capture, json.loads(options.window.read_text()),
                                 options.dry, settings.site()), ensure_ascii=False))
