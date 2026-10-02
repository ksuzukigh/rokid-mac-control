import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
checks = json.loads((root / "DeviceHelper/checksums.json").read_text())
source = root / "DeviceHelper/RokidUiReader.java"
jar = root / "Resources/rokid_ui_reader.jar"
assert hashlib.sha256(source.read_bytes()).hexdigest() == checks["source_sha256"], "Rebuild Android helper after source edits"
assert hashlib.sha256(jar.read_bytes()).hexdigest() == checks["jar_sha256"], "Android helper artifact changed"
with zipfile.ZipFile(jar) as z:
    assert set(z.namelist()) == {"META-INF/", "META-INF/MANIFEST.MF", "classes.dex"}
    dex = z.read("classes.dex")
    assert dex.startswith(b"dex\n")
    assert b"com.rokid.os.sprite.launcher:id/indicator" in dex
assert "FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES" in source.read_text()
print("Device helper source/artifact checks passed")
