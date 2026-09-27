<#
.SYNOPSIS
  Install DSH Studio on Windows (x64).

.DESCRIPTION
  Installs Neovim and (by default) the Neovide GUI front-end into a
  self-contained data directory, then syncs the plugin set.

  The distribution never touches an existing Neovim configuration: it runs with
  its own NVIM_APPNAME (`dshstudio`), so plugins, shada and undo files live in
  this folder and uninstalling is a directory delete.

.PARAMETER NoGui
  Install only Neovim (terminal use, no Neovide desktop window).

.PARAMETER NoPlugins
  Skip the headless plugin sync (useful for offline staging).

.PARAMETER Prefix
  Installation root. Defaults to %LOCALAPPDATA%\DSHStudio.

.EXAMPLE
  pwsh -File .\scripts\install-windows.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -NoGui
#>
[CmdletBinding()]
param(
  [switch]$NoGui,
  [switch]$NoPlugins,
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'DSHStudio'),
  [string]$NvimVersion = 'stable'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Get-Arch {
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -eq 'AMD64' -or $arch -eq 'ARM64') { return $arch }
  if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
  return 'AMD64'
}

function Test-Command($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
Write-Step "DSH Studio installer (Windows)"
$arch = Get-Arch
if ($arch -ne 'AMD64') {
  Write-Warn2 "Only 64-bit x64 builds are published for Windows; detected $arch."
  Write-Warn2 "The x64 build will still run under emulation on ARM64 Windows."
}

$binDir  = Join-Path $Prefix 'bin'
$dataDir = Join-Path $Prefix 'data'
$repoRoot = Split-Path -Parent $PSScriptRoot
$configDir = Join-Path $repoRoot 'nvim-deepseek-studio'

New-Item -ItemType Directory -Force -Path $binDir, $dataDir | Out-Null

# ---------------------------------------------------------------------------
# Neovim
# ---------------------------------------------------------------------------
$nvimExe = Join-Path $binDir 'nvim.exe'
if (Test-Path $nvimExe) {
  Write-Step "Neovim already present — skipping download"
} else {
  Write-Step "Downloading Neovim ($NvimVersion, win64)"
  $asset = "nvim-win64.zip"
  $url = "https://github.com/neovim/neovim/releases/download/$NvimVersion/$asset"
  $zip = Join-Path $env:TEMP $asset
  try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  } catch {
    throw "Could not download Neovim from $url. Check your network or install Neovim manually and re-run with -NoGui."
  }
  $tmp = Join-Path $env:TEMP ("dshstudio-nvim-" + [guid]::NewGuid().ToString('N'))
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  # The archive root may be nvim-win64/ or nvim-win64/bin depending on release.
  $candidate = Get-ChildItem -Path $tmp -Recurse -Filter 'nvim.exe' | Select-Object -First 1
  if (-not $candidate) { throw "nvim.exe not found inside $asset" }
  $root = Split-Path -Parent $candidate.FullName
  Copy-Item -Path (Join-Path $root '*') -Destination $binDir -Recurse -Force
  Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Ok "Neovim installed to $binDir"
}

# ---------------------------------------------------------------------------
# Neovide (GUI window)
# ---------------------------------------------------------------------------
if (-not $NoGui) {
  $neovideExe = Join-Path $binDir 'neovide.exe'
  if (Test-Path $neovideExe) {
    Write-Step "Neovide already present — skipping download"
  } else {
    Write-Step "Downloading Neovide (latest release)"
    try {
      $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/neovide/neovide/releases/latest' `
        -Headers @{ 'User-Agent' = 'dshstudio-installer' }
      $asset = $release.assets | Where-Object { $_.name -match '^neovide\.exe$' } | Select-Object -First 1
      if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match 'windows.*x86_64.*\.zip$|neovide.*win.*\.zip$' } | Select-Object -First 1
      }
      if (-not $asset) { throw 'no Windows asset found in the latest Neovide release' }
      $dl = Join-Path $env:TEMP $asset.name
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dl -UseBasicParsing
      if ($asset.name -like '*.zip') {
        $tmp = Join-Path $env:TEMP ("dshstudio-neovide-" + [guid]::NewGuid().ToString('N'))
        Expand-Archive -Path $dl -DestinationPath $tmp -Force
        $exe = Get-ChildItem -Path $tmp -Recurse -Filter 'neovide.exe' | Select-Object -First 1
        if (-not $exe) { throw 'neovide.exe not found in the downloaded archive' }
        Copy-Item $exe.FullName -Destination $neovideExe -Force
        Remove-Item $dl, $tmp -Recurse -Force -ErrorAction SilentlyContinue
      } else {
        Copy-Item $dl -Destination $neovideExe -Force
        Remove-Item $dl -Force -ErrorAction SilentlyContinue
      }
      Write-Ok "Neovide installed to $neovideExe"
    } catch {
      Write-Warn2 "Neovide install failed: $($_.Exception.Message)"
      Write-Warn2 "The editor still works in a terminal via the dshstudio launcher."
    }
  }
}

# ---------------------------------------------------------------------------
# Launcher on PATH (user scope, no admin needed)
# ---------------------------------------------------------------------------
Write-Step "Registering the launcher on the user PATH"
$launcher = Join-Path $binDir 'dshstudio.cmd'
$launcherPs1 = Join-Path $binDir 'dshstudio.ps1'
$cmdContent = @"
@echo off
rem Generated by the DSH Studio installer.
setlocal
set "DSHSTUDIO_ROOT=%~dp0.."
set "PATH=%~dp0;%PATH%"
set "NVIM_APPNAME=dshstudio"
"%~dp0nvim.exe" %*
"@
Set-Content -Path $launcher -Value $cmdContent -Encoding ASCII

$ps1Content = @"
# Generated by the DSH Studio installer.
`$env:PATH = "`$PSScriptRoot;`$env:PATH"
`$env:DSHSTUDIO_ROOT = (Resolve-Path (Join-Path `$PSScriptRoot '..')).Path
`$env:NVIM_APPNAME = 'dshstudio'
& (Join-Path `$PSScriptRoot 'nvim.exe') @args
"@
Set-Content -Path $launcherPs1 -Value $ps1Content -Encoding UTF8

$gui = Join-Path $binDir 'dshstudio-gui.cmd'
$guiContent = @"
@echo off
rem Launch the DSH Studio desktop window (Neovide + Neovim).
setlocal
set "DSHSTUDIO_ROOT=%~dp0.."
set "PATH=%~dp0;%PATH%"
set "NVIM_APPNAME=dshstudio"
if exist "%~dp0neovide.exe" (
  start "" "%~dp0neovide.exe" --wsl false -- %*
) else (
  echo Neovide is not installed; launching in the terminal instead.
  "%~dp0nvim.exe" %*
)
"@
Set-Content -Path $gui -Value $guiContent -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir), 'User')
  Write-Ok "Added $binDir to the user PATH (open a new terminal to pick it up)"
} else {
  Write-Ok "PATH already contains $binDir"
}

# File association for source files (per-user, no admin).
Write-Step "Registering 'Open with DSH Studio' for source files"
$extensions = @('.f90', '.f95', '.f03', '.f08', '.f', '.for', '.c', '.h', '.cpp', '.hpp', '.cc', '.cxx', '.py', '.lua')
$menuText = 'Open with DSH Studio'
foreach ($ext in $extensions) {
  try {
    $extKey = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    New-Item -Path $extKey -Force | Out-Null
    New-ItemProperty -Path $extKey -Name 'DSHStudio.Source' -Value '' -PropertyType None -Force | Out-Null
  } catch { }
}
try {
  $progId = 'HKCU:\Software\Classes\DSHStudio.Source'
  New-Item -Path $progId -Force | Out-Null
  Set-ItemProperty -Path $progId -Name '(default)' -Value 'Source file (DSH Studio)'
  New-Item -Path "$progId\DefaultIcon" -Force | Out-Null
  Set-ItemProperty -Path "$progId\DefaultIcon" -Name '(default)' -Value "$nvimExe,0"
  New-Item -Path "$progId\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path "$progId\shell\open\command" -Name '(default)' -Value "`"$gui`" `"%1`""
  Write-Ok "'$menuText' registered for common source extensions"
} catch {
  Write-Warn2 "Could not register the file association: $($_.Exception.Message)"
  Write-Warn2 "Right-click a file > Open with > Choose another app to set it manually."
}

# Desktop shortcut for the GUI.
if (-not $NoGui -and (Test-Path (Join-Path $binDir 'neovide.exe'))) {
  try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH Studio.lnk'))
    $lnk.TargetPath = $gui
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Description = 'DSH Studio — DeepSeek Harness code editor'
    $lnk.Save()
    Write-Ok 'Desktop shortcut created'
  } catch {
    Write-Warn2 "Could not create the desktop shortcut: $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------------------
# Plugin sync
# ---------------------------------------------------------------------------
if (-not $NoPlugins) {
  Write-Step "Syncing plugins (headless Neovim — first run downloads everything)"
  $env:NVIM_APPNAME = 'dshstudio'
  $env:DSHSTUDIO_ROOT = $Prefix
  $syncLog = Join-Path $env:TEMP 'dshstudio-sync.log'
  & $nvimExe --headless "-c" "lua require('lazy').sync({ wait = true, show = false })" "-c" "qa!" *> $syncLog
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "Plugins synced"
  } else {
    Write-Warn2 "Plugin sync reported errors; see $syncLog"
    Write-Warn2 "Run 'dshstudio' and then :Lazy sync to retry inside the editor."
  }
  Write-Step "Verifying the configuration loads"
  $check = & $nvimExe --headless "-c" "lua local ok = require('dshstudio.tests.probe').run_all({quiet=true}); print(ok and 'SELFTEST_OK' or 'SELFTEST_FAIL')" "-c" "qa!" 2>&1
  $checkText = ($check | Out-String)
  if ($checkText -match 'SELFTEST_OK') {
    Write-Ok "Self-test passed"
  } else {
    Write-Warn2 "Self-test did not pass. Run ':DshSelfTest' inside the editor for details."
  }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'DSH Studio is installed.' -ForegroundColor Green
Write-Host ''
Write-Host "  Terminal editor : dshstudio <file>"
if (-not $NoGui) { Write-Host "  Desktop window  : dshstudio-gui <file>   (or the desktop shortcut)" }
Write-Host "  Config          : $configDir"
Write-Host "  Data / plugins  : $dataDir"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open a NEW terminal so PATH updates apply.'
Write-Host '  2. Make sure the DeepSeek Harness CLI is available:  npm i -g @deepseek-ai/dsh'
Write-Host '  3. Inside the editor press <leader>dd for the DeepSeek panel, <leader>dp for project analysis.'
Write-Host '  4. Run :DshHealth to see language servers and parsers, :DshSelfTest for protocol tests.'
Write-Host ''
Write-Host "Uninstall: delete $Prefix and the PATH entry." -ForegroundColor DarkGray
