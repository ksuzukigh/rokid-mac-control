#!/usr/bin/env python3
"""Developer-only rebuild of the checked-in Android helper, using the installed SDK."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
sdk = Path(os.environ.get("ANDROID_SDK_ROOT", "/opt/homebrew/share/android-commandlinetools"))
jdk = subprocess.check_output(["/usr/libexec/java_home", "-v", "17"], text=True).strip()
out = root / "build/device-helper"
out.mkdir(parents=True, exist_ok=True)
source = root / "DeviceHelper/RokidUiReader.java"
subprocess.run([jdk + "/bin/javac", "-source", "8", "-target", "8", "-cp", str(sdk / "platforms/android-35/android.jar"),
                "-d", str(out / "classes"), str(source)], check=True)
subprocess.run([jdk + "/bin/jar", "cf", str(out / "classes.jar"), "-C", str(out / "classes"), "."], check=True)
subprocess.run([str(sdk / "build-tools/35.0.0/d8"), "--min-api", "24", "--output", str(out), str(out / "classes.jar")], check=True)
artifact = root / "Resources/rokid_ui_reader.jar"
subprocess.run([jdk + "/bin/jar", "cf", str(artifact), "-C", str(out), "classes.dex"], check=True)
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(root / "DeviceHelper/checksums.json").write_text(json.dumps({"source_sha256": digest(source), "jar_sha256": digest(artifact)}, indent=2) + "\n")
