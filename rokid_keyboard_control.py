#!/usr/bin/env python3

import argparse
import os
import re
import subprocess
import threading
import time

import ApplicationServices
import Quartz
from AppKit import NSRunningApplication
from pynput import keyboard


DOUBLE_TAP_INTERVAL = 0.35


class ReliableKeyboardListener(keyboard.Listener):
    def __init__(self, *args, **kwargs):
        self.event_tap = None
        self.target_is_scrcpy = False
        super().__init__(*args, **kwargs)

    def _create_event_tap(self):
        self.event_tap = super()._create_event_tap()
        return self.event_tap

    def _handler(self, proxy, event_type, event, refcon):
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            if self.event_tap is not None:
                Quartz.CGEventTapEnable(self.event_tap, True)
                print("キーボード入力監視を自動復旧しました。", flush=True)
            return event

        target_pid = Quartz.CGEventGetIntegerValueField(
            event,
            Quartz.kCGEventTargetUnixProcessID,
        )
        target_app = NSRunningApplication.runningApplicationWithProcessIdentifier_(
            target_pid
        )
        target_name = (target_app.localizedName() or "").lower() if target_app else ""
        self.target_is_scrcpy = target_name == "scrcpy"
        return super()._handler(proxy, event_type, event, refcon)

    def ensure_enabled(self):
        if self.event_tap is None or Quartz.CGEventTapIsEnabled(self.event_tap):
            return False
        Quartz.CGEventTapEnable(self.event_tap, True)
        return True


class RokidKeyboardController:
    def __init__(self, serial):
        self.serial = serial
        self.width, self.height = self._get_screen_size()
        self.pressed = set()
        self.state_lock = threading.RLock()
        self.action_lock = threading.Lock()
        self.space_timer = None
        self.listener = None

    def _adb(self, *args):
        subprocess.run(
            ["adb", "-s", self.serial, *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )

    def _get_screen_size(self):
        result = subprocess.run(
            ["adb", "-s", self.serial, "shell", "wm", "size"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        match = re.search(r"(\d+)\s*[x×]\s*(\d+)", result.stdout or result.stderr or "")
        return (int(match.group(1)), int(match.group(2))) if match else (480, 640)

    def _run_action(self, action):
        threading.Thread(target=self._locked_action, args=(action,), daemon=True).start()

    def _locked_action(self, action):
        with self.action_lock:
            action()

    def _tap_center(self):
        print("スペース：画面中央をタップ", flush=True)
        self._adb("shell", "input", "tap", str(self.width // 2), str(self.height // 2))

    def _double_tap_center(self):
        print("スペース2回：画面中央をダブルタップ", flush=True)
        self._adb("shell", "input", "tap", str(self.width // 2), str(self.height // 2))
        time.sleep(0.08)
        self._adb("shell", "input", "tap", str(self.width // 2), str(self.height // 2))

    def _select_left(self):
        print("← 左の項目", flush=True)
        self._adb("shell", "input", "keyevent", "KEYCODE_DPAD_LEFT")

    def _select_right(self):
        print("→ 右の項目", flush=True)
        self._adb("shell", "input", "keyevent", "KEYCODE_DPAD_RIGHT")

    def _open_bottom_icon(self, horizontal_offset):
        self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
        self._adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(0.35)
        self._adb(
            "shell",
            "input",
            "tap",
            str(self.width // 2 + horizontal_offset),
            str(self.height // 2),
        )

    def _select_bottom_left(self):
        print("Shift+←：下段の左アイコン", flush=True)
        self._open_bottom_icon(-(self.width // 15))

    def _select_bottom_right(self):
        print("Shift+→：下段の右アイコン", flush=True)
        self._open_bottom_icon(self.width // 15)

    def _confirm_selection(self):
        print("Enter：決定・起動", flush=True)
        self._adb("shell", "input", "keyevent", "KEYCODE_ENTER")

    def _go_back(self):
        print("Esc：一つ前の画面へ戻る", flush=True)
        self._adb("shell", "input", "keyevent", "KEYCODE_BACK")

    def _go_home(self):
        print("H：中央のHomeへ戻る", flush=True)
        self._open_bottom_icon(0)

    def _single_space_timeout(self):
        with self.state_lock:
            self.space_timer = None
        self._run_action(self._tap_center)

    def _handle_space(self):
        with self.state_lock:
            if self.space_timer is not None:
                self.space_timer.cancel()
                self.space_timer = None
                is_double = True
            else:
                self.space_timer = threading.Timer(
                    DOUBLE_TAP_INTERVAL,
                    self._single_space_timeout,
                )
                self.space_timer.daemon = True
                self.space_timer.start()
                is_double = False

        if is_double:
            self._run_action(self._double_tap_center)

    def on_press(self, key):
        if self.listener is None or not self.listener.target_is_scrcpy:
            return

        with self.state_lock:
            if key in self.pressed:
                return
            self.pressed.add(key)
            shift_pressed = any(
                shift_key in self.pressed
                for shift_key in (
                    keyboard.Key.shift,
                    keyboard.Key.shift_l,
                    keyboard.Key.shift_r,
                )
            )

        if key == keyboard.Key.left:
            self._run_action(
                self._select_bottom_left if shift_pressed else self._select_left
            )
        elif key == keyboard.Key.right:
            self._run_action(
                self._select_bottom_right if shift_pressed else self._select_right
            )
        elif key == keyboard.Key.space:
            self._handle_space()
        elif key == keyboard.Key.enter:
            self._run_action(self._confirm_selection)
        elif key == keyboard.Key.esc:
            self._run_action(self._go_back)
        elif getattr(key, "char", None) and key.char.lower() == "h":
            self._run_action(self._go_home)

    def on_release(self, key):
        with self.state_lock:
            self.pressed.discard(key)

    def run(self):
        print("キーボード操作を開始しました。")
        print("←/→ 上段アプリ / Enter 決定 / Esc 戻る / H 中央のHome")
        print("Shift+← メモ / Shift+→ アプリ一覧")
        print("スペース 画面中央 / 素早く2回でダブルタップ")
        self.listener = ReliableKeyboardListener(
            on_press=self.on_press,
            on_release=self.on_release,
        )
        listener = self.listener
        listener.start()
        listener.wait()
        try:
            while listener.running:
                if listener.ensure_enabled():
                    print("キーボード入力監視を自動復旧しました。", flush=True)
                time.sleep(1)
        finally:
            listener.stop()
            listener.join()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    args = parser.parse_args()

    if not ApplicationServices.AXIsProcessTrusted():
        ApplicationServices.AXIsProcessTrustedWithOptions(
            {ApplicationServices.kAXTrustedCheckOptionPrompt: True}
        )
        permission_target = (
            "Rokid Control"
            if os.environ.get("ROKID_GUI_MODE") == "1"
            else "ターミナル"
        )
        print(
            "Macの『アクセシビリティ』で"
            f"{permission_target}の操作を許可してください。"
        )
        return 2

    RokidKeyboardController(args.serial).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
