"""Generate a reviewable profile for the one analyzed executable; no game writes."""
from pathlib import Path
import hashlib,json,sys
import pefile

root=Path(__file__).resolve().parent
target=root.parent.parent/'Warhammer3.exe'
data=target.read_bytes()
expected='9bd58c63bd7fc5c9909b3d3d9b6b7a6ae4eac784369bf91a9e53c3e9f42be496'
actual=hashlib.sha256(data).hexdigest()
if actual!=expected: raise SystemExit('Executable differs from analyzed version; profile not generated')
pe=pefile.PE(data=data,fast_load=True)
entries={
    'allocate':0x004d3da0,'release':0x004e98d4,
    'destroy_cohort':0x02676658,'construct_cohort':0x026687b4,
    'append_cohort':0x02642468,'prepare_character':0x026b5c78,
    'observe_force':0x01c3adf0,'initialize_cohort':0x0269af00,
    'lookup_force':0x01c6a30c,'at_war':0x026ba60c,
    'reinforcement_direction':0x02692774,
    'make_force_data':0x02669900,'push_force_data':0x0263f6b0,'destroy_force_data':0x02676720,
}
manifest={'exe_sha256':actual,'image_size':pe.OPTIONAL_HEADER.SizeOfImage,
          'timestamp':pe.FILE_HEADER.TimeDateStamp,'functions':{}}
lines=['/* Generated from the exact analyzed Warhammer3.exe. Do not relax checks. */',
       '#ifndef CEB_NATIVE_PROFILE_H','#define CEB_NATIVE_PROFILE_H',
       f'#define CEB_EXPECTED_IMAGE_SIZE 0x{pe.OPTIONAL_HEADER.SizeOfImage:x}u',
       f'#define CEB_EXPECTED_TIMESTAMP 0x{pe.FILE_HEADER.TimeDateStamp:x}u',
       f'#define CEB_EXPECTED_SHA256 "{actual}"',
       'typedef struct { const char *name; unsigned long rva; unsigned char bytes[24]; } CebSignature;',
       'static const CebSignature ceb_signatures[] = {']
for name,rva in entries.items():
    off=pe.get_offset_from_rva(rva);sig=data[off:off+24]
    manifest['functions'][name]={'rva':hex(rva),'signature':sig.hex()}
    lines.append('    {"%s",0x%x,{%s}},'%(name,rva,','.join('0x%02x'%b for b in sig)))
lines+=['};','#endif','']
(root/'native_profile.h').write_text('\n'.join(lines),encoding='utf8')
(root/'native_profile.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
print('Exact executable profile verified:',actual)
