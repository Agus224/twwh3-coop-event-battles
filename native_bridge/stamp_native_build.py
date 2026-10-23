"""Record which source produced the compiled DLL; pack builder rejects stale DLLs."""
from pathlib import Path
import hashlib,json

root=Path(__file__).resolve().parent
names=['bridge_core.c','bridge_core.h','ceb_native_bridge.c','native_profile.h','ceb_version.h','ceb_version.rc','build.cmd','VERSION.json']
h=hashlib.sha256()
for name in names: h.update(name.encode());h.update((root/name).read_bytes())
record={'version':json.loads((root/'VERSION.json').read_text())['version'],
        'source_sha256':h.hexdigest(),'inputs':names,
        'dll_sha256':hashlib.sha256((root/'dist/ceb_native_bridge.dll').read_bytes()).hexdigest()}
(root/'dist/native_build.json').write_text(json.dumps(record,indent=2)+'\n')
print('Native build stamped for version',record['version'])
