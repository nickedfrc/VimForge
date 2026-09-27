# 安装与平台说明（中文）

支持 **Windows x64**、**macOS（Intel 与 Apple 芯片）**、**Linux x86_64**。
本文说明三个平台各自的安装方式、依赖差异、验证方法、卸载方式和已知问题。

只想先跑起来的话，每个平台一条命令：

```powershell
# Windows x64（PowerShell）
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

```bash
# macOS 或 Linux
./scripts/install-unix.sh
```

---

## 1. 三平台支持矩阵

| | Windows 10/11 x64 | macOS 11+ | Linux x86_64 |
|---|---|---|---|
| 终端编辑器 | ✅ `dshstudio` | ✅ `dshstudio` | ✅ `dshstudio` |
| 独立窗口 | ✅ `dshstudio-gui`（Neovide） | ✅ `dshstudio-gui`，并生成 `DSH Studio.app` | ✅ `dshstudio-gui`（Neovide AppImage），可选打包 AppImage |
| Neovim 来源 | 官方 `nvim-win64.zip` | 官方 `nvim-macos-{x86_64,arm64}.tar.gz` | 官方 `nvim-linux-x86_64.tar.gz`（失败时回退旧的 `nvim-linux64`） |
| 配置目录 | `%XDG_CONFIG_HOME%\dshstudio` | `~/.config/dshstudio` | `~/.config/dshstudio` |
| 数据/插件目录 | `%LOCALAPPDATA%\DSHStudio\data` | `~/.local/share/dshstudio/data` | `~/.local/share/dshstudio/data` |
| 文件关联 | 常见源码扩展名注册"用 DSH Studio 打开" | `DSH Studio.app` 文档类型 | `.desktop` 桌面项的 `MimeType=` |
| 桌面快捷方式 | ✅ 桌面创建 | `~/Applications` 里的应用 | `~/.local/share/applications` 桌面项 |
| 安装脚本环境 | PowerShell 5.1+（系统自带） | bash 3.2+（系统自带） | bash 4+ |

**Windows ARM64**：没有单独构建，x64 版本靠系统转译运行，安装脚本会提示但继续。

**Linux ARM64（aarch64）**：上游没有官方预编译 Neovim 包。设置
`DSHSTUDIO_USE_SYSTEM_NVIM=1` 用发行版的 Neovim，或自行安装后软链到安装前缀。

**Apple 芯片**用 `nvim-macos-arm64`，Intel 用 `nvim-macos-x86_64`，脚本按 `uname -m` 自动选择。

---

## 2. 安装脚本做了什么

两个脚本都是同样的五步：

1. **下载 Neovim**（stable）到 `<前缀>/bin`，已存在则跳过。
   Linux 上会把目录结构归一化，保证 `<前缀>/bin/nvim` 一定存在（旧版归档的解包布局不同）。
2. **下载 Neovide**（最新 release），除非传了 `--no-gui`/`-NoGui`。
   macOS 的 `.dmg` 无法非交互解包，脚本会**如实说明**而不是假装成功；
   `dshstudio-gui` 在 `/Applications/Neovide.app` 存在时会优先使用它。
3. **生成启动器**：`dshstudio`（终端）与 `dshstudio-gui`（窗口）。
   两者都设置 `NVIM_APPNAME=dshstudio`，这是本发行版与你的 Neovim 互不干扰的关键。
4. **注册桌面集成**：PATH、文件关联、快捷方式、`.desktop` 或 `.app`。
5. **同步插件并自检**：headless 跑 `lazy.nvim` 同步，然后跑离线自检并报告配置能否加载。

### 为什么 `NVIM_APPNAME` 很重要

Neovim 依据 `NVIM_APPNAME` 决定配置与数据目录。用 `NVIM_APPNAME=dshstudio` 启动意味着：

- 你的 `~/.config/nvim`（或 `%LOCALAPPDATA%\nvim`）**完全不被读取也不被写入**
- 插件、shada、undo、LSP 缓存都放在本发行版自己的目录下
- 卸载 = 删掉一个目录

这也是它能和现有 Neovim 共存、不需要你冒险的原因。

### 可用参数

`scripts/install-windows.ps1`

| 参数 | 作用 |
|---|---|
| `-NoGui` | 不装 Neovide，只要终端版 |
| `-NoPlugins` | 跳过插件同步（离线准备） |
| `-Prefix <目录>` | 安装根目录，默认 `%LOCALAPPDATA%\DSHStudio` |
| `-NvimVersion <tag>` | Neovim 版本标签，默认 `stable` |

`scripts/install-unix.sh`

| 参数 | 作用 |
|---|---|
| `--no-gui` | 不装 Neovide |
| `--no-plugins` | 跳过插件同步 |
| `--prefix DIR` | 安装根目录，默认 `~/.local/share/dshstudio` |
| `--appimage` | 打包单文件 AppImage 启动器（需要 `appimagetool`） |

---

## 3. 手动安装（任意平台）

已有 Neovim 0.11+，想自己掌控：

```bash
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
```

**务必给这套配置独立的应用名**，这样不会碰你原来的配置：

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

然后同步插件并验证：

```bash
nvim --headless "+Lazy! sync" +qa
nvim
```

也可以不复制，直接用 `-u` 指定配置启动：

```bash
nvim -u ./nvim-deepseek-studio/init.lua
```

注意 `-u` 不会设置 `NVIM_APPNAME`，插件数据会落到你常规的数据目录里。
在意隔离就用 `NVIM_APPNAME` 那条路。

---

## 4. 三平台依赖

### 三平台都需要

| 依赖 | 用途 | 安装 |
|---|---|---|
| Neovim 0.11+ | 编辑器本体 | 安装脚本，或包管理器 |
| Node.js 18+ | 运行 DeepSeek Harness | [nodejs.org](https://nodejs.org) |
| DeepSeek Harness | AI 功能 | `npm i -g @deepseek-ai/dsh` |
| git | 下载插件 | 安装脚本/包管理器 |

### 语言服务器

| 语言 | Windows | macOS | Linux |
|---|---|---|---|
| C / C++ | `winget install LLVM.LLVM`，或用 `:Mason` | `brew install llvm`，或用 `:Mason` | `apt install clangd` / `dnf install clang-tools-extra`，或用 `:Mason` |
| Python | `:Mason` 或 `npm i -g pyright` | 同左 | 同左 |
| Lua | `:Mason` | `:Mason` | `:Mason` |
| Fortran | `pip install fortran-language-server` | `brew install fortls` 或 pip | `pip install fortran-language-server` |

首次启动时 `:Mason` 会自动装 clangd、pyright、lua_ls；fortls 在部分平台没有配方，
所以 pip 是最可靠的途径。**缺服务器不影响可用性**：仍有高亮和离线符号大纲。

### 编译运行（需要的话）

| 语言 | Windows | macOS | Linux |
|---|---|---|---|
| Fortran | `gfortran`（MSYS2，或 LLVM `flang`） | `brew install gcc` | `apt install gfortran` |
| C / C++ | MSVC Build Tools，或 MSYS2 `gcc` | Xcode 命令行工具 | `apt install build-essential` |
| CMake | `winget install Kitware.CMake` | `brew install cmake` | `apt install cmake` |

### 终端建议

- **Windows**：用 Windows Terminal。旧版控制台画不好侧边栏边框和图标字形。
- **macOS**：iTerm2 或自带终端都行；图标字形需要 Nerd Font
  （`brew install --cask font-jetbrains-mono-nerd-font`）。
- **Linux**：任何支持真彩色的现代终端。

---

## 5. 验证安装

编辑器内按顺序：

| 命令 | 检查内容 |
|---|---|
| `:DshHealth` | CLI 探测、语言服务器可用性、已装解析器 |
| `:DshSelfTest` | 17 项离线行为测试（协议、会话、符号提取） |
| `:DshPing` | 端到端：Harness 能否应答 |
| `:checkhealth` | Neovim 自身报告（provider、LSP、treesitter） |

不开界面，命令行里：

```bash
# 语法与模块检查（只需 Node，不需要 Lua 工具链）
node tests/lua_syntax_check.js ./nvim-deepseek-studio
node tests/check_requires.js ./nvim-deepseek-studio

# 行为测试
nvim --headless --cmd "set rtp+=$PWD/nvim-deepseek-studio" \
     -c "lua require('dshstudio.tests.probe').main()"
```

安装脚本会自动跑最后一条并打印结果。

---

## 6. 卸载

本发行版只写自己的前缀和 `NVIM_APPNAME` 目录，不动别的东西。

**Windows**

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\DSHStudio"
# 再从用户 PATH 里删掉那个 bin 目录
```

想要更彻底可以顺手删掉桌面的 "DSH Studio" 快捷方式。

**macOS / Linux**

```bash
rm -rf ~/.local/share/dshstudio          # 程序 + 插件
rm -rf ~/.config/dshstudio               # 配置副本（如果安装脚本建过）
rm -f  ~/.local/share/applications/dshstudio.desktop   # 仅 Linux
rm -rf "$HOME/Applications/DSH Studio.app"             # 仅 macOS
```

然后删掉安装脚本提示你加进 `.profile`/`.zshrc` 的那行 `export PATH`。

你自己的 `~/.config/nvim` 和 `~/.vimrc` 全程不受影响。

---

## 7. 各平台已知问题

**Windows —— 装了 `dsh` 却找不到。** CLI 是 `.cmd` 包装脚本，探测逻辑会优先找真正的 node 二进制。
仍失败就在配置里设 `agent_command = { 'cmd', '/c', 'dsh' }`。

**Windows —— 推送 `.github/workflows` 被拒。** 不带 `workflow` scope 的 GitHub token
无法创建 workflow 文件。所以 CI 工作流不在首次提交里；请在网页上添加，或用带该 scope 的 token 推送。

**Windows —— 源码带 UTF-8 BOM。** 已处理：解析前会剥离 BOM。
BOM 曾导致文件首行的 `module`/`program` 从符号列表里消失，而 Windows 编辑器默认会写 BOM。

**macOS —— 从程序坞启动时找不到语言服务器。** GUI 应用不继承 shell 的 PATH。
从终端启动 `dshstudio-gui`，或在配置的 `lsp.*` 里写明服务器路径。

**macOS —— Neovide 的 `.dmg`。** 脚本无法非交互挂载并复制。手动打开、拖进 Applications，
再重跑安装脚本让它能发现。

**Linux —— Neovide AppImage 需要 FUSE。** 没有就用 `--appimage-extract-and-run`，
或改用发行版自带的包。

**Linux ARM64 ——** 上游没有 Neovim 预编译包，用
`DSHSTUDIO_USE_SYSTEM_NVIM=1` 配合发行版的 Neovim 0.11+。

**全平台 —— 固定格式 Fortran 缩进。** 先按扩展名判断，`.f` 这类含糊的再看内容特征。
可强制指定：`:let b:fortran_fixed_source = 1` 或 `b:fortran_free_source = 1`。
