// Validate the built release archives the way a user's machine would see them:
// decompress, list the contents, and check the structure and mode bits.
//
// usage: node scripts/verify_archives.mjs <dist-dir>

import { readdir, stat } from 'node:fs/promises';
import { gunzipSync, inflateRawSync } from 'node:zlib';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const DIST = path.resolve(process.argv[2] || 'dist');

function octal(buf, off, len) {
  const s = buf.subarray(off, off + len).toString('ascii').replace(/\0.*$/, '').trim();
  return s === '' ? 0 : parseInt(s, 8) || 0;
}

function listTar(buf) {
  const out = [];
  let off = 0;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    if (header.every((b) => b === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
    const prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/, '');
    const size = octal(header, 124, 12);
    const mode = octal(header, 100, 8);
    const type = String.fromCharCode(header[156]);
    out.push({ name: prefix ? `${prefix}/${name}` : name, size, mode, type });
    off += 512 + Math.ceil(size / 512) * 512;
  }
  return out;
}

function listZip(buf) {
  // Walk the central directory for a reliable listing.
  let eocd = buf.length - 22;
  while (eocd > 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd <= 0) throw new Error('no end-of-central-directory record');
  const count = buf.readUInt16LE(eocd + 10);
  let cd = buf.readUInt32LE(eocd + 16);
  const out = [];
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(cd + 10);
    const compSize = buf.readUInt32LE(cd + 20);
    const uncompSize = buf.readUInt32LE(cd + 24);
    const nameLen = buf.readUInt16LE(cd + 28);
    const extraLen = buf.readUInt16LE(cd + 30);
    const commentLen = buf.readUInt16LE(cd + 32);
    const attrs = buf.readUInt32LE(cd + 38);
    const name = buf.subarray(cd + 46, cd + 46 + nameLen).toString('utf8');
    out.push({ name, compSize, uncompSize, method, mode: (attrs >>> 16) & 0o777 });
    cd += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

const files = (await readdir(DIST)).filter((f) => /\.(zip|tar\.gz)$/.test(f)).sort();
if (files.length === 0) {
  console.error('no archives found in ' + DIST);
  process.exit(1);
}

// Both launchers and the config must be present in every bundle.
const REQUIRED = [
  'install.sh',
  'README.txt',
  'VERSION',
  'CREDITS.md',
  'SHA256SUMS',
  'nvim-deepseek-studio/init.lua',
  'nvim-deepseek-studio/lua/dshstudio/core/session.lua',
  'nvim-deepseek-studio/lua/dshstudio/core/auth.lua',
  'nvim-deepseek-studio/lua/dshstudio/project/analysis.lua',
  'docs/INSTALL.md',
  'docs/ACP.md',
];

let failures = 0;

for (const file of files) {
  const full = path.join(DIST, file);
  const size = (await stat(full)).size;
  console.log(`\n=== ${file}  (${(size / 1048576).toFixed(1)} MB)`);
  const raw = await readFile(full);

  let entries;
  let root;
  if (file.endsWith('.zip')) {
    entries = listZip(raw);
    root = entries[0].name.split('/')[0];
    console.log(`  format: zip, ${entries.length} entries, root "${root}"`);
  } else {
    entries = listTar(gunzipSync(raw));
    root = entries[0].name.split('/')[0];
    console.log(`  format: tar.gz, ${entries.length} entries, root "${root}"`);
  }

  const names = new Set(entries.map((e) => (e.name.startsWith(root + '/') ? e.name.slice(root.length + 1) : e.name)));

  // Required content.
  let missing = 0;
  for (const want of REQUIRED) {
    if (!names.has(want)) {
      console.log(`  MISSING ${want}`);
      missing++;
    }
  }
  if (missing === 0) console.log(`  all ${REQUIRED.length} required paths present`);
  failures += missing;

  // A bundled Neovim runtime must be inside.
  const nvimEntries = entries.filter((e) => /(^|\/)nvim(\/|\.exe$)/.test(e.name) || /nvim(\.exe)?$/.test(e.name));
  const hasBinary = entries.some((e) => /nvim(\.exe)?$/.test(e.name) && (e.size || e.uncompSize) > 1000000);
  console.log(`  bundled Neovim binary: ${hasBinary ? 'yes' : 'NO'}  (${nvimEntries.length} nvim paths)`);
  if (!hasBinary) failures++;

  // Neovide is bundled on Windows and Linux (macOS upstream ships only a .dmg,
  // so that bundle carries a fetcher script instead). Report which it is.
  const neovideEntry = entries.find((e) => /neovide(\/neovide|\.exe)?$/.test(e.name) && (e.size || e.uncompSize) > 1000000);
  if (neovideEntry) {
    console.log(`  bundled Neovide: yes (${(neovideEntry.size || neovideEntry.uncompSize) / 1048576 | 0} MB) at ${neovideEntry.name.slice(root.length + 1)}`);
    if (file.endsWith('.tar.gz')) {
      const executable = (neovideEntry.mode & 0o111) !== 0;
      console.log(`    mode ${neovideEntry.mode.toString(8)} ${executable ? 'executable' : 'NOT EXECUTABLE'}`);
      if (!executable) failures++;
    }
  } else {
    const fetcher = [...names].some((n) => n.includes('get-neovide'));
    console.log(`  bundled Neovide: no  (fetcher script present: ${fetcher ? 'yes' : 'NO'})`);
    if (!fetcher) failures++;
  }

  // Launchers must be executable in the tar archives; zip carries the bit in
  // external attributes, which Windows ignores anyway.
  if (file.endsWith('.tar.gz')) {
    for (const script of ['vimforge', 'install.sh']) {
      const entry = entries.find((e) => e.name === `${root}/${script}`);
      const mode = entry ? entry.mode : 0;
      const executable = (mode & 0o111) !== 0;
      console.log(`  ${script}: mode ${mode.toString(8)} ${executable ? 'executable' : 'NOT EXECUTABLE'}`);
      if (!executable) failures++;
    }
  }

  // Sanity: the archive must not contain a nested archive or the staging temp.
  const junk = entries.filter((e) => /\.tmp-|\.stage/.test(e.name));
  if (junk.length) {
    console.log(`  unexpected staging entries: ${junk.length}`);
    failures += junk.length;
  }
}

// The checksum file must match the archives.
const sums = (await readFile(path.join(DIST, 'SHA256SUMS.txt'), 'utf8')).trim().split('\n');
console.log(`\n=== SHA256SUMS.txt covers ${sums.length} files`);
for (const line of sums) {
  const [hash, name] = line.split(/\s+/);
  const { createHash } = await import('node:crypto');
  const h = createHash('sha256');
  h.update(await readFile(path.join(DIST, name)));
  const actual = h.digest('hex');
  const okHash = actual === hash;
  console.log(`  ${okHash ? 'ok  ' : 'BAD '} ${name}`);
  if (!okHash) failures++;
}

console.log(failures === 0 ? '\nVERIFY: PASS' : `\nVERIFY: ${failures} problem(s)`);
process.exit(failures === 0 ? 0 : 1);
