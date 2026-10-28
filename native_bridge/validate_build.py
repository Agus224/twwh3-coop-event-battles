"""Validate the built DLL outside the game; never loads it into Warhammer3."""
import os
from pathlib import Path
import ctypes,hashlib,json
import pefile

root=Path(__file__).resolve().parent
release=json.loads((root/'VERSION.json').read_text())
dll=root/'dist/ceb_native_bridge.dll'
data=dll.read_bytes();pe=pefile.PE(data=data)
tests=[]
def check(name,value):
    tests.append({'name':name,'passed':bool(value)})
    if not value: raise AssertionError(name)
check('AMD64 DLL',pe.FILE_HEADER.Machine==0x8664 and bool(pe.FILE_HEADER.Characteristics&0x2000))
version_strings={k.decode():v.decode() for group in getattr(pe,'FileInfo',[]) for item in group
    for table in getattr(item,'StringTable',[]) for k,v in table.entries.items()}
check('DLL file version matches VERSION.json',version_strings.get('FileVersion')==release['version'])
check('DLL product version matches VERSION.json',version_strings.get('ProductVersion')==release['version'])
exports={x.name.decode() for x in pe.DIRECTORY_ENTRY_EXPORT.symbols if x.name}
check('Expected three exports only',exports=={'ceb_bridge_abi_version','ceb_bridge_host_supported','luaopen_ceb_native_bridge'})
imports=sorted({item.name.decode() for dep in pe.DIRECTORY_ENTRY_IMPORT for item in dep.imports if item.name})
forbidden={'WriteProcessMemory','VirtualProtectEx','CreateRemoteThread','VirtualAllocEx','OpenProcess','SetWindowsHookExW'}
check('No remote process injection imports',not (forbidden&set(imports)))
source=(root/'ceb_native_bridge.c').read_text()+(root/'bridge_core.c').read_text()
check('Application source never changes executable page protection','VirtualProtect(' not in source and 'VirtualProtectEx(' not in source)
check('DEP and ASLR enabled',(pe.OPTIONAL_HEADER.DllCharacteristics&0x140)==0x140)
check('No CFG check on raw internal engine calls',not(pe.OPTIONAL_HEADER.DllCharacteristics&0x4000))
module=ctypes.WinDLL(str(dll.resolve()))
module.ceb_bridge_abi_version.restype=ctypes.c_uint
module.ceb_bridge_host_supported.restype=ctypes.c_int
module.luaopen_ceb_native_bridge.argtypes=[ctypes.c_void_p]
module.luaopen_ceb_native_bridge.restype=ctypes.c_int
check('Native ABI version is 1',module.ceb_bridge_abi_version()==1)
check('Rejects non-game host',module.ceb_bridge_host_supported()==0)
check('Rejects null Lua state',module.luaopen_ceb_native_bridge(None)==0)
profile=json.loads((root/'native_profile.json').read_text())
exe=Path(os.environ.get('WH3_GAME_DIR', r'C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III'))/'Warhammer3.exe'
exe_data=exe.read_bytes();exe_pe=pefile.PE(data=exe_data,fast_load=True)
check('Profile matches analyzed executable SHA256',hashlib.sha256(exe_data).hexdigest()==profile['exe_sha256'])
check('Fourteen native entry signatures match file',len(profile['functions'])==14 and all(
    exe_data[exe_pe.get_offset_from_rva(int(item['rva'],16)):][:24].hex()==item['signature']
    for item in profile['functions'].values()))
result={'dll_sha256':hashlib.sha256(data).hexdigest(),'exe_sha256':profile['exe_sha256'],
        'tests':tests,'passed':len(tests),'game_loaded':False,'runtime_join_validated':False,
        'limits':'DLL tested in Python host and native core with simulated engine only. Campaign/control/results require two game clients.',
        'exports':sorted(exports),'imports':imports,
        'static_crt_note':'The statically linked Microsoft C runtime imports VirtualProtect. Bridge application code never calls it or patches executable instructions.'}
(root/'native_validation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
print(f'DLL build checks: {len(tests)}/{len(tests)} passed; not loaded in game.')
