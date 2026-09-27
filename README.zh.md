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

### Windows x64

```powershell
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
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

- **自由格式 / 固定格式自动判别**：先看扩展名，`.f` 这类含糊的再看内容特征。
  固定格式保持 tab 不展开、缩进 6 列（尊重列规则），自由格式 2 列缩进。
  读文件时还会纠正文件类型，修掉 `.F90` / `.f` 的判别竞态。
- `<leader>lf` 根据你的 include 路径生成 `.fortls`。
- **离线符号提取**识别 `subroutine`、`function`、`program`、`module`、
  派生 `type`、`interface`，包括 `recursive` / `pure` / `elemental` 前缀、
  `module procedure`、跨行签名，并按 `contains` 嵌套把子程序归属到所属模块。
  所以**没有 fortls 也能看到完整的子程序列表**。

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
      symbols.lua           离线符号提取
      static.lua            USE / #include / import 与调用图
      report.lua            Markdown 报告生成
      analysis.lua          流程编排与报告浏览
    ui/
      sidebar.lua           DeepSeek 面板
      outline.lua           子程序/函数树
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

**固定格式 Fortran 高亮不对。** 格式判别靠扩展名加内容特征，可以手工指定：
`:let b:fortran_fixed_source = 1` 或 `:let b:fortran_free_source = 1`。

**插件没装上。** 在编辑器里执行 `:Lazy sync`。有代理就先设 `HTTPS_PROXY`。

## 许可

MIT，见 [LICENSE](LICENSE)。

Neovim、Neovide 以及所有列出的插件都是各自独立的项目，遵循各自的开源许可。
本仓库只包含配置与集成代码。
