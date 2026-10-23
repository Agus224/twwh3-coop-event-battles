// PFH5 reader for this installed build. Never edits CA packs.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
function readPack(file) {
  const fd = fs.openSync(file, 'r');
  const header = Buffer.alloc(28); fs.readSync(fd, header, 0, 28, 0);
  if (header.toString('ascii', 0, 4) !== 'PFH5') throw Error('Only PFH5 supported');
  const flags = header.readUInt32LE(4);
  if (flags & ~7) throw Error('Unsupported pack flags: ' + flags);
  const depSize = header.readUInt32LE(12), count = header.readUInt32LE(16), indexSize = header.readUInt32LE(20);
  const idx = Buffer.alloc(indexSize); fs.readSync(fd, idx, 0, indexSize, 28 + depSize);
  let p = 0, offset = 28 + depSize + indexSize;
  const entries = [];
  for (let i = 0; i < count; i++) {
    const size = idx.readUInt32LE(p), compressed = idx[p + 4]; p += 5;
    const end = idx.indexOf(0, p); if (end < 0) throw Error('Bad index');
    entries.push({name:idx.toString('utf8', p, end),size,compressed,offset});
    p = end + 1; offset += size;
  }
  if (p !== indexSize || offset !== fs.fstatSync(fd).size) throw Error('Pack bounds mismatch');
  return {entries, read(e) {
    const b = Buffer.alloc(e.size); fs.readSync(fd,b,0,e.size,e.offset);
    if (!e.compressed) return b;
    const out = zlib.zstdDecompressSync(b.subarray(4));
    if (out.length !== b.readUInt32LE(0)) throw Error('Size mismatch');
    return out;
  }, close(){ fs.closeSync(fd); }};
}
function writePack(file, members) {
  const sorted = Object.entries(members).sort(([a],[b])=>a.localeCompare(b));
  const index = [], payload = [];
  for (const [name, data] of sorted) {
    const b = Buffer.isBuffer(data) ? data : Buffer.from(data);
    const h = Buffer.alloc(5); h.writeUInt32LE(b.length);
    index.push(h, Buffer.from(name.replaceAll('/', '\\') + '\0')); payload.push(b);
  }
  const idx = Buffer.concat(index), h = Buffer.alloc(28);
  h.write('PFH5'); h.writeUInt32LE(3,4); h.writeUInt32LE(sorted.length,16); h.writeUInt32LE(idx.length,20);
  fs.writeFileSync(file, Buffer.concat([h,idx,...payload]));
}
module.exports = {readPack,writePack};
if (require.main === module) {
  const [file, pattern = '.', dest] = process.argv.slice(2), re = new RegExp(pattern,'i');
  const pack = readPack(file);
  for (const e of pack.entries.filter(e=>re.test(e.name))) {
    if (dest) {
      const out = path.resolve(dest,...e.name.split('\\'));
      if (!out.startsWith(path.resolve(dest) + path.sep)) throw Error('Unsafe path');
      fs.mkdirSync(path.dirname(out),{recursive:true}); fs.writeFileSync(out,pack.read(e));
    } else console.log(e.name);
  }
  pack.close();
}
