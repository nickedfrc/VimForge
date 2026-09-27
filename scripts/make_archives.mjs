// Package the staged release bundles into distributable archives.
//
// Windows gets a .zip (the native expectation on that platform); macOS and Linux
// get .tar.gz, which preserves the executable bit the launchers need. Both are
// produced with Node built-ins so the release build works without `tar` or `zip`
// on PATH, and SHA256SUMS.txt covers the archives.
//
// usage: node scripts/make_archives.mjs <dist-dir>

import { readdir, readFile, stat, writeFile, rm } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { gzipSync, deflateRawSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const DIST = path.resolve(process.argv[2] || 'dist');
const STAGE = path.join(DIST, '.stage');
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Minimal ZIP writer (deflate, no zip64 - these archives stay well under 4 GB)
// ---------------------------------------------------------------------------
function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[i] = c;
    }
  }
  let crc = -1;
  for (let i = 0; i < buf.length; i++) crc = (crc >>> 8) ^ table[(crc ^ buf[i]) & 0xff];
  return (crc ^ -1) >>> 0;
}

async function writeZip(srcDir, outFile) {
  const entries = [];
  const rootName = path.basename(srcDir);
  async function walk(abs, rel) {
    for (const entry of (await readdir(abs, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(abs, entry.name);
      const relPath = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        // Record the directory itself so extraction recreates the tree instead of
        // scattering 2000+ files into the user's current folder.
        entries.push({ relPath: relPath.replace(/\\/g, '/') + '/', abs: null, isDir: true });
        await walk(full, relPath);
      } else if (entry.isFile()) {
        entries.push({ relPath: `${rootName}/${relPath}`.replace(/\\/g, '/'), abs: full, isDir: false });
      }
    }
  }
  await walk(srcDir, '');

  const locals = [];
  const central = [];
  let offset = 0;

  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.relPath, 'utf8');
    const data = entry.isDir ? Buffer.alloc(0) : await readFile(entry.abs);
    const crc = crc32(data);
    let payload = data;
    let method = 0;
    if (!entry.isDir) {
      const deflated = deflateRawSync(data, { level: 9 });
      if (deflated.length < data.length) {
        payload = deflated;
        method = 8;
      }
    }

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);       // version needed
    local.writeUInt16LE(0, 6);        // flags
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10);       // time
    local.writeUInt16LE(0x21, 12);    // date (1980-01-01)
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);       // extra length
    locals.push(local, nameBuf, payload);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);          // version made by
    cd.writeUInt16LE(20, 6);          // version needed
    cd.writeUInt16LE(0, 8);
    cd.writeUInt16LE(method, 10);
    cd.writeUInt16LE(0, 12);
    cd.writeUInt16LE(0x21, 14);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(payload.length, 20);
    cd.writeUInt32LE(data.length, 24);
    cd.writeUInt16LE(nameBuf.length, 28);
    cd.writeUInt16LE(0, 30);          // extra
    cd.writeUInt16LE(0, 32);          // comment
    cd.writeUInt16LE(0, 34);          // disk
    cd.writeUInt16LE(0, 36);          // internal attrs
    // Mark scripts executable so an unzip on Unix keeps them runnable.
    const isScript = /\.(sh|bash|cmd|ps1)$/i.test(entry.relPath) || !path.extname(entry.relPath);
    const externalAttrs = (isScript ? 0o755 : 0o644) << 16;
    cd.writeUInt32LE(externalAttrs >>> 0, 38);
    cd.writeUInt32LE(offset, 42);
    central.push(cd, nameBuf);

    offset += local.length + nameBuf.length + payload.length;
  }

  const centralStart = offset;
  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(centralStart, 16);
  eocd.writeUInt16LE(0, 20);

  await writeFile(outFile, Buffer.concat([...locals, centralBuf, eocd]));
  const size = (await stat(outFile)).size;
  console.log(`  ${path.basename(outFile)}  ${(size / 1048576).toFixed(1)} MB  (${entries.length} files)`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const dirs = (await readdir(STAGE, { withFileTypes: true }))
  .filter((e) => e.isDirectory())
  .map((e) => e.name)
  .sort();

if (dirs.length === 0) {
  console.error('nothing staged in ' + STAGE + ' - run build_release_bundles.mjs first');
  process.exit(1);
}

const { execFileSync } = await import('node:child_process');

for (const dir of dirs) {
  const src = path.join(STAGE, dir);
  if (/windows/.test(dir)) {
    await writeZip(src, path.join(DIST, `${dir}.zip`));
  } else {
    const out = path.join(DIST, `${dir}.tar.gz`);
    // Reuse the standalone tar writer so the extraction semantics (mode bits)
    // stay in one place.
    execFileSync(process.execPath, [path.join(SCRIPT_DIR, 'make_targz.mjs'), src, out, dir], { stdio: 'inherit' });
  }
}

// Checksums over the archives.
const sums = [];
for (const f of (await readdir(DIST)).sort()) {
  if (f.startsWith('.')) continue;
  const full = path.join(DIST, f);
  if (!(await stat(full)).isFile()) continue;
  if (f === 'SHA256SUMS.txt') continue;
  const h = createHash('sha256');
  h.update(await readFile(full));
  sums.push(`${h.digest('hex')}  ${f}`);
}
await writeFile(path.join(DIST, 'SHA256SUMS.txt'), sums.join('\n') + '\n');
console.log(`\nSHA256SUMS.txt:\n${sums.join('\n')}`);
