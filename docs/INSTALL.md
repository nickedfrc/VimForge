# Installation and platform notes

Windows x64, macOS (Intel and Apple Silicon) and Linux x86_64 are all supported.
This page covers what the installer does on each, how to install by hand, what
each platform needs for the language features, and how to verify the result.

If you only want the short version, it is one command per platform:

```powershell
# Windows x64 (PowerShell)
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

```bash
# macOS or Linux
./scripts/install-unix.sh
```

---

## 1. Platform support matrix

| | Windows 10/11 x64 | macOS 11+ | Linux x86_64 |
|---|---|---|---|
| Terminal editor | ✅ `dshstudio` | ✅ `dshstudio` | ✅ `dshstudio` |
| Desktop window | ✅ `dshstudio-gui` (Neovide) | ✅ `dshstudio-gui`, plus `DSH Studio.app` | ✅ `dshstudio-gui` (Neovide AppImage), optional AppImage |
| Neovim source | official `nvim-win64.zip` | official `nvim-macos-{x86_64,arm64}.tar.gz` | official `nvim-linux-x86_64.tar.gz` (falls back to the legacy `nvim-linux64` asset) |
| Config location | `%XDG_CONFIG_HOME%\dshstudio` (default `%LOCALAPPDATA%\dshstudio`) | `~/.config/dshstudio` | `~/.config/dshstudio` |
| Data / plugins | `%LOCALAPPDATA%\DSHStudio\data` | `~/.local/share/dshstudio/data` | `~/.local/share/dshstudio/data` |
| File association | "Open with DSH Studio" for source extensions | `DSH Studio.app` document types | `.desktop` entry with `MimeType=` |
| Desktop shortcut | ✅ created on the Desktop | app in `~/Applications` | desktop entry in `~/.local/share/applications` |
| Installer language | PowerShell 5.1+ (ships with Windows) | bash 3.2+ (ships with macOS) | bash 4+ |

**Windows ARM64** has no dedicated build. The x64 package runs under emulation.
The installer warns but continues.

**Linux on ARM (aarch64)** has no official prebuilt Neovim tarball from upstream.
Set `DSHSTUDIO_USE_SYSTEM_NVIM=1` and install Neovim through your distribution, or
install Neovim manually and symlink it into the install prefix.

**macOS on Apple Silicon** uses the `nvim-macos-arm64` asset; Intel uses
`nvim-macos-x86_64`. The installer picks by `uname -m`.

---

## 2. What the installers do

Both installers follow the same five steps.

1. **Download Neovim** (stable) into `<prefix>/bin` unless it is already there.
   On Linux the layout is normalised so `<prefix>/bin/nvim` always exists, because
   older archives unpack differently from current ones.
2. **Download Neovide** (latest release) unless `--no-gui`/`-NoGui` is passed.
   On macOS a `.dmg` cannot be unpacked non-interactively; the installer says so
   instead of pretending to succeed, and `dshstudio-gui` prefers
   `/Applications/Neovide.app` when it exists.
3. **Write launchers**: `dshstudio` (terminal) and `dshstudio-gui` (window). Both
   export `NVIM_APPNAME=dshstudio`, which is what keeps this distribution out of
   your normal Neovim configuration.
4. **Register desktop integration**: `PATH` entry, file associations, shortcut,
   `.desktop` entry or `.app` bundle.
5. **Sync plugins and self-test**: runs a headless `lazy.nvim` sync, then runs the
   offline self-test and reports whether the configuration loads.

### Why `NVIM_APPNAME` matters

Neovim derives its config and data directories from `NVIM_APPNAME`. Launching with
`NVIM_APPNAME=dshstudio` means:

- your `~/.config/nvim` (or `%LOCALAPPDATA%\nvim`) is never read or written
- plugins, shada, undo files and the LSP cache live under this distribution
- uninstalling is deleting one directory

This is also why the distribution can be installed next to an existing Neovim
setup without touching it — the concern that usually stops people from trying a
distribution.

### Options

`scripts/install-windows.ps1`

| Flag | Effect |
|---|---|
| `-NoGui` | Skip Neovide; terminal editor only |
| `-NoPlugins` | Skip the plugin sync (offline staging) |
| `-Prefix <dir>` | Install root, default `%LOCALAPPDATA%\DSHStudio` |
| `-NvimVersion <tag>` | Neovim release tag, default `stable` |

`scripts/install-unix.sh`

| Flag | Effect |
|---|---|
| `--no-gui` | Skip Neovide |
| `--no-plugins` | Skip the plugin sync |
| `--prefix DIR` | Install root, default `~/.local/share/dshstudio` |
| `--appimage` | Build a single-file AppImage launcher (needs `appimagetool`) |

---

## 3. Manual install (any platform)

If you already have Neovim 0.11+ and prefer to control everything:

```bash
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
```

**Give this config its own application name** so your existing setup is untouched:

```bash
# Linux / macOS
export NVIM_APPNAME=dshstudio
mkdir -p ~/.config/dshstudio
cp -R nvim-deepseek-studio/. ~/.config/dshstudio/
```

```powershell
# Windows
$env:NVIM_APPNAME = 'dshstudio'
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\dshstudio" | Out-Null
Copy-Item nvim-deepseek-studio\* "$env:LOCALAPPDATA\dshstudio" -Recurse -Force
```

Then sync plugins and check it loads:

```bash
nvim --headless "+Lazy! sync" +qa
nvim
```

Or use it in place without copying, by launching with an explicit config path:

```bash
nvim -u ./nvim-deepseek-studio/init.lua
```

`-u` does not set `NVIM_APPNAME`, so plugin data lands in your normal data
directory. Prefer the `NVIM_APPNAME` route if you care about isolation.

---

## 4. Dependencies per platform

### Required everywhere

| Dependency | Why | Install |
|---|---|---|
| Neovim 0.11+ | the editor | installer, or your package manager |
| Node.js 18+ | runs the DeepSeek Harness CLI | [nodejs.org](https://nodejs.org) |
| DeepSeek Harness | AI features | `npm i -g @deepseek-ai/dsh` |
| git | plugin downloads | installer/package manager |

### AI credentials

The harness needs an API key per model provider. The editor writes them into the
harness' own store, so there is nothing extra to configure:

```vim
:DshAuth          " choose a provider and paste its key
:DshProviders     " see which providers are keyed and which model each offers
:DshModel         " pick the model
```

Precedence, highest first: a variable exported in your shell, then the harness
store (`$DSH_HOME/.credentials.yaml`), then a project `.env`, then
`$DSH_HOME/.env`. So exporting a key in a CI job overrides whatever a developer
saved locally, and no key has to be stored on disk at all.

To add a provider beyond the shipped DeepSeek and Xiaomi routes, declare it in
`$DSH_HOME/settings.yaml` as a pi-ai route with an `apiKeyEnv` reference, then run
`:DshAuth` to fill that variable. See the README section "Models and API keys".

### Language servers

| Language | Windows | macOS | Linux |
|---|---|---|---|
| C / C++ | `winget install LLVM.LLVM`, or `:Mason` | `brew install llvm`, or `:Mason` | `apt install clangd` / `dnf install clang-tools-extra`, or `:Mason` |
| Python | `:Mason` or `npm i -g pyright` | same | same |
| Lua | `:Mason` | `:Mason` | `:Mason` |
| Fortran | `pip install fortran-language-server` | `brew install fortls` or pip | `pip install fortran-language-server` |

`:Mason` installs clangd, pyright and lua_ls automatically on first launch; fortls
has no recipe on every platform, which is why pip is the reliable route. Everything
degrades gracefully: with no server you still get highlighting and the offline
symbol outline.

### Compilers, if you build from the editor

| Language | Windows | macOS | Linux |
|---|---|---|---|
| Fortran | `gfortran` (MSYS2, or LLVM `flang`) | `brew install gcc` | `apt install gfortran` |
| C / C++ | MSVC via Build Tools, or MSYS2 `gcc` | Xcode command line tools | `apt install build-essential` |
| CMake | `winget install Kitware.CMake` | `brew install cmake` | `apt install cmake` |

### Terminal notes

- **Windows:** use Windows Terminal. The legacy console cannot draw the sidebar
  borders or the icon glyphs correctly.
- **macOS:** iTerm2 or the built-in Terminal both work; for the icon glyphs install
  a Nerd Font (`brew install --cask font-jetbrains-mono-nerd-font`).
- **Linux:** any modern terminal with true colour.

---

## 5. Verifying the installation

Inside the editor, in this order:

| Command | Checks |
|---|---|
| `:DshHealth` | CLI discovery, language-server availability, installed parsers |
| `:DshSelfTest` | 17 offline behavioural tests (protocol, transcript, extraction) |
| `:DshPing` | end-to-end: can the harness answer at all |
| `:checkhealth` | Neovim's own report (providers, LSP, treesitter) |

From a shell, without starting the UI:

```bash
# syntax + module checks (Node only, no Lua toolchain)
node tests/lua_syntax_check.js ./nvim-deepseek-studio
node tests/check_requires.js ./nvim-deepseek-studio

# the behavioural tests
nvim --headless --cmd "set rtp+=$PWD/nvim-deepseek-studio" \
     -c "lua require('dshstudio.tests.probe').main()"
```

The installers run the last of these automatically and print the result.

---

## 6. Uninstalling

The distribution never modifies anything outside its own prefix and its
`NVIM_APPNAME` directories.

**Windows**

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\DSHStudio"
# then remove that bin directory from your user PATH
```

Also delete the "DSH Studio" desktop shortcut if you want it gone. File
associations point at the launcher; Windows drops them once the target is gone.

**macOS / Linux**

```bash
rm -rf ~/.local/share/dshstudio          # program + plugins
rm -rf ~/.config/dshstudio               # config copy, if the installer made one
rm -f  ~/.local/share/applications/dshstudio.desktop   # Linux only
rm -rf "$HOME/Applications/DSH Studio.app"             # macOS only
```

Then remove the `export PATH=...` line the installer suggested.

Your own `~/.config/nvim` and `~/.vimrc` are never touched by any of this.

---

## 7. Platform-specific known issues

**Windows — `dsh` is not found although it is installed.** The CLI is a `.cmd`
shim; discovery prefers the real Node binary. If it still fails, set
`agent_command = { 'cmd', '/c', 'dsh' }` in your config.

**Windows — the commit/push of `.github/workflows` is refused.** A GitHub token
without the `workflow` scope cannot create workflow files. That is why the CI
workflow is not part of the initial commit; add it in the browser or push it with
a token that has `workflow` scope.

**Windows — a UTF-8 BOM in a source file.** Handled: the extractors strip a BOM
before parsing, because a leading BOM used to hide the first `module`/`program`
declaration from the symbol list. Windows editors write BOMs by default, so this
matters more here than elsewhere.

**macOS — language servers not found when launched from the Dock.** GUI apps do
not inherit your shell `PATH`. Start `dshstudio-gui` from a terminal, or add the
server paths to `vim.g.dshstudio` via `lsp.*` settings.

**macOS — the Neovide `.dmg`.** The installer cannot mount and copy a `.dmg`
non-interactively. Open it, drag Neovide to Applications, and re-run the installer
so it can find it.

**Linux — Neovide AppImage needs FUSE.** Without it, run with
`--appimage-extract-and-run`, or use a distribution package.

**Linux — ARM64.** No upstream Neovim tarball; use `DSHSTUDIO_USE_SYSTEM_NVIM=1`
with a distribution Neovim 0.11+.

**All platforms — fixed-form Fortran indentation.** Detected from the extension,
then from content for ambiguous `.f` files. Override with
`:let b:fortran_fixed_source = 1` or `b:fortran_free_source = 1`.
