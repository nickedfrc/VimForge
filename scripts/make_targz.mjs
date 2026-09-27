// Create a .tar.gz from a directory using only Node built-ins.
//
// The sandbox this was developed in has no `tar`, and a shelling-out dependency
// would also make the release build fail on a bare Windows machine. The writer
// records mode bits, which matters: the Unix launchers must stay executable after
// extraction.
//
// usage: node make_targz.mjs <source-dir> <output.tar.gz> [entry-name] [--strip-prefix]

import { readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import path from 'node:path';

const [srcDir, outFile, entryName, ...flags] = process.argv.slice(2);
if (!srcDir || !outFile) {
  console.error('usage: node make_targz.mjs <source-dir> <out.tar.gz> [entry-name]');
  process.exit(2);
}

const stripPrefix = flags.includes('--strip-prefix');
const base = path.basename(srcDir);

function pad(buf, size) {
  const out = Buffer.alloc(size, 0);
  buf.copy(out, 0, 0, Math.min(buf.length, size));
  return out;
}

function octal(value, size) {
  // Numeric fields are octal, zero-padded, terminated by NUL or space.
  const s = value.toString(8).padStart(size - 1, '0');
  return Buffer.from(s + '\0', 'ascii');
}

function header(name, size, mode, type) {
  const block = Buffer.alloc(512, 0);
  // name (100), mode (8), uid (8), gid (8), size (12), mtime (12), checksum (8),
  // typeflag (1), linkname (100), magic (6), version (2), uname (32), gname (32),
  // devmajor (8), devminor (8), prefix (155)
  pad(Buffer.from(name, 'utf8'), 100).copy(block, 0);
  octal(mode & 0o7777, 8).copy(block, 100);
  octal(0, 8).copy(block, 108);
  octal(0, 8).copy(block, 116);
  octal(size, 12).copy(block, 124);
  octal(Math.floor(Date.now() / 1000), 12).copy(block, 136);
  block.write('        ', 148, 8, 'ascii'); // checksum placeholder
  block.write(type, 156, 1, 'ascii');
  block.write('ustar\0', 257, 6, 'ascii');
  block.write('00', 263, 2, 'ascii');

  let sum = 0;
  for (let i = 0; i < 512; i++) sum += block[i];
  const chk = sum.toString(8).padStart(6, '0') + '\0 ';
  block.write(chk, 148, 8, 'ascii');
  return block;
}

const chunks = [];

const prefix = stripPrefix ? '' : (entryName || base);
// Launcher scripts must keep their executable bit through extraction; every
// other file is a plain 0644 data file.
const LAUNCHERS = new Set(['vimforge', 'install.sh', 'install.cmd', 'install.ps1', 'vimforge.ps1']);

async function walk(abs, rel) {
  const info = await stat(abs);
  if (info.isDirectory()) {
    chunks.push(header(rel.endsWith('/') ? rel : rel + '/', 0, 0o755, '5'));
    for (const entry of (await readdir(abs, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      await walk(path.join(abs, entry.name), rel + '/' + entry.name);
    }
    return;
  }
  if (!info.isFile()) return; // symlinks are intentionally not archived
  const data = await readFile(abs);
  const fileMode = LAUNCHERS.has(path.basename(rel)) ? 0o755 : 0o644;
  chunks.push(header(rel, data.length, fileMode, '0'));
  chunks.push(data);
  const remainder = data.length % 512;
  if (remainder !== 0) chunks.push(Buffer.alloc(512 - remainder, 0));
}

await walk(srcDir, prefix);

// Two zero blocks terminate the archive.
chunks.push(Buffer.alloc(1024, 0));

const tarBuf = Buffer.concat(chunks);
await writeFile(outFile, gzipSync(tarBuf, { level: 9 }));
const size = (await stat(outFile)).size;
console.log(`wrote ${path.basename(outFile)}  ${(size / 1048576).toFixed(1)} MB  (${tarBuf.length} bytes uncompressed)`);
