"""Bump release before shipping changed content: 1.1 -> 1.1.1 -> 1.1.2."""
import argparse,json
from prepare_version import ROOT,prepare

p=argparse.ArgumentParser()
p.add_argument('part',nargs='?',choices=['patch','minor','major'],default='patch')
args=p.parse_args()
release=json.loads((ROOT/'VERSION.json').read_text())
previous=release['version'];parts=[int(x) for x in previous.split('.')]
parts += [0]*(3-len(parts))
if args.part=='major': parts=[parts[0]+1,0,0]
elif args.part=='minor': parts=[parts[0],parts[1]+1,0]
else: parts[2]+=1
release['version']='.'.join(map(str,parts))
(ROOT/'VERSION.json').write_text(json.dumps(release,indent=2)+'\n')
prepare()
print(previous,'->',release['version'],'; regenerate companion, compile DLL and build pack.')
