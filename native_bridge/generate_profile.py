"""Generate a reviewable profile for the one analyzed executable; no game writes."""
import os
from pathlib import Path
import hashlib,json,sys
import pefile

root=Path(__file__).resolve().parent
target=Path(os.environ.get('WH3_GAME_DIR', r'C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III'))/'Warhammer3.exe'
data=target.read_bytes()
# Patch 9.0.5 (Steam build 26403568). The 1.1.2 profile was 9bd58c63... (build 25961564);
# every function below is byte-identical to that build except for relocated call targets.
expected='d2a8a58288bf8bd86768f21ff6be036cebb1916f9c312999c60afc1abe13789f'
actual=hashlib.sha256(data).hexdigest()
if actual!=expected: raise SystemExit('Executable differs from analyzed version; profile not generated')
pe=pefile.PE(data=data,fast_load=True)
entries={
    'allocate':0x004f38e0,'release':0x00509184,
    'destroy_cohort':0x0267c988,'construct_cohort':0x0266eb78,
    'append_cohort':0x02648688,'prepare_character':0x026bbec8,
    'observe_force':0x01c41354,'initialize_cohort':0x026a1264,
    'lookup_force':0x01c705e0,'at_war':0x026c0848,
    'reinforcement_direction':0x02698abc,
    'make_force_data':0x0266fcc4,'push_force_data':0x026458c0,'destroy_force_data':0x0267ca50,
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
