#!/usr/bin/env bash
# Install DSH Studio on Linux (x86_64) and macOS (Intel or Apple Silicon).
#
# Installs Neovim and (unless --no-gui) the Neovide GUI front-end into a
# self-contained prefix, then syncs plugins. The distribution uses its own
# NVIM_APPNAME (`dshstudio`), so any existing Neovim configuration is untouched.
#
# Usage:
#   ./scripts/install-unix.sh [--no-gui] [--no-plugins] [--prefix DIR] [--appimage]
#
#   --appimage  On Linux, also build a single-file AppImage launcher (requires
#               a working Neovide AppImage download; optional).

set -euo pipefail

NO_GUI=0
NO_PLUGINS=0
MAKE_APPIMAGE=0
PREFIX="${DSHSTUDIO_PREFIX:-$HOME/.local/share/dshstudio}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-gui) NO_GUI=1 ;;
    --no-plugins) NO_PLUGINS=1 ;;
    --appimage) MAKE_APPIMAGE=1 ;;
    --prefix) shift; PREFIX="$1" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/nvim-deepseek-studio"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/data"

say()  { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) echo "unsupported OS: $OS (this script covers Linux and macOS)" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_TAG=x86_64 ;;
  arm64|aarch64) ARCH_TAG=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

if [ "$PLATFORM" = linux ] && [ "$ARCH_TAG" != x86_64 ]; then
  warn "Prebuilt Linux binaries are published for x86_64; on $ARCH use your package manager for Neovim/Neovide."
fi

say "DSH Studio installer ($PLATFORM/$ARCH_TAG)"
mkdir -p "$BIN_DIR" "$DATA_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

download() {
  local url="$1" out="$2"
  if have curl; then
    curl -fL --retry 3 --connect-timeout 20 -o "$out" "$url"
  elif have wget; then
    wget -q -O "$out" "$url"
  else
    echo "need curl or wget to download $url" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Neovim
# ---------------------------------------------------------------------------
if [ -x "$BIN_DIR/nvim" ]; then
  say "Neovim already present — skipping download"
elif have nvim && [ "${DSHSTUDIO_USE_SYSTEM_NVIM:-0}" = "1" ]; then
  say "Using the system Neovim at $(command -v nvim)"
  ln -sf "$(command -v nvim)" "$BIN_DIR/nvim"
else
  say "Downloading Neovim (stable)"
  TMP="$(mktemp -d)"
  if [ "$PLATFORM" = linux ]; then
    URL="https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz"
    if ! download "$URL" "$TMP/nvim.tar.gz"; then
      warn "download failed; trying the legacy asset name"
      URL="https://github.com/neovim/neovim/releases/download/stable/nvim-linux64.tar.gz"
      download "$URL" "$TMP/nvim.tar.gz"
    fi
    tar -xzf "$TMP/nvim.tar.gz" -C "$TMP"
    SRC="$(find "$TMP" -maxdepth 2 -type d -name 'nvim-*' | head -n1)"
    cp -R "$SRC"/* "$PREFIX/"
  else
    if [ "$ARCH_TAG" = arm64 ]; then
      ASSET="nvim-macos-arm64.tar.gz"
    else
      ASSET="nvim-macos-x86_64.tar.gz"
    fi
    download "https://github.com/neovim/neovim/releases/download/stable/$ASSET" "$TMP/nvim.tar.gz"
    tar -xzf "$TMP/nvim.tar.gz" -C "$TMP"
    SRC="$(find "$TMP" -maxdepth 2 -type d -name 'nvim-*' | head -n1)"
    cp -R "$SRC"/* "$PREFIX/"
  fi
  rm -rf "$TMP"
  # Older Linux archives lack a top-level bin/ layout; normalise it.
  if [ ! -x "$BIN_DIR/nvim" ] && [ -x "$PREFIX/nvim" ]; then
    mkdir -p "$BIN_DIR"
    mv "$PREFIX/nvim" "$BIN_DIR/nvim"
  fi
  [ -x "$BIN_DIR/nvim" ] || { echo "Neovim was not installed correctly" >&2; exit 1; }
  ok "Neovim installed to $BIN_DIR"
fi

# ---------------------------------------------------------------------------
# Neovide (GUI)
# ---------------------------------------------------------------------------
if [ "$NO_GUI" -eq 0 ]; then
  if [ -x "$BIN_DIR/neovide" ]; then
    say "Neovide already present — skipping download"
  else
    say "Downloading Neovide (latest release)"
    TMP="$(mktemp -d)"
    API="https://api.github.com/repos/neovide/neovide/releases/latest"
    JSON="$TMP/release.json"
    if download "$API" "$JSON"; then
      if [ "$PLATFORM" = macos ]; then
        PATTERN='neovide.*\.dmg\|neovide.*macos.*\.zip'
      else
        PATTERN='neovide.*\.AppImage\|neovide.*linux.*x86_64.*\.tar\.gz'
      fi
      URL="$(grep -o '"browser_download_url": *"[^"]*"' "$JSON" \
              | sed 's/.*"\(https[^"]*\)"/\1/' \
              | grep -i "$PATTERN" | head -n1 || true)"
      if [ -n "$URL" ]; then
        FILE="$TMP/$(basename "$URL")"
        if download "$URL" "$FILE"; then
          case "$FILE" in
            *.AppImage) cp "$FILE" "$BIN_DIR/neovide"; chmod +x "$BIN_DIR/neovide" ;;
            *.tar.gz)   tar -xzf "$FILE" -C "$TMP"
                        EXE="$(find "$TMP" -type f -name 'neovide' | head -n1)"
                        [ -n "$EXE" ] && cp "$EXE" "$BIN_DIR/neovide" && chmod +x "$BIN_DIR/neovide" ;;
            *.dmg)      warn "A .dmg was downloaded to $FILE — open it and drag Neovide to Applications,"
                        warn "then re-run this installer so it can pick up the binary." ;;
          esac
          [ -x "$BIN_DIR/neovide" ] && ok "Neovide installed to $BIN_DIR/neovide"
        fi
      else
        warn "no suitable Neovide asset found for $PLATFORM/$ARCH_TAG"
      fi
    fi
    rm -rf "$TMP"
  fi
fi

# ---------------------------------------------------------------------------
# Launchers
# ---------------------------------------------------------------------------
say "Installing launchers"
cat > "$BIN_DIR/dshstudio" <<EOF
#!/usr/bin/env bash
# Generated by the DSH Studio installer.
set -euo pipefail
export DSHSTUDIO_ROOT="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="\$(dirname "\${BASH_SOURCE[0]}"):\$PATH"
export NVIM_APPNAME=dshstudio
exec "\$(dirname "\${BASH_SOURCE[0]}")/nvim" "\$@"
EOF
chmod +x "$BIN_DIR/dshstudio"

cat > "$BIN_DIR/dshstudio-gui" <<EOF
#!/usr/bin/env bash
# Generated by the DSH Studio installer.
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export DSHSTUDIO_ROOT="\$(cd "\$DIR/.." && pwd)"
export PATH="\$DIR:\$PATH"
export NVIM_APPNAME=dshstudio
if [ -x "\$DIR/neovide" ]; then
  exec "\$DIR/neovide" "\$@"
elif [ -d "/Applications/Neovide.app" ]; then
  exec /Applications/Neovide.app/Contents/MacOS/neovide "\$@"
else
  echo "Neovide is not installed; falling back to the terminal editor." >&2
  exec "\$DIR/nvim" "\$@"
fi
EOF
chmod +x "$BIN_DIR/dshstudio-gui"
ok "dshstudio and dshstudio-gui written to $BIN_DIR"

# macOS .app bundle so the GUI behaves like a normal application.
if [ "$PLATFORM" = macos ]; then
  APP="$HOME/Applications/DSH Studio.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DSH Studio</string>
  <key>CFBundleDisplayName</key><string>DSH Studio</string>
  <key>CFBundleIdentifier</key><string>dev.dshstudio.editor</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>dshstudio-launch</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Source file</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.c-source</string>
        <string>public.c-plus-plus-source</string>
        <string>public.python-script</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF
  cat > "$APP/Contents/MacOS/dshstudio-launch" <<EOF
#!/usr/bin/env bash
exec "$BIN_DIR/dshstudio-gui" "\$@"
EOF
  chmod +x "$APP/Contents/MacOS/dshstudio-launch"
  ok "Created $APP"
fi

# Linux desktop entry.
if [ "$PLATFORM" = linux ]; then
  DESKTOP_DIR="$HOME/.local/share/applications"
  mkdir -p "$DESKTOP_DIR"
  cat > "$DESKTOP_DIR/dshstudio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DSH Studio
Comment=DeepSeek Harness code editor (Fortran, C, C++, Python)
Exec=$BIN_DIR/dshstudio-gui %F
Terminal=false
Categories=Development;IDE;TextEditor;
MimeType=text/x-fortran;text/x-csrc;text/x-c++src;text/x-python;text/plain;
Icon=utilities-terminal
StartupWMClass=neovide
EOF
  ok "Desktop entry installed ($DESKTOP_DIR/dshstudio.desktop)"
fi

# ---------------------------------------------------------------------------
# Optional AppImage
# ---------------------------------------------------------------------------
if [ "$MAKE_APPIMAGE" -eq 1 ] && [ "$PLATFORM" = linux ]; then
  say "Building a self-contained AppImage launcher"
  APPDIR="$(mktemp -d)/DSHStudio.AppDir"
  mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications"
  cp -R "$PREFIX"/* "$APPDIR/usr/"
  [ -f "$CONFIG_DIR/../README.md" ] && cp "$CONFIG_DIR/../README.md" "$APPDIR/" || true
  cp "$DESKTOP_DIR/dshstudio.desktop" "$APPDIR/" 2>/dev/null || true
  cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export NVIM_APPNAME=dshstudio
export DSHSTUDIO_ROOT="$HERE/usr"
exec "$HERE/usr/bin/dshstudio-gui" "$@"
EOF
  chmod +x "$APPDIR/AppRun"
  if have appimagetool; then
    OUT="$REPO_ROOT/DSH-Studio-x86_64.AppImage"
    appimagetool "$APPDIR" "$OUT" && ok "AppImage written to $OUT"
  else
    warn "appimagetool not found — the AppDir is at $APPDIR"
    warn "Install appimagetool (https://github.com/AppImage/appimagetool) and run it on that directory."
  fi
fi

# ---------------------------------------------------------------------------
# Plugin sync
# ---------------------------------------------------------------------------
if [ "$NO_PLUGINS" -eq 0 ]; then
  say "Syncing plugins (headless Neovim — first run downloads everything)"
  export NVIM_APPNAME=dshstudio
  export DSHSTUDIO_ROOT="$PREFIX"
  if "$BIN_DIR/nvim" --headless -c "lua require('lazy').sync({ wait = true, show = false })" -c 'qa!' 2>&1 | tail -n 5; then
    ok "Plugins synced"
  else
    warn "plugin sync reported errors; run 'dshstudio' and then :Lazy sync inside the editor"
  fi

  say "Verifying the configuration loads"
  TEST_OUT="$("$BIN_DIR/nvim" --headless \
    -c "lua local ok = require('dshstudio.tests.probe').run_all({quiet=true}); print(ok and 'SELFTEST_OK' or 'SELFTEST_FAIL')" \
    -c 'qa!' 2>&1 || true)"
  case "$TEST_OUT" in
    *SELFTEST_OK*) ok "Self-test passed" ;;
    *) warn "self-test did not pass — run ':DshSelfTest' inside the editor" ;;
  esac
fi

# ---------------------------------------------------------------------------
cat <<EOF

DSH Studio is installed.

  Terminal editor : $BIN_DIR/dshstudio <file>
  Desktop window  : $BIN_DIR/dshstudio-gui <file>
  Config          : $CONFIG_DIR
  Data / plugins  : $DATA_DIR

Next steps:
  1. Add the bin directory to PATH if it is not already:
       echo 'export PATH="$BIN_DIR:\$PATH"' >> ~/.profile   # or ~/.zshrc
  2. Make sure the DeepSeek Harness CLI is available:  npm i -g @deepseek-ai/dsh
  3. In the editor: <leader>dd opens the DeepSeek panel, <leader>dp runs project analysis.
  4. Run :DshHealth for language-server status and :DshSelfTest for protocol tests.

Uninstall: delete $PREFIX and the launcher you added to PATH.
EOF
