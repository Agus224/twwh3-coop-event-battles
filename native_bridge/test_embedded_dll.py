"""Checks the DLL embedded in dist/coop_event_battles.pack: the pack member decodes in
Lua 5.1 to the exact bytes of dist/ceb_native_bridge.dll and the companion writes it,
skips rewriting an identical file, and refuses a blob of another version."""
from pathlib import Path
import os, struct, tempfile, shutil, sys, json
from lupa import lua51

root = Path(__file__).resolve().parent
version = json.loads((root / 'VERSION.json').read_text())['version']
dll = (root / 'dist/ceb_native_bridge.dll').read_bytes()
data = (root / (sys.argv[1] if len(sys.argv)>1 else 'dist') / 'coop_event_battles.pack').read_bytes()
flags, deps, dep_size, count, index_size, _ = struct.unpack_from('<6I', data, 4)
p, files = 28 + dep_size, []
for _ in range(count):
    size, = struct.unpack_from('<I', data, p); compressed = data[p + 4]; p += 5
    end = data.index(b'\0', p); files.append((data[p:end].decode(), size, compressed)); p = end + 1
offset, blob = 28 + dep_size + index_size, None
for name, size, compressed in files:
    if name.replace('\\', '/') == 'script/campaign/mod/coop_event_battles_native_blob.lua':
        assert not compressed; blob = data[offset:offset + size]
    offset += size
assert blob, 'blob member missing from the pack'
work = Path(tempfile.mkdtemp()); cwd = os.getcwd(); os.chdir(work)
try:
    L = lua51.LuaRuntime()
    L.globals().network_src = (root / 'network.inc.lua').read_bytes()
    L.globals().blob_src = blob
    L.globals().release_version = version
    # Like the game's mod loader: every mod file runs with setfenv(chunk, env), where env is a
    # separate table that falls back to _G. Globals written by the blob file land in env, not _G.
    result = L.execute('''
      local env = setmetatable({}, {__index = _G})
      local function run(src) local f = assert(loadstring(src)); setfenv(f, env); return f() end
      env.ceb = {version = release_version, log = function() end}
      run(network_src)
      assert(rawget(_G, "ceb") == nil, "test env leaked into _G")
      run(blob_src); assert(rawget(_G, "ceb_native_dll_blob") == nil)
      local a1, d1 = env.ceb:extract_native_dll()
      run(blob_src); local a2, d2 = env.ceb:extract_native_dll()
      run(blob_src); env.ceb_native_dll_blob.version = "other"; local a3, d3 = env.ceb:extract_native_dll()
      local a4, d4 = env.ceb:extract_native_dll()
      _G.ceb_native_dll_blob = nil
      return tostring(a1) .. "|" .. d1 .. "|" .. tostring(a2) .. "|" .. d2 .. "|" .. tostring(a3) .. "|" .. tostring(a4) .. "|" .. d4''')
    parts = result.split('|')
    assert parts[0] == 'true' and 'extracted' in parts[1], result
    assert parts[2] == 'true' and 'up to date' in parts[3], result
    assert parts[4] == 'false', result
    assert parts[5] == 'false' and 'no embedded' in parts[6], result  # blob consumed after use
    assert (work / 'ceb_native_bridge.dll').read_bytes() == dll, 'extracted DLL differs'
    print(f'Embedded DLL OK: {len(dll)} bytes, byte-identical after extraction; rewrite skipped; wrong version refused.')
finally:
    os.chdir(cwd); shutil.rmtree(work, ignore_errors=True)
