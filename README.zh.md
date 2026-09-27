# VimForge · DSH Studio 中文说明

**一个真正能用的 Vim 编辑器 —— 内置 DeepSeek Harness。**

面向 Fortran / C / C++ / Python：语法高亮、代码跳转、子程序与函数列表、
工程级解析报告，加上一个能直接对话的 AI 侧边栏。装完即用，不影响你现有的 Vim 配置。

> 本项目是独立项目，基于 [Neovim](https://neovim.io) 构建，
> **与 Neovim、Vim、Neovide、DeepSeek 官方均无关联、未获其背书**。
> 依赖与许可证说明见 [CREDITS.md](CREDITS.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 英文主文档（功能全表） |
| [docs/INSTALL.zh.md](docs/INSTALL.zh.md) | **三平台安装说明**：Windows x64 / macOS（Intel 与 Apple 芯片）/ Linux x86_64 |
| [docs/TROUBLESHOOTING.zh.md](docs/TROUBLESHOOTING.zh.md) | **中文排障手册**：按发生频率排序的故障与修复 |
| [docs/ACP.md](docs/ACP.md) | 与 DeepSeek Harness 通信的 ACP 协议契约（实测确认） |
| [docs/DEVELOPING.md](docs/DEVELOPING.md) | 架构、加载顺序、并发规则、测试方法 |
| [docs/MIGRATING.md](docs/MIGRATING.md) | 从你自己的 vim 配置迁移过来 |
| [CREDITS.md](CREDITS.md) | 依赖、许可证、商标说明 |

---

## 为什么这样选型

你原本的需求是"保留 Vim 的高亮和跳转插件、替换 Notepad、要子程序列表、要工程解析"。
如果从零写一个编辑器，高亮、跳转、符号索引、补全都得自己实现，工作量是现在的数倍，
而且很难做到"直接完整可用"。

所以这个项目**不重写编辑器**：

| 你需要的 | 由谁提供 |
|---|---|
| Vim 键位、模态编辑 | Neovim（就是真 Neovim） |
| 语法高亮 | tree-sitter（官方 neovim-treesitter） |
| 跳转、补全、重命名、引用 | clangd / pyright / fortls（LSP） |
| 独立 GUI 窗口 | Neovide（双击即开，像 Notepad） |
| AI 对话与工程解析 | DeepSeek Harness |

本项目做的是**把这些装好、配好**，并补上这些工具对 Fortran 支持不好的部分，
再通过官方 **ACP 协议**（编辑器与 agent 的标准协议）把 DeepSeek 接进来——
不是在侧边栏里开个终端假装集成。

## 功能

### 编辑与导航

- Vim 键位，`<leader>` 是空格
- tree-sitter 高亮：C / C++ / Fortran / Python / Lua / CMake / Markdown / JSON / YAML / Bash
- 跳转定义、声明、实现；查找引用；重命名符号；代码动作；悬停文档；签名帮助
- Telescope 模糊查找：文件 `<leader>ff`、全文 `<leader>fg`、符号 `<leader>fs` / `<leader>fw`
- 文件树 `<leader>e`、git 标记、自动括号、注释、blink.cmp 补全

### 子程序 / 函数列表

`<leader>o` 在左侧打开**符号大纲**：模块、派生类型、子程序、函数、interface、方法，
带嵌套层级和行号，回车跳转，`p` 模糊筛选，`r` 刷新。

数据来源优先用 LSP；**没有语言服务器时自动回退到内置离线解析器**，
所以一个没配 fortls 的 Fortran 工程照样能看到子程序列表。

`:DshProjectSymbols` 可以离线扫全工程并列出所有符号。

### 工程符号树

`<leader>ot` 打开**工程树**：目录 → 文件 → 每个文件声明的符号，整个代码库是一棵可折叠的树。
这对 Fortran/C 混合工程特别有用，因为一个子程序在哪个文件里往往看不出来。

- 按需分块索引，工程再大也不会卡住界面
- 按工程根缓存，`r` 重新索引，`<leader>op` 在全工程符号里模糊筛选
- 走离线解析器，**不需要语言服务器**
- 回车跳转符号 / 折叠目录 / 打开文件

### 针对单个文件或文件夹的程序树

`:DshTree [路径]` 回答的是"**这一处**里面有什么、谁调用了谁"，而不是整个工程：

| 命令 | 作用对象 |
|---|---|
| `:DshTree [路径]` | 指定的文件或文件夹（默认当前文件所在目录） |
| `:DshTree! [路径]` | 同上，但直接打开符号视图 |
| `:DshTreeFile` | 当前缓冲区的文件 |
| `:DshTreeFolder` | 当前文件所在的工程目录 |
| `:DshTreePick` | 先问你要哪个路径 |

两种视图，`Tab` 切换。**调用视图**把找到的入口层层展开，每个符号下面列出它调用的符号，
可以从 `main` 一路往下追；**符号视图**是同一个目标的声明树（模块、类型、接口、子程序、函数）。
回车展开节点或跳到定义，`r` 刷新，`q` 关闭。

全程离线，用的是和大纲同一套提取器，不需要语言服务器。
调用归属按行记录，所以一个符号只记它**自己函数体里**的调用，不会把嵌套在里面的子程序的调用算到它头上。

### DeepSeek 面板

`<leader>dd` 打开右侧面板（对话区 + 输入区），底层直接说 **ACP 协议**
（`dsh --profile acp`），不是抓终端输出。

- 流式回复、可见的推理过程、工具调用实时状态
- **自动注入上下文**：当前文件（或你选中的代码）带行号、所在子程序、声明大纲、
  当前诊断、工程标志文件、git 分支
- 会话中切换模型 `<leader>dm`、推理强度 `<leader>de`，不用重启
- 工具执行前弹权限确认，可配置 `auto_approve`
- `<leader>di` 把回复插入到文件，`<leader>dy` 复制到剪贴板
- `:DshSessions` 列出并恢复历史会话；`<leader>dq` 取消正在进行的回合

### 模型与 API Key（自己选模型、自己填 Key）

模型由你选，Key 由你填。**编辑器不另存一份密钥**——所有东西都放在 Harness 自己的位置，
不会出现"以后找不到存在哪了"的情况。

**选模型。** `<leader>dm` 列出 Harness 当前公布的全部模型，按 provider 分组。
没有可用 Key 的 provider，其选项会标注 `⚠ no key`，让失败可预期；
选中它时会直接问你要不要现在补 Key。

**填 Key。** `:DshAuth` 把 Key 写进 Harness 官方凭证存储
（`$DSH_HOME/.credentials.yaml` 的 `refs:` 段）——和 Harness 自己的工具写的是同一个地方，
所以这个 Key 对所有 Harness 界面都生效，不只是本编辑器。
首次修改前会自动备份，注释行会保留；存储是热重载的，所以**下一条请求就生效，不用重启**。
`:DshProviders` 查看状态表。

Key 的优先级就是 Harness 的规则：**启动环境变量 → 存储文件 → 项目 `.env` → Harness 家目录 `.env`**。
也就是说你手动 export 的变量依然优先，CI 场景正是想要这个行为。

```
:DshAuth              交互式管理 Key
:DshProviders         查看 provider 与 Key 状态
:DshModel             切换模型
:DshEffort            切换推理强度
```

**加自己的 provider。** 出厂只路由了 DeepSeek 和 Xiaomi。
要接入任何 OpenAI 兼容网关或其他 pi-ai provider，在 `$DSH_HOME/settings.yaml`
里按下面的格式声明一条路由（带凭证引用名），然后填 Key 即可——
编辑器的 provider 列表会自动识别，**即使 agent 还没公布它**：

```yaml
llm-pi-ai:
  providers:
    acme-gateway:
      displayName: Acme Gateway
      apiKeyEnv: ACME_GATEWAY_API_KEY      # :DshAuth 会写入这个名字
      baseURL: https://gateway.example.com/v1
      api: openai-completions
agent-default-model:
  provider: deepseek-official
  model: deepseek-flash
```

如果你更习惯用 Harness 自带的界面完成登录（OAuth、交互式 Key），
在终端跑一次 `dsh` 即可，那边保存的凭证在这里直接可用。

> **关于密钥安全，必须说清楚：** Harness 的 agent 工具进程以**同一个操作系统用户**运行，
> 所以 agent 能用的 Key，agent 就能读到——文件权限无法把两者隔开。
> 不要把权限范围超出你愿意交给 agent 的 Key 存进去。

### 工程解析（deepwiki 式）

`<leader>dp` 打开菜单，或直接 `:DshAnalyze!`。

分两层，**断网也能出结果**：

1. **静态分析（离线、秒出）**：扫描目录树、提取符号、解析
   `USE` / `#include` / `import` 依赖、构建调用图、找入口点和最大文件。
2. **AI 架构说明（可选）**：把静态摘要交给 `dsh --profile headless`，
   追加一段架构评述。

结果写到 `<工程>/.dshstudio/analysis-<时间戳>.md` 并在新标签页打开：
工程概览、目录树、模块与类型、子程序/函数表、依赖分析、调用图要点、
入口点、最大文件、AI 说明。

## 支持平台

三种系统架构都支持，细节见 [docs/INSTALL.zh.md](docs/INSTALL.zh.md)。

| | Windows 10/11 **x64** | **macOS** 11+（Intel 与 Apple 芯片） | **Linux x86_64** |
|---|---|---|---|
| 终端编辑器 | `dshstudio` | `dshstudio` | `dshstudio` |
| 独立窗口 | `dshstudio-gui`（Neovide）+ 桌面快捷方式 | `dshstudio-gui` + `DSH Studio.app` | `dshstudio-gui` + 桌面项，可选 AppImage |
| 使用的 Neovim 构建 | `nvim-win64.zip` | `nvim-macos-arm64` / `nvim-macos-x86_64` | `nvim-linux-x86_64` |
| 安装脚本 | `install-windows.ps1`（PowerShell 5.1+） | `install-unix.sh`（bash） | `install-unix.sh`（bash） |
| 文件关联 | 注册"用 DSH Studio 打开" | 应用包内声明文档类型 | 桌面项 `MimeType=` |
| 额外要求 | 建议用 Windows Terminal | 图标字形需 Nerd Font | Neovide AppImage 需要 FUSE |

Windows ARM64 用 x64 版本（系统转译运行）。Linux ARM64 上游没有官方 Neovim 包，
设置 `DSHSTUDIO_USE_SYSTEM_NVIM=1` 并使用发行版的 Neovim 0.11+。

各平台的语言服务器、编译器与包管理器命令不同，对照表见
[docs/INSTALL.zh.md](docs/INSTALL.zh.md) 第 4 节。

## 依赖

- **Neovim 0.11+**（安装脚本会自动装）
- **Node.js 18+**，用来跑 DeepSeek Harness：`npm i -g @deepseek-ai/dsh`
- **git**（插件管理器需要）
- 可选：`clangd`、`pyright`、`fortls`（语言服务器，`clangd`/`pyright` 可用 `:Mason` 一键装）
- 可选：`gcc` / `g++` / `gfortran`、`cmake`、`make`（编译运行用）

## 安装

### 下载现成安装包（推荐：不需要再装别的东西）

每个 Release 都提供**三平台各自的自包含压缩包**。包内已经带了本配置**和该平台官方 Neovim**，
解压即可开始编辑——不用另装 Neovim、不用包管理器、不需要联网。

| 平台 | 下载 | 然后 |
|---|---|---|
| **Windows 10/11 x64** | [`VimForge-0.1.0-windows-x64.zip`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-windows-x64.zip) | 解压后运行 **`install.cmd`** |
| **macOS 11+**（Intel **与** Apple 芯片） | [`VimForge-0.1.0-macos-universal.tar.gz`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-macos-universal.tar.gz) | `tar xzf … && cd VimForge-* && ./install.sh` |
| **Linux x86_64** | [`VimForge-0.1.0-linux-x86_64.tar.gz`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-linux-x86_64.tar.gz) | `tar xzf … && cd VimForge-* && ./install.sh` |

全部版本与校验和：**[github.com/nickedfrc/VimForge/releases](https://github.com/nickedfrc/VimForge/releases)**。
运行前可用 `SHA256SUMS.txt` 校验下载是否完整。

macOS 包里**同时包含** Intel 与 Apple 芯片两个 Neovim 构建，启动器会自动选择，
所以一次下载通吃两种机型。

只有 AI 功能需要额外依赖——Node.js 18+ 和 Harness CLI：

```bash
npm install -g @deepseek-ai/dsh
```

之后 `:DshAuth` 填 API Key，`<leader>dm` 选模型。

### 或者用安装脚本（克隆仓库，脚本自动下载 Neovim）

```bash
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
```

**Windows x64**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

装到 `%LOCALAPPDATA%\DSHStudio`，把 `dshstudio` 加进用户 PATH，
给常见源码扩展名注册"用 DSH Studio 打开"，并创建 GUI 桌面快捷方式。

可用参数：`-NoGui`（只装终端版）、`-NoPlugins`（跳过插件下载）、`-Prefix <目录>`。

### macOS / Linux

```bash
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
./scripts/install-unix.sh
```

装到 `~/.local/share/dshstudio`，生成 `dshstudio` 和 `dshstudio-gui`，
macOS 额外生成 `DSH Studio.app`，Linux 生成桌面项。

可用参数：`--no-gui`、`--no-plugins`、`--prefix 目录`、`--appimage`。

两个安装脚本结束时都会**自动跑一遍离线自检**并报告配置能否加载。

### 为什么不会破坏你现有的 Vim

安装器用 `NVIM_APPNAME=dshstudio` 启动，Neovim 会把配置和数据目录整体隔离开：

- 你的 `~/.config/nvim`、`~/.vimrc` 完全不被读取也不被修改
- 本项目的插件装在 `~/.local/share/dshstudio` 下
- 卸载 = 删掉安装目录 + 移除 PATH 里那一行

想把自己的配置搬过来？见 [docs/MIGRATING.md](docs/MIGRATING.md)，
个人改动写在 `lua/dshstudio/user.lua`（复制 `user.example.lua`），升级不会覆盖。

## 第一次使用

```bash
dshstudio                    # 终端里打开
dshstudio-gui mycode.f90     # 独立窗口打开（替换 Notepad 的用法）
```

进入编辑器后：

| 按键 | 作用 |
|---|---|
| `<leader>dd` | 开关 DeepSeek 面板 |
| `<leader>da` | 就选中的代码提问 |
| `<leader>dp` | 工程解析菜单 |
| `<leader>o` | 开关符号大纲（子程序/函数列表） |
| `:DshTree` | 程序树：指定文件或文件夹的调用层级与符号 |
| `<leader>dm` | 切换模型 |
| `:DshHealth` | 查看语言服务器、解析器、CLI 探测结果 |
| `:DshSelfTest` | 跑离线协议自检 |
| `:DshPing` | 端到端验证 Harness 能否应答 |

**出任何问题，第一件事是 `:DshHealth`。** 它会明确告诉你哪个语言服务器没找到、
哪个解析器没装、CLI 是怎么被定位到的。

## 语言服务器

| 语言 | 服务器 | 安装方式 |
|---|---|---|
| C / C++ | `clangd` | `:Mason`（自动）或 LLVM 官方包 |
| Python | `pyright` | `:Mason`（自动）或 `npm i -g pyright` |
| Lua | `lua_ls` | `:Mason`（自动） |
| Fortran | `fortls` | `pip install fortran-language-server`，或在有配方时用 `:Mason` |

缺服务器不会导致编辑器不可用：仍然有高亮和离线大纲。`:DshHealth`
会列出缺失的二进制名和你系统对应的安装命令。

### C / C++ 的头文件路径

clangd 靠 `compile_commands.json` 找头文件。CMake 工程配置时加
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`（`<leader>lb` 编译命令已经带上了）。
其他情况用 `<leader>lc` 根据配置生成 `.clangd`。

### Fortran 的特殊处理

现成配置在 Fortran 上最容易崩，这里做了针对性处理：

- **自由格式 / 固定格式自动判别**：判别规则只有一份（`dshstudio.project.sniff`），
  所以**编辑器的高亮和工程分析读同一份文件的方式永远一致**。
  `.f90`/`.f95`/`.f03`/`.f08` 直接认定为自由格式；其余的看内容。
  固定格式保持 tab 不展开、缩进 6 列（尊重列规则），自由格式 2 列缩进。
  读文件时还会纠正文件类型，修掉 `.F90` / `.f` 的判别竞态。
- **老式文件名**：GAMESS 这类程序用 `foo.src` 命名源码、`bar.inc` 命名 include，
  这些名字本身不说明语言，Neovim 干脆不给文件类型。现在改成按前几行判断，
  于是高亮、缩进、语言服务器、语法解析器都能用上，工程分析也不再跳过它们。
  详见 [老式源码与固定格式](#老式源码与固定格式)。
- `<leader>lf` 根据你的 include 路径生成 `.fortls`。
- **离线符号提取**识别 `subroutine`、`function`、`program`、`module`、
  派生 `type`、`interface`，包括 `recursive` / `pure` / `elemental` 前缀、
  `module procedure`、跨行签名，并按 `contains` 嵌套把子程序归属到所属模块。
  所以**没有 fortls 也能看到完整的子程序列表**。

## 老式源码与固定格式

Fortran 77 把语义放在**列**上：第 1 列是 `C`、`c`、`*` 或 `!` 就整行是注释，
第 6 列是续行标记，语句从第 7 列开始。按自由格式去读不会报错，而是**安静地读错**。
在一份 7785 行的 GAMESS 风格 deck 上，自由格式读法把注释行里写的 20 个 `CALL`
当成了 20 个真实调用。

这些规则只实现一次（`lua/dshstudio/project/sniff.lua`），三处共用：

| 使用方 | 决定什么 |
|---|---|
| `lang.lua` | 缓冲区的文件类型与 Fortran 格式 |
| `project/symbols.lua` | 哪些行是声明 |
| `project/static.lua` | 哪些行是 `use` / `call` / `include` |

**判断格式。** `.f90`/`.f95`/`.f03`/`.f08` 一律算自由格式；其余的看内容，
用"语句是否出现在第 7 列"作为**精确判据**：固定格式要求所有语句都在第 7 列开始，
因此同一个关键字出现在别的缩进位置就证明是自由格式。
这条判据同时避免了把自由格式里的 `contains`、`character` 误当成第 1 列的 `C` 注释。

**名字不说明语言的文件。** `.src`、`.inc`、`.ins` 在 Fortran / C / C++ 工程里都在用，
所以按内容判断，而且**只在证据明确时才下结论**，含糊的文件宁可不动。
一份 `.src` deck 会以 Fortran 打开并使用正确的列规则，一个 `.inc` 的 C 头文件会以 C 打开。
判别必须保守，因为"像 Fortran"的信号到处都是：Lua 也用 `end` 结束块、
`function` 是 Lua 关键字、Markdown 的列表项以 `*` 开头、`class` 属于 C++ 也属于 Python。

固定格式 Fortran **故意跳过 tree-sitter**：该语法树只描述自由格式，
在固定格式 deck 上它的输出不只是漏掉声明，而是描述了另一段文本，
合并进来会凭空造出符号。正则提取器两种格式都懂，交给它做。

## 配置

配置优先级：内置默认值 → `vim.g.dshstudio` → `DSHSTUDIO_*` 环境变量 → `setup(opts)`。

```lua
vim.g.dshstudio = {
  sidebar_width = 50,
  auto_context = true,          -- 每次提问是否自动带上当前文件
  context_max_bytes = 24000,
  auto_approve = 'ask',         -- 'ask' | 'always' | 'never'
  model = '["deepseek-official","deepseek-v4-pro"]',   -- 注意是 JSON 字符串
  reasoning_effort = 'high',
  agent_command = { 'dsh' },    -- 手动指定 CLI
  fortran_include_dirs = { 'include', 'build/mod' },
  extra_include_dirs = { 'include', 'third_party' },
  analysis_output_dir = '.dshstudio',
  keymaps = true,
}
```

常用环境变量：

| 变量 | 用途 |
|---|---|
| `NVIM_APPNAME=dshstudio` | 隔离配置，不碰你原来的 Neovim |
| `DSHSTUDIO_DSH_BIN` | 指定 Harness 启动器绝对路径 |
| `DSHSTUDIO_AGENT_COMMAND` | 覆盖 agent 命令 |
| `DSHSTUDIO_ROOT` | 发行版根目录（启动器自动设置） |

## DeepSeek 集成是怎么做的

用了 Harness 的两个 profile，各司其职。协议细节和实测记录见
[docs/ACP.md](docs/ACP.md)，这里只说结论。

**交互式 —— `dsh --profile acp`。** ACP 是 JSON-RPC 2.0，一行一个 JSON，
stdout 只走协议。面板实现客户端：

```
---> initialize            { protocolVersion: 1, clientCapabilities, clientInfo }
<--- { agentInfo, agentCapabilities, authMethods }

---> session/new           { cwd, mcpServers: [] }
<--- { sessionId, configOptions: [ model, reasoning_effort ] }

---> session/prompt        { sessionId, prompt: [ { type: "text", text } ] }
<--- session/update        agent_message_chunk / agent_thought_chunk
                           tool_call / tool_call_update / usage_update
<--> session/request_permission   （客户端回 allow-once / reject-once）
<--- { stopReason: "end_turn" }
```

**批量 —— `dsh --profile headless "<任务>"`。** 跑一次任务、打印最终答案、退出，
工程解析的 AI 部分用它。

几个踩过的坑（都已在代码里处理，写在这里免得你重新踩）：

1. **切换模型时 `value` 必须是 JSON 编码的字符串**，例如
   `"[\"deepseek-official\",\"deepseek-v4-pro\"]"`；直接传数组会被拒绝，
   字段名是 `configId` 不是 `optionId`。
2. **headless 的任务只能通过命令行参数传**，用管道喂 stdin 会直接报
   `error: a task is required`。所以大摘要改成写文件、让 agent 自己读。
3. **权限确认没有服务端超时**：不回答就一直卡着。所以面板总是立刻应答。
4. **模型 provider 没登录时**，切换会成功，但下一条提问返回
   `401 Invalid API Key`。面板会识别这种情况并提示你去换模型或先登录。

## 自检与测试

```bash
# 离线协议 + 上下文测试（不需要网络，不需要启动 agent）
nvim --headless --cmd "set rtp+=./nvim-deepseek-studio" \
     -c "lua require('dshstudio.tests.probe').main()"

# 语法检查（自带词法检查器，不需要 Lua 工具链）
node tests/lua_syntax_check.js ./nvim-deepseek-studio

# 用真实 Lua 5.1 语法解析器复核（需先 npm install luaparse）
node tests/lua_parse_check.js ./nvim-deepseek-studio

# 编辑器内
:DshSelfTest
```

协议测试用**注入式假传输**驱动客户端，所以分帧、id 关联、跨块切割、CRLF、
错误响应、权限回调、取消、进程退出这些都能在 CI 里覆盖，不需要真进程。

## 目录结构

```
nvim-deepseek-studio/
  init.lua                  入口：选项、lazy.nvim 引导、模块装配
  plugin/dshstudio.lua      用户命令（全部防御式注册）
  lua/dshstudio/
    config.lua              默认值与配置合并
    editor.lua keymaps.lua  选项与键位
    lsp.lua lang.lua        语言服务器；Fortran/C/C++/Python 特有处理
    treesitter.lua          解析器管理（兼容两种分支）
    plugins.lua             插件清单
    core/
      acp.lua               ACP 客户端：分帧、请求关联、回调
      session.lua           会话状态、流式渲染、模型切换
      context.lua           提问时注入什么上下文
      headless.lua          一次性 Harness 任务（工程解析）
    project/
      scan.lua              目录扫描与语言统计
      sniff.lua             按内容判断语言与 Fortran 格式
      symbols.lua           离线符号提取
      static.lua            USE / #include / import 与调用图
      report.lua            Markdown 报告生成
      analysis.lua          流程编排与报告浏览
    ui/
      sidebar.lua           DeepSeek 面板
      outline.lua           子程序/函数树
      calltree.lua          程序树（调用层级 + 符号）
      project_tree.lua      全工程符号树
    user.example.lua        个人配置模板（复制成 user.lua）
    tests/probe.lua         离线自检
scripts/                    安装脚本（Windows PowerShell / Unix bash）
docs/ACP.md                 实测确认的 ACP 协议契约
docs/MIGRATING.md           从你自己的 vim 配置迁移
```

## 常见问题

**面板提示找不到 agent。** 先 `npm i -g @deepseek-ai/dsh`，再用
`:DshHealth` 看探测结果。也可以用 `DSHSTUDIO_DSH_BIN` 直接指定路径。

**某个模型报 `401 Invalid API Key`。** 那个 provider 没登录。先在终端跑一次
`dsh` 完成登录，或用 `<leader>dm` 换成别的模型。

**看不到子程序列表。** 先看 `:DshHealth` 有没有在跑语言服务器；没有也没关系，
直接开大纲（`<leader>o`）走离线解析。超大生成文件可能要多等一会儿。

**clangd 找不到头文件。** 用 `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` 重新配置，
或者设置 `extra_include_dirs` 后跑 `<leader>lc`。

**固定格式 Fortran 高亮不对。** 格式判别先看扩展名、再看内容，内置语法文件自己猜错时
会自动重新加载。也可以手工指定：`:let b:fortran_fixed_source = 1`
或 `:let b:fortran_free_source = 1`。

**`.src` / `.inc` 文件打开后没有高亮。** 这类文件是按内容判断的，证据不明确时不会硬猜。
用 `:set filetype?` 看当前类型；如果是空的，说明前几行没能确定语言，
可以手工设一次 `:setf fortran`（或 `c`），或者在文件里加一个 `modeline`。

**插件没装上。** 在编辑器里执行 `:Lazy sync`。有代理就先设 `HTTPS_PROXY`。

## 许可

MIT，见 [LICENSE](LICENSE)。

Neovim、Neovide 以及所有列出的插件都是各自独立的项目，遵循各自的开源许可。
本仓库只包含配置与集成代码。
