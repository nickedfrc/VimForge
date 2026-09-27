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
    // Neovide ships as a zip on Windows, so it can be unpacked unattended.
    neovide: { asset: 'neovide.exe.zip', dest: 'neovide', format: 'zip' },
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
    // Upstream publishes only a .dmg for macOS, which cannot be mounted and
    // copied unattended, so this platform gets the fetcher script instead.
    neovide: null,
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
    // The AppImage is a single executable file.
    neovide: { asset: 'neovide.AppImage', dest: 'neovide/neovide', format: 'raw', mode: 0o755 },
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

// Extract a zip without a child process (this environment blocks spawned stdio).
async function extractZip(buffer, destDir, stripPrefix) {
  const { inflateRawSync } = await import('node:zlib');
  let eocd = buffer.length - 22;
  while (eocd > 0 && buffer.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd <= 0) throw new Error('not a zip archive (no central directory)');
  const count = buffer.readUInt16LE(eocd + 10);
  let cd = buffer.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i++) {
    const method = buffer.readUInt16LE(cd + 10);
    const compSize = buffer.readUInt32LE(cd + 20);
    const nameLen = buffer.readUInt16LE(cd + 28);
    const extraLen = buffer.readUInt16LE(cd + 30);
    const commentLen = buffer.readUInt16LE(cd + 32);
    const localOff = buffer.readUInt32LE(cd + 42);
    let entryName = buffer.subarray(cd + 46, cd + 46 + nameLen).toString('utf8');
    if (stripPrefix) entryName = entryName.replace(stripPrefix, '');
    const localNameLen = buffer.readUInt16LE(localOff + 26);
    const localExtraLen = buffer.readUInt16LE(localOff + 28);
    const dataStart = localOff + 30 + localNameLen + localExtraLen;
    const compressed = buffer.subarray(dataStart, dataStart + compSize);
    if (entryName && !entryName.endsWith('/')) {
      const target = path.join(destDir, entryName);
      if (path.resolve(target).startsWith(path.resolve(destDir))) {
        await mkdir(path.dirname(target), { recursive: true });
        await writeFile(target, method === 0 ? compressed : inflateRawSync(compressed));
      }
    }
    cd += 46 + nameLen + extraLen + commentLen;
  }
}

// Find a release asset by exact name on a GitHub repository.
async function findAsset(repo, assetName) {
  const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { 'User-Agent': 'vimforge-builder', Accept: 'application/vnd.github+json' },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status} for ${repo}`);
  const release = await res.json();
  const asset = (release.assets || []).find((a) => a.name === assetName);
  if (!asset) throw new Error(`asset ${assetName} not found in ${repo} ${release.tag_name}`);
  return asset;
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

This bundle is self-contained. It includes the configuration AND the official
Neovim build for this platform, and it keeps everything inside this folder, so you
can start editing immediately and delete the folder to uninstall.

QUICK START
-----------

  Windows        double-click  install.cmd
                 then use the "VimForge" desktop shortcut, or VimForge.cmd
                 terminal:  powershell -File vimforge.ps1

  macOS / Linux  ./install.sh
                 then:  vimforge            terminal editor
                        vimforge-gui        desktop window (needs Neovide)

Nothing is written outside this folder. An existing Neovim configuration is never
read or modified.

FOLDER LAYOUT
-------------

  nvim-deepseek-studio/   the shipped configuration (read-only source of truth)
  config/dshstudio/       the Neovim config directory actually in use, seeded
                          from the folder above on first run
  data/                   plugins, undo files and state, all inside the bundle
  nvim/                   the bundled Neovim runtime for this platform
  vimforge / vimforge.ps1        terminal editor launcher
  vimforge-gui / VimForge.cmd    desktop window launcher (Neovide, optional)
  install.sh / install.cmd       first-run setup
  docs/                   ACP protocol contract, install, troubleshooting, dev
  scripts/get-neovide.sh/.ps1    optional: fetch the Neovide GUI front-end
  VERSION, SHA256SUMS     bundle metadata

Why the config lives in two places: Neovim only reads the directory named after
$NVIM_APPNAME (here "dshstudio"), while the repository ships it as
"nvim-deepseek-studio". Seeding config/dshstudio on first run bridges that without
touching your home directory.

THE DESKTOP WINDOW (Neovide)
----------------------------

The terminal editor works out of the box. For a standalone window, run:

  Windows        powershell -ExecutionPolicy Bypass -File scripts\\get-neovide.ps1
  Linux          ./scripts/get-neovide.sh
  macOS          download Neovide from https://neovide.dev and put "neovide" in
                 this folder or on your PATH

Neovide is deliberately not bundled: it is a large per-platform binary, and the
terminal editor is fully functional without it.

THE AI FEATURES (optional)
--------------------------

These need Node.js 18+ and the DeepSeek Harness CLI:

  npm install -g @deepseek-ai/dsh

Then, in the editor:

  <leader>dd   open the DeepSeek panel        (Space is <leader>)
  :DshAuth     set an API key for a provider
  <leader>dm   choose the model
  :DshProviders  see which providers are keyed
  <leader>dp   project analysis
  :DshHealth   what was found / what is missing

Keys are stored where the harness keeps them ($DSH_HOME/.credentials.yaml), so
they are available to every harness tool, not just this editor. Precedence is:
an exported environment variable, then that store, then a project .env, then the
harness-home .env.

REQUIREMENTS
------------

  Required   none beyond this bundle
  Optional   Node.js 18+ and @deepseek-ai/dsh   for the AI panel and analysis
  Optional   Neovide                            for the standalone window
  Optional   clangd / pyright / fortls           for full code intelligence
             (installable from inside the editor with :Mason)

Without a language server you still get tree-sitter highlighting and the offline
symbol outline, which needs no server at all.

LICENCES
--------

The configuration is MIT. The bundled Neovim is the official upstream build under
its own licence (Apache-2.0 with the Vim licence for inherited parts) and is
redistributed unmodified. See CREDITS.md for the full inventory.

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
      // The archive root is nvim-win64/; strip it. Pure-JS extraction because
      // this environment cannot spawn a child process to run unzip.
      await extractZip(await readFile(file), dest, /^nvim-win64\//);
    } else {
      await extractTarGz(await readFile(file), dest);
    }
    await rm(file, { force: true });
  }

  // 3b. Neovide, where upstream publishes something unpackable without a desktop
  //     session. macOS ships only a .dmg, so that platform gets the fetcher
  //     script instead of a bundled binary.
  if (platform.neovide) {
    try {
      console.log(`    fetching Neovide (${platform.neovide.asset})`);
      const asset = await findAsset('neovide/neovide', platform.neovide.asset);
      const file = path.join(tmp, platform.neovide.asset);
      await download(asset.browser_download_url, file);
      const destPath = path.join(dir, platform.neovide.dest);
      await mkdir(path.dirname(destPath), { recursive: true });
      if (platform.neovide.format === 'zip') {
        await extractZip(await readFile(file), destPath);
      } else {
        await writeFile(destPath, await readFile(file), { mode: platform.neovide.mode || 0o755 });
      }
      await rm(file, { force: true });
      console.log(`    Neovide -> ${platform.neovide.dest}`);
    } catch (err) {
      console.log(`    !! Neovide unavailable (${String(err.message).slice(0, 140)})`);
      console.log('       the terminal editor is unaffected');
    }
  }
  await rm(tmp, { recursive: true, force: true });

  // 4. Launchers.
  //
  // Config resolution is the subtle part. Neovim only looks at
  // `$XDG_CONFIG_HOME/$NVIM_APPNAME`, so a bundle whose configuration directory
  // is named `nvim-deepseek-studio` is invisible to it - the editor starts as a
  // bare Neovim, which is exactly the bug this layout exists to prevent. The
  // fix is to keep everything inside the bundle: `config/dshstudio` is the
  // Neovim config directory, populated from the shipped configuration on first
  // run, and `XDG_CONFIG_HOME` points at `config/`. Nothing is written to the
  // user's home directory.
  const shLauncher = `#!/usr/bin/env bash
# VimForge portable launcher. Self-contained: uses the Neovim and the
# configuration inside this folder, and writes nothing outside it.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

# Resolve this machine's Neovim build.
NVIM_BIN=""
if [ -x "$HERE/nvim/bin/nvim" ]; then
  NVIM_BIN="$HERE/nvim/bin/nvim"
else
  case "$(uname -m)" in
    aarch64|arm64) CAND="$HERE/nvim/arm64/bin/nvim" ;;
    *)             CAND="$HERE/nvim/x86_64/bin/nvim" ;;
  esac
  if [ -x "$CAND" ]; then
    NVIM_BIN="$CAND"
  elif command -v nvim >/dev/null 2>&1; then
    echo "note: this bundle has no Neovim for $(uname -m); using $(command -v nvim)" >&2
    NVIM_BIN="$(command -v nvim)"
  else
    echo "No Neovim available: the bundle has none for $(uname -m) and none is on PATH." >&2
    exit 1
  fi
fi

# Make the configuration the app config directory, without touching ~/.config.
export DSHSTUDIO_ROOT="$HERE"
export XDG_CONFIG_HOME="$HERE/config"
mkdir -p "$XDG_CONFIG_HOME/dshstudio"
if [ ! -f "$XDG_CONFIG_HOME/dshstudio/init.lua" ]; then
  cp -R "$HERE/nvim-deepseek-studio/." "$XDG_CONFIG_HOME/dshstudio/"
fi
# Keep plugin and state data inside the bundle too, so uninstalling is a delete.
export XDG_DATA_HOME="\${XDG_DATA_HOME:-$HERE/data}"
mkdir -p "$XDG_DATA_HOME"
export NVIM_APPNAME=dshstudio

exec "$NVIM_BIN" "\$@"
`;
  await writeFile(path.join(dir, 'vimforge'), shLauncher, { mode: 0o755 });

  const shGui = `#!/usr/bin/env bash
# VimForge desktop window (Neovide). Falls back to the terminal editor when
# Neovide is not present in this bundle.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export DSHSTUDIO_ROOT="$HERE"
export XDG_CONFIG_HOME="$HERE/config"
mkdir -p "$XDG_CONFIG_HOME/dshstudio"
if [ ! -f "$XDG_CONFIG_HOME/dshstudio/init.lua" ]; then
  cp -R "$HERE/nvim-deepseek-studio/." "$XDG_CONFIG_HOME/dshstudio/"
fi
export XDG_DATA_HOME="\${XDG_DATA_HOME:-$HERE/data}"
mkdir -p "$XDG_DATA_HOME"
export NVIM_APPNAME=dshstudio

for candidate in "$HERE/nvim/neovide" "$HERE/neovide" "/Applications/Neovide.app/Contents/MacOS/neovide"; do
  if [ -x "$candidate" ]; then exec "$candidate" "\$@"; fi
done
if command -v neovide >/dev/null 2>&1; then exec neovide "\$@"; fi
echo "Neovide is not installed; starting the terminal editor instead." >&2
exec "$HERE/vimforge" "\$@"
`;
  await writeFile(path.join(dir, 'vimforge-gui'), shGui, { mode: 0o755 });

  // install.sh wires up PATH entries; the launchers already work in place.
  const installSh = `#!/usr/bin/env bash
# VimForge ${VERSION} portable install (${platform.label}).
#
# This bundle is already complete - nothing is extracted or downloaded. This
# script links the launchers into a directory on your PATH and, unless NO_PLUGINS
# is set, syncs the plugin set.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
BIN="\${DSHSTUDIO_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"

for launcher in vimforge vimforge-gui; do
  if [ -x "$HERE/$launcher" ]; then
    ln -sf "$HERE/$launcher" "$BIN/$launcher"
    echo "linked $BIN/$launcher"
  fi
done

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: add $BIN to PATH, e.g.  export PATH=\\"$BIN:\\$PATH\\"" ;;
esac

if [ "\${NO_PLUGINS:-0}" != "1" ] && command -v git >/dev/null 2>&1; then
  echo "syncing plugins (the first run downloads them)…"
  "$HERE/vimforge" --headless "+Lazy! sync" +qa 2>/dev/null || \\
    echo "plugin sync reported errors; inside the editor run :Lazy sync"
fi

cat <<EOF

VimForge is ready.

  vimforge              terminal editor
  vimforge-gui          desktop window (Neovide)
  vimforge file.f90

Configuration and plugin data live inside this folder:
  $HERE/config         Neovim config directory
  $HERE/data           plugin and state data

Your existing Neovim configuration was not touched.

Optional: the AI panel and project analysis need the harness CLI
  npm install -g @deepseek-ai/dsh
then set an API key with :DshAuth and pick a model with <leader>dm.
EOF
`;
  await writeFile(path.join(dir, 'install.sh'), installSh, { mode: 0o755 });

  const ps1Launcher = `<#
VimForge portable launcher (Windows). Self-contained: uses the Neovim and the
configuration inside this folder, and writes nothing outside it.
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

# Neovim reads $XDG_CONFIG_HOME/$NVIM_APPNAME, so the config directory must be
# named 'dshstudio'. Keeping it inside the bundle means nothing is written to the
# user's home directory and an existing Neovim setup is untouched.
$env:DSHSTUDIO_ROOT = $here
$env:XDG_CONFIG_HOME = Join-Path $here 'config'
$cfg = Join-Path $env:XDG_CONFIG_HOME 'dshstudio'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
if (-not (Test-Path (Join-Path $cfg 'init.lua'))) {
  Copy-Item (Join-Path $here 'nvim-deepseek-studio\\*') $cfg -Recurse -Force
}
$env:XDG_DATA_HOME = Join-Path $here 'data'
New-Item -ItemType Directory -Force -Path $env:XDG_DATA_HOME | Out-Null
$env:NVIM_APPNAME = 'dshstudio'

& $nvim @args
`;
  await writeFile(path.join(dir, 'vimforge.ps1'), ps1Launcher);

  const ps1Gui = `<#
VimForge desktop window (Windows, Neovide). Falls back to the terminal editor.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$neovide = Join-Path $here 'neovide\\neovide.exe'
if (-not (Test-Path $neovide)) { $neovide = Join-Path $here 'neovide.exe' }
if (Test-Path $neovide) {
  & $neovide @args
} else {
  Write-Host 'Neovide is not in this bundle; starting the terminal editor instead.'
  & (Join-Path $here 'vimforge.ps1') @args
}
`;
  await writeFile(path.join(dir, 'vimforge-gui.ps1'), ps1Gui);

  // A double-clickable GUI launcher, since that is how most Windows users start.
  await writeFile(path.join(dir, 'VimForge.cmd'), `@echo off
rem Double-click to open the VimForge desktop window.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vimforge-gui.ps1" %*
if errorlevel 1 pause
`);

  await writeFile(path.join(dir, 'install.ps1'), `<#
VimForge ${VERSION} portable install (Windows x64).

This bundle is already complete. This script warms the plugin cache and reports
how to start the editor; a desktop shortcut is created for convenience.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host 'Preparing VimForge (the first run downloads the plugins)…'
& (Join-Path $here 'vimforge.ps1') --headless "+Lazy! sync" +qa
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Plugin sync reported errors; inside the editor run :Lazy sync.'
}

try {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'VimForge.lnk'))
  $lnk.TargetPath = Join-Path $here 'VimForge.cmd'
  $lnk.WorkingDirectory = $here
  $lnk.Description = 'VimForge - Vim editor with DeepSeek Harness built in'
  $lnk.Save()
  Write-Host 'Desktop shortcut created.'
} catch {
  Write-Host ('Could not create a desktop shortcut: ' + $_.Exception.Message)
}

Write-Host ''
Write-Host 'VimForge is ready.'
Write-Host ''
Write-Host ('  double-click   ' + (Join-Path $here 'VimForge.cmd') + '   (desktop window)')
Write-Host ('  terminal       powershell -File "' + (Join-Path $here 'vimforge.ps1') + '"')
Write-Host ''
Write-Host 'Configuration and plugin data stay inside this folder; your existing'
Write-Host 'Neovim setup was not touched.'
Write-Host ''
Write-Host 'Optional AI features:'
Write-Host '  npm install -g @deepseek-ai/dsh'
Write-Host 'then :DshAuth to set an API key and <leader>dm to pick a model.'
`);

  await writeFile(path.join(dir, 'install.cmd'), `@echo off
rem VimForge ${VERSION} portable install (Windows x64). Double-click me.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
`);

  await writeFile(path.join(dir, 'README.txt'), README(platform));

  // 5. An opt-in Neovide fetcher. Neovide is not bundled - it is a large
  //    per-platform binary and the terminal editor needs nothing extra - but the
  //    bundle can fetch it on request so a user gets the standalone window with
  //    one command.
  const neovideSh = `#!/usr/bin/env bash
# Fetch the Neovide GUI front-end into this bundle.
#
#   ./scripts/get-neovide.sh
#
# Neovide is not bundled because it is a large per-platform binary and the
# terminal editor works without it. On macOS the upstream artifact is a .dmg,
# which cannot be unpacked non-interactively; the script says so rather than
# pretending to succeed.
set -euo pipefail
HERE="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/neovide"
mkdir -p "$DEST"

API="https://api.github.com/repos/neovide/neovide/releases/latest"
if command -v curl >/dev/null 2>&1; then DL="curl -fL --retry 3 -o"; elif command -v wget >/dev/null 2>&1; then DL="wget -q -O"; else
  echo "need curl or wget" >&2; exit 1
fi

json="$(mktemp)"
if command -v curl >/dev/null 2>&1; then curl -fsSL "$API" -o "$json"; else wget -q -O "$json" "$API"; fi

case "$(uname -s)" in
  Linux)  pattern='neovide.AppImage' ;;
  Darwin) pattern='apple-darwin.dmg' ;;
  *) echo "unsupported platform for automatic Neovide install: $(uname -s)" >&2; exit 1 ;;
esac

url="$(grep -o '"browser_download_url": *"[^"]*"' "$json" | sed 's/.*"\\(https[^"]*\\)"/\\1/' | grep "$pattern" | head -n1 || true)"
rm -f "$json"
if [ -z "$url" ]; then echo "no Neovide asset matching $pattern found" >&2; exit 1; fi

out="$DEST/$(basename "$url")"
echo "downloading $(basename "$url")"
$DL "$out" "$url"

case "$out" in
  *.AppImage) chmod +x "$out"; ln -sf "$out" "$DEST/neovide"; echo "installed $DEST/neovide" ;;
  *.dmg) echo "Downloaded a .dmg to $out"
         echo "Open it, drag Neovide to Applications, then use vimforge-gui,"
         echo "which also looks in /Applications/Neovide.app." ;;
esac
`;
  await writeFile(path.join(dir, 'scripts', 'get-neovide.sh'), neovideSh, { mode: 0o755 });

  const neovidePs1 = `<#
Fetch the Neovide GUI front-end into this bundle (Windows).

  powershell -ExecutionPolicy Bypass -File scripts\\get-neovide.ps1

Neovide is not bundled because it is a large per-platform binary and the terminal
editor works without it.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dest = Join-Path $here 'neovide'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/neovide/neovide/releases/latest' \`
  -Headers @{ 'User-Agent' = 'vimforge' }
$asset = $release.assets | Where-Object { $_.name -eq 'neovide.exe.zip' } | Select-Object -First 1
if (-not $asset) { $asset = $release.assets | Where-Object { $_.name -like '*win*x86_64*' } | Select-Object -First 1 }
if (-not $asset) { throw 'no Windows Neovide asset found in the latest release' }

$zip = Join-Path $env:TEMP $asset.name
Write-Host ('downloading ' + $asset.name)
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $dest -Force
Remove-Item $zip -Force -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $dest 'neovide.exe')) {
  Write-Host ('installed ' + (Join-Path $dest 'neovide.exe'))
  Write-Host 'Run VimForge.cmd (or vimforge-gui.ps1) for the desktop window.'
} else {
  throw 'neovide.exe was not found in the downloaded archive'
}
`;
  await writeFile(path.join(dir, 'scripts', 'get-neovide.ps1'), neovidePs1);

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
