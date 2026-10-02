import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
original = (root / "Resources/rokid_r08_direction_bridge.sh").read_text()
with tempfile.TemporaryDirectory(prefix="rokid-ring-test-") as folder:
    p = Path(folder)
    (p / "bin").mkdir()
    source = original
    for key, device in [("PIDFILE", "rokid_control_r08_direction.pid"), ("LOGFILE", "rokid_control_r08_direction.log"), ("FIFO", "rokid_control_r08_direction.fifo")]:
        source = source.replace(key + "=/data/local/tmp/" + device, key + "=" + str(p / key.lower()))
    script = p / "bridge.sh"
    script.write_text(source)
    mocks = {
        "date": 'if [ ! -f "$TEST_CLOCK" ]; then echo first > "$TEST_CLOCK"; echo 1800000000; else echo 1800000004; fi',
        "dumpsys": 'cat "$TEST_FOREGROUND"',
        "input": 'printf "%s\\n" "$*" >> "$TEST_INPUT"',
        "logcat": 'cat "$TEST_LINES"',
    }
    for name, body in mocks.items():
        f = p / "bin" / name
        f.write_text("#!/bin/sh\n" + body + "\n")
        f.chmod(0o700)
    lines = p / "lines"
    lines.write_text("""1800000000.100 10064 111 111 D R08Bridge: R08 forward from key:87 launcherSteps=1
1800000004.100 99999 111 111 D R08Bridge: R08 forward from key:87 launcherSteps=1
1800000004.100 10064 111 111 D R08Bridge: R08 forward from adb-key:87 launcherSteps=1
1800000004.100 10064 111 111 D R08Bridge: R08 forward from key:87 launcherSteps=1
1800000004.200 10064 111 111 D R08Bridge: R08 backward from key:88 launcherSteps=1
""")
    env = dict(os.environ, PATH=str(p / "bin") + ":/usr/bin:/bin", TEST_CLOCK=str(p / "clock"), TEST_FOREGROUND=str(p / "foreground"), TEST_INPUT=str(p / "input"), TEST_LINES=str(lines))
    for component, expected in [
        ("com.rokid.os.sprite.launcher/.page.volume.SettingVolumeActivity", ["keyevent 22", "keyevent 21"]),
        ("com.rokid.os.sprite.launcher/.page.brightness.SettingBrightnessActivity", ["keyevent 22", "keyevent 21"]),
        ("other.app/.MainActivity", []),
        ("com.rokid.os.sprite.launcher/.page.volume.SettingVolumeActivityExtra", []),
    ]:
        (p / "foreground").write_text("topResumedActivity=ActivityRecord{123 u0 " + component + " t4}\nHist #1: com.rokid.os.sprite.launcher/.page.volume.SettingVolumeActivity\n")
        for f in [p / "clock", p / "input"]:
            if f.exists(): f.unlink()
        r = subprocess.run(["/bin/sh", str(script), "run", "10064"], env=env, capture_output=True, text=True, timeout=8)
        actual = (p / "input").read_text().splitlines() if (p / "input").exists() else []
        assert r.returncode == 0 and actual == expected, (component, actual, r.stderr)
print("R08 bridge UID, freshness, real-key and foreground checks passed")
