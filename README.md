<div align="center">

# VimForge

### DSH Studio

**A Vim editor that is actually an editor — with DeepSeek Harness built in.**

Syntax highlighting, code navigation and symbol trees for Fortran, C, C++ and Python,
plus an AI panel and project-wide analysis, in one installable package.

[![Platforms](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20macOS%20%7C%20Linux%20x86__64-blue)](#supported-platforms)
[![Neovim](https://img.shields.io/badge/neovim-0.11%2B-57A143)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

*Independent project. Built on [Neovim](https://neovim.io); not affiliated with or
endorsed by the Neovim, Vim, Neovide or DeepSeek projects. See [CREDITS.md](CREDITS.md).*

</div>

---

## Documentation

| Document | What it covers |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | **Windows / macOS / Linux**: installers, manual install, per-platform dependencies, verification, uninstall |
| [docs/ACP.md](docs/ACP.md) | The verified ACP wire contract used to talk to DeepSeek Harness |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Measured costs, the idle-loop and parser-probe fixes, and where the remaining time goes |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Every failure mode we have hit, and its fix |
| [docs/DEVELOPING.md](docs/DEVELOPING.md) | Architecture, load order, concurrency rules, testing |
| [docs/MIGRATING.md](docs/MIGRATING.md) | Porting your own vimrc/keymaps here |
| [CREDITS.md](CREDITS.md) | Dependencies, licences, trademark notes |
| [README.zh.md](README.zh.md) | 中文说明 · [中文安装](docs/INSTALL.zh.md) · [中文排障](docs/TROUBLESHOOTING.zh.md) |

---

## Why this exists

Notepad cannot jump to a definition, cannot show a subroutine list, and cannot
explain a codebase. Vim can, but wiring up highlighting, language servers, symbol
outlines and an AI assistant by hand is a weekend of yak-shaving and breaks the
moment a plugin updates.

DSH Studio is that wiring, finished and pinned. It is a **Neovim distribution**:
real Vim keybindings, real tree-sitter highlighting, real language servers — driven
by a launcher that installs what it needs and leaves your existing Neovim setup
completely alone.

Nothing is reimplemented from scratch. The editor *is* Neovim; the desktop window
*is* Neovide; navigation *is* clangd, pyright and fortls. What this project adds is
the assembly, the Fortran/C/C++ specifics those tools get wrong out of the box, and
the DeepSeek Harness integration.

## Features

### Editing and navigation (the Vim part you wanted to keep)

| Capability | How |
|---|---|
| Vim modal editing | Neovim, `<leader>` is `Space` |
| Tree-sitter highlighting | C, C++, Fortran, Python, Lua, CMake, Markdown, JSON, YAML, Bash |
| Go to definition / declaration / implementation | clangd, pyright, fortls via LSP |
| Find references, rename symbol, code actions | LSP |
| Hover docs, signature help, diagnostics | LSP |
| Fuzzy file / text / symbol search | Telescope |
| File tree, git signs, autopairs, commenting | nvim-tree, gitsigns, nvim-autopairs, Comment.nvim |
| Completion | blink.cmp (LSP + snippets + path + buffer) |

### Subroutine and function lists

`<leader>o` opens a **symbol outline** in a left split: modules, derived types,
subroutines, functions, interfaces and methods, nested, with line numbers. Click or
press `Enter` to jump; `p` fuzzy-picks; `r` refreshes.

It reads LSP document symbols first, and falls back to a built-in offline extractor
(see [Offline symbol extraction](#offline-symbol-extraction)) so the outline still
works on a Fortran project with no language server running.

`<leader>fs` searches symbols in the current file, `<leader>fw` across the workspace,
and `:DshProjectSymbols` builds a project-wide symbol index offline.

### Project symbol tree

`<leader>ot` opens the **project tree**: directories, then files, then the symbols
each file declares — the whole codebase as one collapsible tree. It is what a mixed
Fortran/C project needs, because a subroutine's home file is rarely obvious.

- Indexes on demand in chunks, so a large tree never freezes the UI
- Cached per project root; `r` re-indexes, `<leader>op` fuzzy-picks across the index
- Built from the offline extractor, so no language server is required
- `Enter` jumps to a symbol, folds a directory, or opens a file

### Program tree for a file or folder

`:DshTree [path]` answers "what is in here, and what calls what" for **one target**
rather than the whole project:

| Command | Target |
|---|---|
| `:DshTree [path]` | the given file or folder (defaults to the current file's folder) |
| `:DshTree! [path]` | the same, opening straight in the symbol view |
| `:DshTreeFile` | the file in the current buffer |
| `:DshTreeFolder` | the current file's project folder |
| `:DshTreePick` | asks for a path first |

Two views, `Tab` switches between them. The **call view** nests the entry points it
finds and expands each symbol into the symbols that symbol calls, so a program can be
followed from `main` downwards. The **symbol view** is the declaration tree (modules,
types, interfaces, subroutines and functions) for the same target. `Enter` expands a
node or jumps to the definition, `r` refreshes, `q` closes.

It is offline, using the same extractor as the outline, so no language server has to
be running. Call attribution is per line, so a symbol is credited with the calls in
its own body rather than those of a procedure nested inside it.

### DeepSeek Harness panel

`<leader>dd` opens a right-hand panel with a streaming transcript and an input
buffer. It speaks the **Agent Client Protocol (ACP)** directly over stdio to
`dsh --profile acp` — the same protocol other editors use — rather than scraping a
terminal.

- Streaming answers, visible reasoning, and live tool-call status
- **Context is injected automatically**: the active file (or your visual selection)
  with line numbers, the enclosing symbol, the declaration outline, current
  diagnostics, project markers, and git branch
- Model switching (`<leader>dm`) and reasoning effort (`<leader>de`) without
  restarting the session
- Permission prompts for tool use, with `auto_approve` modes
- `<leader>di` inserts the last reply into the file; `<leader>dy` copies it
- Session history: `:DshSessions` lists and resumes persisted conversations
- `<leader>dq` cancels a running turn

### Models and API keys

You choose the model, and you supply the key. There is no editor-private key store
to hunt for later: everything lives where the harness keeps it.

**Choosing a model.** `<leader>dm` lists every model the harness advertises, grouped
by provider. Options from a provider with no usable key are marked `⚠ no key` so a
failure is predictable rather than surprising, and picking one offers to set the key
straight away.

**Setting an API key.** `:DshAuth` writes it into the harness credential store
(`$DSH_HOME/.credentials.yaml`, its `refs:` section) — the same place the harness'
own tooling writes, so the key is visible to every harness surface, not just this
editor. A timestamped backup is taken before the first change in a session, comment
lines are preserved, and the store reloads on change, so the key applies to the next
request without a restart. `:DshProviders` shows the status table.

Key precedence is the harness': **launch environment → stored file → project `.env`
→ harness-home `.env`**. An exported variable therefore still wins over anything
saved here, which is what you want in CI.

```
:DshAuth              manage keys (interactive)
:DshProviders         provider and key status
:DshModel             choose the model
:DshEffort            choose the reasoning effort
```

**Adding another provider.** The shipped composition routes DeepSeek and Xiaomi. To
add any OpenAI-compatible gateway or another pi-ai provider, declare a route in
`$DSH_HOME/settings.yaml` with a credential reference, then set the key — the
editor's provider list picks the route up automatically, even before the agent
advertises it:

```yaml
llm-pi-ai:
  providers:
    acme-gateway:
      displayName: Acme Gateway
      apiKeyEnv: ACME_GATEWAY_API_KEY      # the name :DshAuth will write
      baseURL: https://gateway.example.com/v1
      api: openai-completions
agent-default-model:
  provider: deepseek-official
  model: deepseek-flash
```

If you prefer the harness' own UI for sign-in flows (OAuth, interactive keys), run
`dsh` in a terminal once; credentials saved there are picked up here unchanged.

> **A note on secret handling.** The harness runs agent tool processes as the same
> OS user, so an API key the agent can use is one the agent can read — file
> permissions cannot separate the two. Do not store a key with a wider scope than
> you would hand to the agent itself.

### Project analysis ("deepwiki" mode)

`<leader>dp` opens the analysis menu; `:DshAnalyze!` runs it directly.

Two layers, so you get an answer even with no network:

1. **Static analysis (offline, instant).** Scans the tree, extracts symbols, parses
   `USE`/`#include`/`import` edges, builds a call graph, and finds entry points and
   the largest files.
2. **AI architecture notes (optional).** Sends a compact digest of that static
   result through `dsh --profile headless` and appends a written architecture
   review.

The result is a Markdown report at `<project>/.dshstudio/analysis-<timestamp>.md`,
opened in a tab: project overview, directory tree, modules and types, subroutine and
function tables, dependency analysis, call-graph highlights, entry points, largest
files, and the AI notes.

## Supported platforms

Three platforms, three architectures. Full detail in [docs/INSTALL.md](docs/INSTALL.md).

| | Windows 10/11 **x64** | **macOS** 11+ (Intel & Apple Silicon) | **Linux x86_64** |
|---|---|---|---|
| Terminal editor | `dshstudio` | `dshstudio` | `dshstudio` |
| Desktop window | `dshstudio-gui` (Neovide) + desktop shortcut | `dshstudio-gui` + `DSH Studio.app` | `dshstudio-gui` + `.desktop` entry, optional AppImage |
| Neovim build used | `nvim-win64.zip` | `nvim-macos-arm64` / `nvim-macos-x86_64` | `nvim-linux-x86_64` |
| Installer | `install-windows.ps1` (PowerShell 5.1+) | `install-unix.sh` (bash) | `install-unix.sh` (bash) |
| File association | "Open with DSH Studio" | document types in the app bundle | `MimeType=` desktop entry |
| Extra requirement | Windows Terminal recommended | Nerd Font for icon glyphs | FUSE for the Neovide AppImage |

Windows ARM64 runs the x64 build under emulation. Linux on ARM has no official
upstream Neovim tarball — set `DSHSTUDIO_USE_SYSTEM_NVIM=1` and use your
distribution's Neovim 0.11+.

Each platform's language servers, compilers and package-manager commands differ;
the matrix is in [docs/INSTALL.md](docs/INSTALL.md) (see "Dependencies per platform").

## Requirements

- **Neovim 0.11+** (installed by the installer; needed for the built-in
  `vim.lsp.config` API)
- **Node.js 18+**, to run the DeepSeek Harness CLI: `npm i -g @deepseek-ai/dsh`
- **git**, used by the plugin manager (and by the git status features)
- Optional, for language intelligence: `clangd`, `pyright`, `fortls`
  (the first two install through `:Mason`; see [Language servers](#language-servers))
- Optional, for building: `gcc`/`g++`/`gfortran`, `cmake`, `make`

## Install

### Download a ready-made bundle (recommended: nothing else to install)

Every release ships a **self-contained archive per platform**. Each one already
contains the configuration *and* the official Neovim build, so extracting it is
enough to start editing — no Neovim install, no package manager, no network.

| Platform | Download | Then |
|---|---|---|
| **Windows 10/11 x64** | [`VimForge-0.1.0-windows-x64.zip`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-windows-x64.zip) | extract it, then run **`install.cmd`** |
| **macOS 11+** (Intel **and** Apple Silicon) | [`VimForge-0.1.0-macos-universal.tar.gz`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-macos-universal.tar.gz) | `tar xzf … && cd VimForge-* && ./install.sh` |
| **Linux x86_64** | [`VimForge-0.1.0-linux-x86_64.tar.gz`](https://github.com/nickedfrc/VimForge/releases/latest/download/VimForge-0.1.0-linux-x86_64.tar.gz) | `tar xzf … && cd VimForge-* && ./install.sh` |

All releases and checksums: **[github.com/nickedfrc/VimForge/releases](https://github.com/nickedfrc/VimForge/releases)**.
Verify a download against `SHA256SUMS.txt` before running it.

The macOS bundle carries **both** Neovim builds and the launcher picks the right
one, so a single download covers Intel and Apple Silicon.

Only the AI features need anything extra — Node.js 18+ and the harness CLI:

```bash
npm install -g @deepseek-ai/dsh
```

Then `:DshAuth` sets your API key and `<leader>dm` picks the model.

### Or use the installers (clone the repository, they fetch Neovim)

```bash
git clone https://github.com/nickedfrc/VimForge.git
cd VimForge
```

**Windows (x64)** — installs into `%LOCALAPPDATA%\DSHStudio`, adds `dshstudio` to
your user `PATH`, registers "Open with DSH Studio" for source files, and creates a
desktop shortcut for the GUI.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

**macOS and Linux** — installs into `~/.local/share/dshstudio`, creates
`dshstudio` and `dshstudio-gui`, plus a `DSH Studio.app` bundle on macOS and a
`.desktop` entry on Linux.

```bash
./scripts/install-unix.sh
```

Options: Windows `-NoGui`, `-NoPlugins`, `-Prefix <dir>`; Unix `--no-gui`,
`--no-plugins`, `--prefix DIR`, `--appimage`. Both finish by running the offline
self-test and reporting whether the configuration loads.

Both routes are described in full, with the per-platform dependency matrix, in
[docs/INSTALL.md](docs/INSTALL.md).

### Manual install (any platform)

If you already have Neovim 0.11+ and prefer to do it yourself, give this
configuration its own application name so your existing setup is untouched:

```bash
export NVIM_APPNAME=dshstudio
mkdir -p ~/.config/dshstudio
cp -R nvim-deepseek-studio/. ~/.config/dshstudio/
nvim --headless "+Lazy! sync" +qa
nvim
```

On Windows the config directory is `%LOCALAPPDATA%\dshstudio`.

### Building the bundles yourself

```bash
node scripts/build_release_bundles.mjs dist   # stage: config + official Neovim
node scripts/make_archives.mjs dist           # zip / tar.gz + SHA256SUMS.txt
node scripts/verify_archives.mjs dist         # required paths, modes, checksums
```

The archive writers use only Node built-ins, so no `tar` or `zip` is required, and
`verify_archives.mjs` checks each archive the way a user would see it.

## First run

```bash
dshstudio                       # terminal editor
dshstudio-gui mycode.f90        # desktop window
```

Then, inside the editor:

| Keys | Action |
|---|---|
| `<leader>dd` | Toggle the DeepSeek panel |
| `<leader>da` | Ask about the current selection |
| `<leader>dp` | Project analysis menu |
| `<leader>o` | Toggle the symbol outline |
| `:DshTree` | Program tree (call hierarchy and symbols) for a file or folder |
| `<leader>dm` | Choose the model |
| `:DshHealth` | Show language servers, parsers, and CLI discovery |
| `:DshSelfTest` | Run the offline protocol self-tests |
| `:DshPing` | End-to-end check that the harness answers |

The single most useful command when something looks wrong is **`:DshHealth`**. It
prints exactly which language servers were found, which tree-sitter parsers are
installed, and how the harness CLI was located.

## Language servers

| Language | Server | Install |
|---|---|---|
| C / C++ | `clangd` | `:Mason` (auto) or LLVM release |
| Python | `pyright` | `:Mason` (auto) or `npm i -g pyright` |
| Lua | `lua_ls` | `:Mason` (auto) |
| Fortran | `fortls` | `pip install fortran-language-server`, or `:Mason` where available |

If a server is missing the editor still opens files, with highlighting and the
offline outline. `:DshHealth` names the missing binary and the install command for
your OS.

### C and C++

clangd needs to know your include paths. It reads `compile_commands.json`
automatically; for CMake projects configure with
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` (the `<leader>lb` build command does this).
Otherwise `<leader>lc` writes a `.clangd` file from `extra_include_dirs` in your
config.

### Fortran

Fortran is where off-the-shelf setups usually fall apart, so this distribution
handles it explicitly:

- **Free vs fixed form detection.** The declaration and analysis rules live in one
  place (`dshstudio.project.sniff`), so the editor never highlights a file
  differently from the way the analysis reads it. Fixed-form files keep tabs
  unexpanded and shift by 6 to respect the column rules; free-form uses 2-space
  indents. The filetype is corrected on read, which fixes `.F90`/`.f` detection
  races.
- **Legacy source names.** A GAMESS-style deck is `foo.src`, an include is
  `bar.inc` — names that state no language at all, and that Neovim leaves with an
  empty filetype. Those are classified from their first lines instead, so they get
  highlighting, indentation, the language server and the parser, and the project
  analysis no longer skips them. See [Legacy and fixed-form sources](#legacy-and-fixed-form-sources).
- **`<leader>lf`** writes a `.fortls` file with your include paths.
- **Offline symbol extraction** recognises `subroutine`, `function`, `program`,
  `module`, derived `type`, and `interface` declarations — including `recursive`,
  `pure`, and `elemental` prefixes, `module procedure`, and multiline signatures —
  and tracks `contains` nesting so nested routines are attributed to their module.
  This gives you the subroutine list even without fortls.

## Legacy and fixed-form sources

Fortran 77 puts meaning in the columns: `C`, `c`, `*` or `!` in column 1 comments
out the whole line, column 6 holds the continuation marker, and a statement
begins at column 7. A reader that assumes free form gets this wrong silently — it
does not fail, it reports the wrong thing. On a 7785-line GAMESS-style deck, a
free-form reading turned twenty `CALL` statements written inside comment lines
into twenty calls that do not exist.

The rules are implemented once, in `lua/dshstudio/project/sniff.lua`, and used by
all three consumers:

| Consumer | What it decides |
|---|---|
| `lang.lua` | the buffer's filetype and Fortran source form |
| `project/symbols.lua` | which lines hold declarations |
| `project/static.lua` | which lines hold `use`, `call` and `include` |

**Source form.** A `.f90`/`.f95`/`.f03`/`.f08` extension is free form by
definition. Everything else is decided from content, using the column-7 rule as
an exact discriminator: in fixed form every statement must start at column 7, so
the same keyword at any other indentation proves free form. That is also what
stops `contains` and `character` from being read as `C`-in-column-1 comments.

**File names that state no language.** `.src`, `.inc` and `.ins` are shared by
Fortran, C and C++ projects. They are classified by content, and only when the
evidence is unambiguous — a file that could be anything is left alone rather than
guessed at. A `.src` deck opens as Fortran with the correct column rules; a `.inc`
C header opens as C. Detection is deliberately conservative, because the
Fortran-ish signals are everywhere: `end` closes a block in Lua, `function` is a
Lua keyword, `*` opens a Markdown bullet, and `class` belongs to C++ and Python
alike.

Tree-sitter is skipped for fixed-form Fortran on purpose. The grammar describes
free form, so on a fixed-form deck its output does not merely miss declarations,
it describes different text; merging that in would invent symbols. The regex
extractor knows both forms and does the work.

## Offline symbol extraction

The outline and static analysis never require a language server or the network.
A hand-written extractor handles Fortran (case-insensitive, free and fixed form),
C/C++ (return types, qualifiers, K&R-style braces, `class`/`struct`/`enum`/`union`,
`#define`, namespaces) and Python (indentation-derived nesting for `def`, `async
def`, `class`). Tree-sitter is used when a parser is present, but the regex path is
the reliable baseline and is what the tests exercise — and for fixed-form Fortran
it is the only correct one.

Files named `.src`, `.inc` or `.ins` are classified from their content before they
reach the extractor, so legacy decks are analysed like any other source file.

## Configuration

Settings are merged in this order: built-in defaults, then `vim.g.dshstudio`, then
`DSHSTUDIO_*` environment variables.

```lua
-- in your own module, before or after setup
vim.g.dshstudio = {
  sidebar_width = 50,
  auto_context = true,          -- inject the current file into every prompt
  context_max_bytes = 24000,
  auto_approve = 'ask',         -- 'ask' | 'always' | 'never'
  model = '["deepseek-official","deepseek-v4-pro"]',
  reasoning_effort = 'high',
  agent_command = { 'dsh' },    -- override CLI discovery
  fortran_include_dirs = { 'include', 'build/mod' },
  extra_include_dirs = { 'include', 'third_party' },
  analysis_output_dir = '.dshstudio',
  keymaps = true,
}
```

Useful environment variables:

| Variable | Purpose |
|---|---|
| `NVIM_APPNAME=dshstudio` | Keep this config isolated from your normal Neovim |
| `DSHSTUDIO_DSH_BIN` | Absolute path to the harness launcher |
| `DSHSTUDIO_AGENT_COMMAND` | Override the agent argv |
| `DSHSTUDIO_ROOT` | Distribution root (set by the launchers) |

## How the DeepSeek integration works

Two harness profiles, used for different jobs. Both were verified against the real
CLI while building this, and the wire contract is documented in
[`docs/ACP.md`](docs/ACP.md).

**Interactive — `dsh --profile acp`.** ACP is JSON-RPC 2.0, newline-delimited, one
object per line, stdout strictly protocol-only. The panel implements the client:

```
---> initialize            { protocolVersion: 1, clientCapabilities, clientInfo }
<--- { agentInfo, agentCapabilities, authMethods }

---> session/new           { cwd, mcpServers: [] }
<--- { sessionId, configOptions: [ model, reasoning_effort ] }

---> session/prompt        { sessionId, prompt: [ { type: "text", text } ] }
<--- session/update        agent_message_chunk / agent_thought_chunk
                           tool_call / tool_call_update / usage_update
<--> session/request_permission   (client answers allow-once / reject-once)
<--- { stopReason: "end_turn" }
```

Model switching uses `session/set_config_option`, where the `model` value is a
**JSON-encoded string** such as `["deepseek-official","deepseek-v4-pro"]` — passing
a raw array is rejected by the agent. Reasoning effort takes a plain string
(`off`/`low`/`high`/`max`).

**Batch — `dsh --profile headless "<task>"`.** Runs one task, prints the final
answer to stdout, exits. Used by the AI analysis. The task must be an **argv
argument**: an empty argv with piped stdin exits 1 with
`error: a task is required`. Because argv is the only channel, digests are
size-capped to stay under the Windows command-line limit.

Design consequences worth knowing:

- The panel holds no conversation state of its own; closing it never loses a session.
- The statusline shows connection state, model, token usage and a working indicator.
- If the agent exits, outstanding requests are failed immediately rather than
  hanging, and the stderr tail is surfaced — which is how a `401 Invalid API Key`
  becomes a readable message instead of a silent stall.
- A model provider that is not signed in produces a clear hint pointing at the
  model picker, rather than a bare error.

## Testing

```bash
# Offline protocol and context tests — no network, no agent process
nvim --headless --cmd "set rtp+=./nvim-deepseek-studio" \
     -c "lua require('dshstudio.tests.probe').main()"

# Syntax check every Lua file (no Lua toolchain required)
node tests/lua_syntax_check.js ./nvim-deepseek-studio

# Inside the editor
:DshSelfTest
```

The protocol tests drive the ACP client against a **scripted fake transport**, so
framing, id correlation, split chunks, CRLF, error responses, permission callbacks,
cancellation and exit handling are all covered without spawning anything. That is
deliberate: it means the tests run in CI and in restricted environments.

## Project layout

```
nvim-deepseek-studio/
  init.lua                     entry: options, lazy.nvim bootstrap, module setup
  plugin/dshstudio.lua         user commands, registered defensively
  lua/dshstudio/
    config.lua                 defaults, env/global merging
    editor.lua keymaps.lua     options and keymaps
    lsp.lua lang.lua           language servers; Fortran/C/C++/Python specifics
    treesitter.lua             highlighting-agnostic parser management
    plugins.lua                plugin specs
    core/
      acp.lua                  ACP client: framing, correlation, callbacks
      session.lua              conversation state, streaming, model switching
      context.lua              what gets injected into a prompt
      headless.lua             one-shot harness tasks (project analysis)
    project/
      scan.lua                 tree walk, language stats
      sniff.lua                language and Fortran source form from content
      symbols.lua              offline symbol extraction (Fortran/C/C++/Python)
      static.lua               USE / #include / import and call graphs
      report.lua               Markdown report builder
      analysis.lua             orchestration and the report browser
    ui/
      sidebar.lua              the DeepSeek panel
      outline.lua              subroutine/function tree
      calltree.lua             program tree (call hierarchy and symbols)
      project_tree.lua         whole-project symbol tree
    tests/probe.lua            offline self-tests
scripts/                       installers (Windows PowerShell, Unix bash)
docs/ACP.md                    the verified ACP wire contract
```

## Troubleshooting

**The panel says the agent was not found.** `npm i -g @deepseek-ai/dsh`, then
`:DshHealth` to see the discovery result. You can force a path with
`DSHSTUDIO_DSH_BIN`.

**A model returns `401 Invalid API Key`.** That provider is not signed in. Run
`dsh` once in a terminal to authenticate, or pick a different model with
`<leader>dm`.

**No subroutine list.** Check `:DshHealth` for a running language server, or just
open the outline (the offline extractor does not need one). On a huge generated
file the offline scan may need a moment.

**clangd finds no headers.** Configure with
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`, or set `extra_include_dirs` and run
`<leader>lc`.

**Fixed-form Fortran is coloured wrongly.** The form is decided from the extension
and then from content, and the syntax file is reloaded when its own guess differs.
Set it explicitly with `:let b:fortran_free_source = 1` or
`b:fortran_fixed_source = 1`.

**A `.src` or `.inc` file opens with no highlighting.** It is classified from its
content, so an ambiguous file is left alone rather than guessed at. Check the
filetype with `:set filetype?`; if it is empty, the first lines did not identify
the language — set it once with `:setf fortran` (or `c`), or add a `modeline`.

**Plugins did not install.** Run `:Lazy sync` inside the editor. Behind a proxy,
set `HTTPS_PROXY` before installing.

## Contributing

Issues and pull requests are welcome. Two ground rules keep this distribution
trustworthy:

1. **Never let a missing piece break startup.** Optional features are `pcall`-guarded;
   a missing language server degrades to highlighting plus the offline outline.
2. **Do not break the offline path.** Highlighting, navigation fallbacks, symbol
   extraction and the self-tests must work with no network and no agent.

Run `node tests/lua_syntax_check.js ./nvim-deepseek-studio` and `:DshSelfTest`
before opening a pull request.

## License

MIT — see [LICENSE](LICENSE).

Neovim, Neovide and every plugin listed here are separate projects under their own
licenses; this repository contains configuration and integration code only.
