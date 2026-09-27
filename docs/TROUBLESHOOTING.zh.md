# 排障手册（中文）

按**实际发生频率**排序。遇到任何问题，第一步永远是 **`:DshHealth`** ——
它会打印：Harness CLI 的探测结果、每个语言服务器的状态、已安装的 tree-sitter 解析器。

如果 `:DshHealth` 本身报错，接着跑 `:DshSelfTest`；如果它也报错，说明配置目录损坏了，
直接重新复制 `nvim-deepseek-studio` 目录比排查更快。

---

## 面板提示找不到 agent

`:DshHealth` 显示 `Harness CLI: NOT FOUND`。

```bash
npm install -g @deepseek-ai/dsh
dsh --version          # 确认它在 PATH 上
```

装在非常规位置时，手动指定：

```lua
vim.g.dshstudio = { agent_command = { 'node', '/path/to/dsh/lib/bin.js' } }
```

或设置环境变量 `DSHSTUDIO_DSH_BIN`。探测顺序是：你的配置 → `DSHSTUDIO_DSH_BIN`
→ PATH 上的 `dsh` → 已知的 npx 缓存 → `npx -y` 兜底。

**Windows** 上 CLI 是 `.cmd` 包装脚本。探测逻辑会优先找真正的 node 二进制以避开这个问题；
若全局安装后仍找不到，把 `agent_command` 设为 `{ 'cmd', '/c', 'dsh' }`。

## 某个模型报 `401 Invalid API Key`

面板会原样显示这个错误并附上提示：该模型所属 provider 没登录。

- 在终端跑一次 `dsh` 完成登录，**或者**
- 用 `<leader>dm` 换别的模型（每个选项都标了 provider 分组，能看出自己在选谁）。

注意：**切换模型本身一定成功**，失败只会出现在下一条提问上，因为 provider 是那时才联系的。
这是上游行为，不是面板的 bug。

## 回复被粘成一条，或 reasoning 之后的文字位置不对

这是早期版本的真实 bug，已修复，并由 `:DshSelfTest` 里的
`session: transcript assembly` 用例覆盖。如果你又遇到了，跑一下那个用例——
它失败就说明状态机回归了。

## 刷新侧边栏或大纲时编辑器卡死

同样是已修复的 bug：大纲和上下文构建原先用 `vim.lsp.buf_request_sync`，
语言服务器不响应时会让 Neovim 主循环**无限阻塞**。现在两处都改成了带超时的异步 API。
**不要**在新代码里同步调用 LSP。

## 看不到子程序 / 函数列表

1. `:DshHealth` —— 该文件类型有语言服务器在跑吗？
2. 没有也没关系：按 `<leader>o`。大纲会自动回退到内置离线解析器，不需要服务器。
3. 如果某个本该识别的文件大纲是空的，检查 `:set filetype?`。
   解析器依赖文件类型，一个 `.F90` 文件如果被识别成 `fortran77` 或 `text` 就不会被解析。

离线解析器识别 Fortran 的 `module`、`program`、`subroutine`、`function`、派生 `type`、
`interface`、`module procedure`（含 `recursive`/`pure`/`elemental` 前缀和 `contains` 嵌套）；
C/C++ 的函数、`class`/`struct`/`union`/`enum`、`#define`、命名空间；
Python 的 `def`、`async def`、`class`（按缩进嵌套）。

## 工程报告里写"0 个模块"，或符号缺失

已修复：原先只要 tree-sitter 返回了任何符号，就不再走正则兜底；
而 Fortran 语法树可能识别出嵌套的 `type` 却漏掉外层 `module`。
现在两遍提取都会跑并合并结果，同时兼容 **BOM**（Windows 编辑器默认会加；
BOM 曾导致文件首行的 `module` / `program` 被整行漏掉）。

如果报告内容仍偏少，按 `<leader>or` 重新索引，再和单文件大纲对照一下。

## 工程解析失败或卡住

- 静态部分完全离线；失败时消息会指明卡在哪一步。
- AI 部分需要 Harness。用 `:DshPing` 单独验证它能否应答。
- 超大工程有文件数/单文件字节上限，报告里会注明被截断。
- AI 摘要写到 `<工程>/.dshstudio/` 下由 agent 自己读，因为 `headless` profile
  **只接受命令行参数传任务**，而 Windows 命令行上限约 32k 字符。

## clangd 找不到头文件

clangd 依赖 `compile_commands.json`：

```bash
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

CMake 工程用 `<leader>lb` 编译时已经带上了这个开关。
其他情况在配置里设 `extra_include_dirs`，然后 `<leader>lc` 生成 `.clangd`。

## Fortran 高亮或缩进不对

`.f90` / `.f95` / `.f03` / `.f08` 一律算自由格式；其余的由
`lua/dshstudio/project/sniff.lua` 按内容判断，内置语法文件自己猜错时会自动重新加载。
可以按缓冲区强制指定：

```vim
:let b:fortran_free_source = 1
:let b:fortran_fixed_source = 1
```

固定格式保持 tab 不展开、缩进 6 列；自由格式 2 列。
想对某个文件类型退回经典正则高亮，见 [MIGRATING.md](MIGRATING.md) 第 4 节。

## `.src` / `.inc` 文件没有高亮，或分析里看不到它

这类文件名不说明语言，Neovim 不会给它文件类型，工程扫描以前也会跳过它。
现在改成按前几行判断。如果某个文件仍然是空的，说明前几行不足以明确判断语言，
程序**故意不猜**——因为 `end`、`function`、`*`、`class` 在别的语言里同样常见。

看一下判断结果：

```vim
:set filetype?
```

如果是空的，手工设一次（`:setf fortran` 或 `:setf c`），或者在文件里加 `modeline`。
以第 1 列 `C` 注释或第 7 列语句开头的 Fortran deck 会自动识别，
详见 [老式源码与固定格式](../README.zh.md#老式源码与固定格式)。

## 调用图里出现了并不存在的调用

如果某个 `CALL` 只出现在固定格式文件的注释里，说明这个文件被当成自由格式读了。
格式是逐文件判断的，用 `:echo b:dshstudio_fortran_form` 确认，再按上面的办法强制指定。

## 在较新的 Neovim 上提示 "This build needs Neovim 0.11+"

这是 `0.1.0` 及之前版本的一个真实 bug，不是版本问题。
`vim.lsp.config` 在 Neovim 0.11 里是普通函数，在 0.12 里是**可调用的 table**，
而 LSP 初始化前面的判断写的是 `type(...) == 'function'`。
在 0.12 上这个判断为假，于是弹出这条提示，并且**所有语言服务器都被跳过**——
补全、诊断、跳转定义全部失效。

现已修复：判断改成"只要能调用就算可用"，`:DshSelfTest` 也覆盖了这条。
升级到 `0.1.0` 之后的版本即可；也可以用 `:lua print(type(vim.lsp.config))` 自行确认。
如果暂时无法升级，可以手工启动服务器：

```vim
:lua vim.lsp.enable({ 'clangd', 'pyright', 'fortls' })
```

## 找不到 fortls

`pip install fortran-language-server`，或在有配方时用 `:Mason` 安装。
然后 `<leader>lf` 会根据你的 include 路径生成 `.fortls`。
在装上之前，高亮和离线大纲照常可用。

## 插件没装上

编辑器里执行 `:Lazy sync`，用 `:Lazy log` 看日志。

- 有代理就先设 `HTTPS_PROXY` / `HTTP_PROXY`。
- `lazy.nvim` 首次启动时通过 clone 引导。引导检查的是**模块入口文件**而不是目录，
  所以第一次运行中断留下的空目录会在下次启动自愈。
- 完全没有 `git` 的话插件管理器无法工作，请先装 git。

## 独立窗口打不开

`dshstudio-gui` 在 Neovide 缺失时会回退到终端，所以"打开的是终端"就是 Neovide 没装。
重新跑安装脚本（不要带 `--no-gui`/`-NoGui`），或自己装 Neovide 并放进 PATH。

**Linux**：Neovide AppImage 需要 FUSE。没有的话用
`--appimage-extract-and-run`，或者改用发行版自带的包。

## `:DshHealth` 显示某个语言服务器 found=false，但确实装了

`lsp.which()` 在一次会话内会缓存查找结果。重启后再看 `:DshHealth`，
或执行 `:lua require('dshstudio.lsp').clear_cache()`。
常见原因是二进制装在 Neovim 继承的 PATH 之外（macOS 从 GUI 启动时尤其常见）——
从有它的 shell 里启动编辑器即可。

## 键位不生效

- 除非你改过，`<leader>` 是空格。
- `<leader>f` 是 `<leader>ff`、`<leader>fg` 等的前缀，所以要等 `timeoutlen`。
  无歧义的格式化用 `<leader>fm`。
- 裸 `gr` 要排在 Neovim 0.11 自带的 `gra`/`grn` 组后面；`<leader>gr` 是立即生效的。

## 干净重装

本发行版通过 `NVIM_APPNAME=dshstudio` 完全隔离，不会碰你原来的 Neovim 配置：

```bash
rm -rf ~/.local/share/dshstudio ~/.config/dshstudio     # Linux/macOS
```

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\DSHStudio"
```

然后重跑安装脚本。无论哪种情况，你自己的 `~/.config/nvim` 都不受影响。
