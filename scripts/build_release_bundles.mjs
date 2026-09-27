// Build self-contained portable bundles for Windows, macOS and Linux.
//
// Each bundle carries the configuration, the install scripts, the docs and the
// platform's official Neovim binary, so extracting it is enough to run - no
// installer, no network, no package manager.
//
// usage: node scripts/build_release_bundles.mjs <output-dir> [--with-neovide]

import { mkdir, writeFile, readFile, readdir, stat, rm, cp } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { execFileSync } from 'node:child_process';

const OUT = path.resolve(process.argv[2] || 'dist');
// This script lives in <repo>/scripts, so the config directory is its sibling.
// fileURLToPath decodes the percent-encoded path (the checkout lives under a
// directory with non-ASCII characters).
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_DIR = path.join(SCRIPT_DIR, '..');
const REPO_ROOT = path.dirname(CONFIG_DIR);
const VERSION = process.env.BUNDLE_VERSION || '0.1.0';
const NVIM_VERSION = process.env.NVIM_VERSION || 'stable';

const PLATFORMS = [
  {
    id: 'windows-x64',
    label: 'Windows x64',
    neovim: {
      url: `https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-win64.zip`,
      format: 'zip',
    },
  },
  {
    id: 'macos-universal',
    label: 'macOS (Intel and Apple Silicon)',
    // Two separate upstream assets; the bundle ships both and the launcher picks.
    neovim: [
      {
        name: 'arm64',
        url: `https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-macos-arm64.tar.gz`,
        format: 'tar.gz',
      },
      {
        name: 'x86_64',
        url: `https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-macos-x86_64.tar.gz`,
        format: 'tar.gz',
      },
    ],
  },
  {
    id: 'linux-x86_64',
    label: 'Linux x86_64',
    neovim: {
      url: `https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz`,
      format: 'tar.gz',
      // Older releases used this name; fall back if the primary 404s.
      fallback: `https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux64.tar.gz`,
    },
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function download(url, dest, fallback) {
  const urls = fallback ? [url, fallback] : [url];
  for (const candidate of urls) {
    const res = await fetch(candidate, { redirect: 'follow' });
    if (!res.ok) {
      console.log(`    ${path.basename(candidate)} -> HTTP ${res.status}`);
      continue;
    }
    const total = Number(res.headers.get('content-length') || 0);
    await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
    const size = (await stat(dest)).size;
    console.log(`    downloaded ${path.basename(dest)} (${(size / 1048576).toFixed(1)} MB of ${(total / 1048576).toFixed(1)} MB)`);
    if (total && size !== total) throw new Error(`truncated download: ${size} != ${total}`);
    return true;
  }
  return false;
}

// Minimal tar (ustar) reader, so extraction needs no child process.
function octal(buf, off, len) {
  const s = buf.subarray(off, off + len).toString('ascii').replace(/\0.*$/, '').trim();
  return s === '' ? 0 : parseInt(s, 8) || 0;
}

function parseTar(buf) {
  const entries = [];
  let off = 0;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    if (header.every((b) => b === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
    const size = octal(header, 124, 12);
    const type = String.fromCharCode(header[156]);
    const prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/, '');
    const full = prefix ? `${prefix}/${name}` : name;
    const dataStart = off + 512;
    entries.push({
      name: full,
      type,
      mode: octal(header, 100, 8),
      data: type === '0' || type === '\0' || type === '' ? buf.subarray(dataStart, dataStart + size) : null,
    });
    off = dataStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

async function extractTarGz(buffer, destDir) {
  const { gunzipSync } = await import('node:zlib');
  const entries = parseTar(gunzipSync(buffer));
  const roots = new Set(entries.map((e) => e.name.split('/')[0]));
  const strip = roots.size === 1 ? [...roots][0] + '/' : '';
  for (const entry of entries) {
    if (strip && !entry.name.startsWith(strip)) continue;
    const rel = strip ? entry.name.slice(strip.length) : entry.name;
    if (!rel) continue;
    const target = path.join(destDir, rel);
    if (!path.resolve(target).startsWith(path.resolve(destDir))) continue;
    if (entry.type === '5') {
      await mkdir(target, { recursive: true });
    } else if (entry.data) {
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, entry.data, { mode: entry.mode || 0o644 });
    }
  }
}

// ---------------------------------------------------------------------------
// Bundle assembly
// ---------------------------------------------------------------------------

async function copyTree(from, to, skip = new Set()) {
  await mkdir(to, { recursive: true });
  for (const entry of await readdir(from, { withFileTypes: true })) {
    if (skip.has(entry.name)) continue;
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) {
      await copyTree(src, dst, skip);
    } else if (entry.isFile()) {
      await cp(src, dst);
    }
  }
}

const README = (platform) => `VimForge ${VERSION} - portable bundle for ${platform.label}
=====================================================================

This bundle is self-contained: it includes the configuration AND the official
Neovim binary, so you do not need to install anything else to start editing.
Only the optional AI features need Node.js and the DeepSeek Harness CLI.

QUICK START
-----------

  Windows        double-click  install.cmd
                 or run        powershell -ExecutionPolicy Bypass -File install.ps1

  macOS / Linux  ./install.sh

The installer points this bundle at its own config (NVIM_APPNAME=dshstudio), so
your existing Neovim configuration is never read or modified.

The AI panel and project analysis also need:

  npm install -g @deepseek-ai/dsh      # DeepSeek Harness CLI (needs Node.js 18+)

Then open the editor and press:

  <leader>dd   open the DeepSeek panel        (Space is <leader>)
  <leader>dm   choose the model
  :DshAuth     set an API key for a provider
  <leader>dp   project analysis
  :DshHealth   show what was found / what is missing

WHAT IS IN THIS BUNDLE
----------------------

  nvim-deepseek-studio/   the configuration (Neovim loads this as the app config)
  nvim/                   the bundled Neovim runtime for this platform
  scripts/                install scripts (also usable standalone)
  docs/                   ACP protocol contract, install, troubleshooting, development
  install.sh/.ps1/.cmd    the entry points (handled by the launchers below)
  VERSION                 bundle version
  SHA256SUMS              checksums of the files in this bundle

REQUIREMENTS
------------

  Required   none beyond this bundle
  Optional   Node.js 18+ and @deepseek-ai/dsh   for the AI panel and analysis
  Optional   clangd / pyright / fortls          for full code intelligence
             (installable from inside the editor with :Mason)

Without a language server you still get tree-sitter highlighting and the offline
symbol outline, which needs no server at all.

LICENCES
--------

The configuration is MIT. The bundled Neovim is the official upstream build
under its own licence (Apache-2.0 with the Vim licence for inherited parts) and
is redistributed unmodified. See docs/../CREDITS.md for the full inventory.

This is an independent project, not affiliated with or endorsed by the Neovim,
Vim, Neovide or DeepSeek projects.
`;

async function buildBundle(platform, stageRoot) {
  const name = `VimForge-${VERSION}-${platform.id}`;
  const dir = path.join(stageRoot, name);
  console.log(`  assembling ${name}`);
  await mkdir(dir, { recursive: true });

  // 1. The configuration itself.
  await copyTree(CONFIG_DIR, path.join(dir, 'nvim-deepseek-studio'), new Set(['.git', 'dist']));

  // 2. Docs and scripts alongside, so they are readable without digging in.
  await copyTree(path.join(CONFIG_DIR, 'docs'), path.join(dir, 'docs'));
  await copyTree(path.join(CONFIG_DIR, 'scripts'), path.join(dir, 'scripts'));
  await cp(path.join(CONFIG_DIR, 'CREDITS.md'), path.join(dir, 'CREDITS.md'));
  await cp(path.join(CONFIG_DIR, 'LICENSE'), path.join(dir, 'LICENSE'));
  await writeFile(path.join(dir, 'VERSION'), `${VERSION}\n`);

  // 3. The platform's official Neovim.
  const assets = Array.isArray(platform.neovim) ? platform.neovim : [platform.neovim];
  const tmp = path.join(stageRoot, `.tmp-${platform.id}`);
  await mkdir(tmp, { recursive: true });

  for (const asset of assets) {
    const label = asset.name || platform.id;
    const file = path.join(tmp, path.basename(new URL(asset.url).pathname));
    console.log(`    fetching Neovim (${label})`);
    const okDownload = await download(asset.url, file, asset.fallback);
    if (!okDownload) {
      console.log(`    !! could not download Neovim for ${asset.url} - bundle will install it at first run`);
      continue;
    }
    const dest = asset.name ? path.join(dir, 'nvim', asset.name) : path.join(dir, 'nvim');
    await mkdir(dest, { recursive: true });
    if (asset.format === 'zip') {
      // Unzip via PowerShell's Expand-Archive equivalent is unavailable in this
      // sandbox, so use a pure-JS inflate over the zip's stored members.
      const { inflateRawSync } = await import('node:zlib');
      const buf = await readFile(file);
      // Walk the central directory to find file entries.
      let eocd = buf.length - 22;
      while (eocd > 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
      const count = buf.readUInt16LE(eocd + 10);
      let cd = buf.readUInt32LE(eocd + 16);
      for (let i = 0; i < count; i++) {
        const method = buf.readUInt16LE(cd + 10);
        const compSize = buf.readUInt32LE(cd + 20);
        const nameLen = buf.readUInt16LE(cd + 28);
        const extraLen = buf.readUInt16LE(cd + 30);
        const commentLen = buf.readUInt16LE(cd + 32);
        const localOff = buf.readUInt32LE(cd + 42);
        const entryName = buf.subarray(cd + 46, cd + 46 + nameLen).toString('utf8');
        const localNameLen = buf.readUInt16LE(localOff + 26);
        const localExtraLen = buf.readUInt16LE(localOff + 28);
        const dataStart = localOff + 30 + localNameLen + localExtraLen;
        const compressed = buf.subarray(dataStart, dataStart + compSize);
        // The archive root is nvim-win64/; strip it.
        const rel = entryName.replace(/^nvim-win64\//, '');
        if (rel && !entryName.endsWith('/')) {
          const target = path.join(dest, rel);
          if (path.resolve(target).startsWith(path.resolve(dest))) {
            await mkdir(path.dirname(target), { recursive: true });
            if (method === 0) await writeFile(target, compressed);
            else await writeFile(target, inflateRawSync(compressed));
          }
        }
        cd += 46 + nameLen + extraLen + commentLen;
      }
    } else {
      await extractTarGz(await readFile(file), dest);
    }
    await rm(file, { force: true });
  }
  await rm(tmp, { recursive: true, force: true });

  // 4. Launchers that use the bundled Neovim.
  const shLauncher = `#!/usr/bin/env bash
# VimForge portable launcher. Uses the Neovim inside this bundle.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

# Pick the Neovim build for this machine.
NVIM_BIN=""
if [ -x "$HERE/nvim/bin/nvim" ]; then
  NVIM_BIN="$HERE/nvim/bin/nvim"
else
  for arch in "$(uname -m)" x86_64 arm64; do
    case "$arch" in
      aarch64|arm64) candidate="$HERE/nvim/arm64/bin/nvim" ;;
      *)             candidate="$HERE/nvim/x86_64/bin/nvim" ;;
    esac
    if [ -x "$candidate" ]; then NVIM_BIN="$candidate"; break; fi
  done
fi
if [ -z "$NVIM_BIN" ]; then
  if command -v nvim >/dev/null 2>&1; then
    NVIM_BIN="$(command -v nvim)"
  else
    echo "No Neovim found in this bundle and none on PATH." >&2
    echo "Re-download the bundle, or install Neovim 0.11+ and retry." >&2
    exit 1
  fi
fi

# Isolate from any existing Neovim configuration.
export NVIM_APPNAME=dshstudio
export DSHSTUDIO_ROOT="$HERE"
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$XDG_CONFIG_HOME/dshstudio"

# Point the app config at this bundle the first time it runs.
if [ ! -e "$XDG_CONFIG_HOME/dshstudio/init.lua" ]; then
  ln -sfn "$HERE/nvim-deepseek-studio" "$XDG_CONFIG_HOME/dshstudio-link" 2>/dev/null || true
  cp -R "$HERE/nvim-deepseek-studio/." "$XDG_CONFIG_HOME/dshstudio/" 2>/dev/null || true
fi

exec "$NVIM_BIN" "$@"
`;
  await writeFile(path.join(dir, 'vimforge'), shLauncher, { mode: 0o755 });

  const installSh = `#!/usr/bin/env bash
# VimForge ${VERSION} portable install (${platform.label}).
# Extracts nothing: the bundle is already complete. This wires up the launcher
# and, optionally, the plugin set.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
BIN="\${DSHSTUDIO_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"

ln -sf "$HERE/vimforge" "$BIN/vimforge"
echo "linked $BIN/vimforge"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: add $BIN to PATH:  export PATH=\\"$BIN:\\$PATH\\"" ;;
esac

# Optional: sync plugins now (needs network + git).
if [ "\${NO_PLUGINS:-0}" != "1" ] && command -v git >/dev/null 2>&1; then
  echo "syncing plugins (first run downloads them)…"
  "$HERE/vimforge" --headless "+Lazy! sync" +qa 2>/dev/null || \\
    echo "plugin sync reported errors; inside the editor run :Lazy sync"
fi

echo ""
echo "VimForge is ready.  Start it with:"
echo "  vimforge              terminal editor"
echo "  vimforge file.f90"
echo ""
echo "Optional AI features need the harness CLI:"
echo "  npm install -g @deepseek-ai/dsh"
`;
  await writeFile(path.join(dir, 'install.sh'), installSh, { mode: 0o755 });

  const ps1Launcher = `<#
VimForge portable launcher (Windows). Uses the Neovim inside this bundle.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$nvim = Join-Path $here 'nvim\\bin\\nvim.exe'
if (-not (Test-Path $nvim)) {
  $found = Get-ChildItem -Path (Join-Path $here 'nvim') -Recurse -Filter nvim.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($found) { $nvim = $found.FullName }
  elseif (Get-Command nvim -ErrorAction SilentlyContinue) { $nvim = (Get-Command nvim).Source }
  else {
    Write-Error 'No Neovim found in this bundle and none on PATH.'
    exit 1
  }
}

# Isolate from any existing Neovim configuration.
$env:NVIM_APPNAME = 'dshstudio'
$env:DSHSTUDIO_ROOT = $here
$cfgRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:LOCALAPPDATA 'dshstudio-config' }
$cfg = Join-Path $cfgRoot 'dshstudio'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
if (-not (Test-Path (Join-Path $cfg 'init.lua'))) {
  Copy-Item (Join-Path $here 'nvim-deepseek-studio\\*') $cfg -Recurse -Force
}

& $nvim @args
`;
  await writeFile(path.join(dir, 'vimforge.ps1'), ps1Launcher);

  await writeFile(path.join(dir, 'install.ps1'), `<#
VimForge ${VERSION} portable install (Windows x64).
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here 'vimforge.ps1') --headless "+Lazy! sync" +qa
Write-Host ''
Write-Host 'VimForge is ready. Start it with:'
Write-Host ('  powershell -File "' + (Join-Path $here 'vimforge.ps1') + '" yourfile.f90')
Write-Host ''
Write-Host 'Optional AI features need the harness CLI:'
Write-Host '  npm install -g @deepseek-ai/dsh'
`);

  await writeFile(path.join(dir, 'install.cmd'), `@echo off
rem VimForge ${VERSION} portable install (Windows x64).
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
`);

  await writeFile(path.join(dir, 'README.txt'), README(platform));

  // 5. Checksums for the bundle contents.
  const sums = [];
  async function hashTree(d, rel = '') {
    for (const entry of (await readdir(d, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(d, entry.name);
      const relPath = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await hashTree(full, relPath);
      } else if (entry.isFile()) {
        // Skip the bundled Neovim runtime: it is upstream's, already checksummed
        // by the Neovim project, and hashing it triples the file size.
        if (relPath.startsWith('nvim/')) continue;
        const h = createHash('sha256');
        h.update(await readFile(full));
        sums.push(`${h.digest('hex')}  ${relPath}`);
      }
    }
  }
  await hashTree(dir);
  await writeFile(path.join(dir, 'SHA256SUMS'), sums.join('\n') + '\n');

  return { name, dir };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });
const stage = path.join(OUT, '.stage');
await mkdir(stage, { recursive: true });

const built = [];
for (const platform of PLATFORMS) {
  console.log(`\n=== ${platform.label} ===`);
  const bundle = await buildBundle(platform, stage);
  built.push({ platform, bundle });
}

// Archive each staged directory.
const { gzipSync } = await import('node:zlib');
for (const { platform, bundle } of built) {
  // tar.gz needs a tar writer; use the system tar when present, else ship a
  // directory-only note.
  const tarPath = path.join(OUT, `${bundle.name}.tar.gz`);
  let archived = false;
  try {
    execFileSync('tar', ['-czf', tarPath, '-C', stage, bundle.name], { stdio: 'ignore' });
    archived = true;
  } catch {
    console.log(`  tar unavailable; leaving ${bundle.name}/ as a directory`);
  }
  if (archived) {
    const size = (await stat(tarPath)).size;
    execFileSync(process.execPath, ['-e', 'process.exit(0)']);
    console.log(`  ${path.basename(tarPath)}  ${(size / 1048576).toFixed(1)} MB`);
  }
}

// Checksums for the archives themselves.
const archiveSums = [];
for (const f of (await readdir(OUT)).sort()) {
  if (f.startsWith('.')) continue;
  const full = path.join(OUT, f);
  if (!(await stat(full)).isFile()) continue;
  const h = createHash('sha256');
  h.update(await readFile(full));
  archiveSums.push(`${h.digest('hex')}  ${f}`);
}
if (archiveSums.length) {
  await writeFile(path.join(OUT, 'SHA256SUMS.txt'), archiveSums.join('\n') + '\n');
  console.log(`\nSHA256SUMS.txt written for ${archiveSums.length} archive(s)`);
}

console.log(`\nstaged bundles in ${stage}`);
for (const { bundle } of built) {
  const files = [];
  async function count(d) {
    for (const e of await readdir(d, { withFileTypes: true })) {
      if (e.isDirectory()) await count(path.join(d, e.name));
      else files.push(e.name);
    }
  }
  await count(bundle.dir);
  console.log(`  ${bundle.name}: ${files.length} files`);
}
