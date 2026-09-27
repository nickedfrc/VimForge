# Design, development and testing

This document explains how the distribution is put together, why the pieces are
split the way they are, and how to change it without breaking the properties that
make it dependable. It is aimed at someone modifying the project, not at someone
installing it.

---

## 1. The one rule that shapes everything

**A missing optional piece must never break the editor.**

That single constraint explains most of the code's shape:

- Every cross-module call is wrapped in `pcall`. A module may be absent, fail to
  load, or be mid-edit, and keymaps still work.
- `init.lua` loads first-party modules through a helper that reports a failure
  instead of propagating it.
- The plugin manager is optional: if `lazy.nvim` cannot be bootstrapped, the user
  gets a working editor with highlighting, the offline outline, and the DeepSeek
  panel, minus third-party niceties.
- No first-party module `require`s a plugin at file scope. Plugins are contacted
  lazily inside functions, behind `pcall`.

The consequence is that there are two tiers of functionality:

| Tier | Depends on | Degrades to |
|---|---|---|
| Core | Neovim + this repo | — |
| Enhanced | plugins, language servers, tree-sitter parsers, DeepSeek Harness | Core |

Almost every support question is "which tier am I in?", which is why `:DshHealth`
exists.

## 2. Load order

```
init.lua
  ├─ options read by lazy.nvim (mapleader)
  ├─ lazy.nvim bootstrap (clone if the module entry point is missing)
  ├─ lazy.setup(specs)                     -- plugins load on demand
  ├─ dshstudio.config.setup()
  ├─ dshstudio.editor.setup()              -- options, autocmds
  ├─ dshstudio.treesitter.setup()          -- parser management
  ├─ dshstudio.lsp.setup()                 -- servers whose binary exists
  ├─ dshstudio.lang.setup()                -- per-language FileType rules
  ├─ dshstudio.keymaps.setup()
  └─ dshstudio.user (optional, wins over all of the above)

plugin/dshstudio.lua                       -- user commands, registered defensively
```

Two properties matter here:

- **`lang.lua` runs after `editor.lua` on purpose.** `editor.lua` sets per-filetype
  baselines (Fortran 2, C/C++ 4, Python 4); `lang.lua` then refines Fortran to 6
  for fixed-form files. Reversing the order silently breaks fixed-form indentation.
- **`user.lua` is last.** It is the supported place for personal changes and it is
  git-ignored, so upgrades never conflict.

## 3. Module map

```
core/acp.lua        ACP client: framing, request correlation, callbacks, cancel
core/session.lua    conversation state machine, streaming, model switching
core/context.lua    what gets injected into a prompt
core/headless.lua   one-shot `dsh --profile headless` jobs
ui/sidebar.lua      the panel (transcript + input buffer)
ui/outline.lua      per-file symbol tree
ui/project_tree.lua project-wide symbol tree (directory -> file -> symbols)
project/scan.lua    tree walk, language stats
project/symbols.lua offline symbol extraction + tree-sitter merge
project/static.lua  USE / #include / import parsing, call graph, structure
project/report.lua  Markdown report builder
project/analysis.lua orchestration, caching, report opening
lsp.lua             server configuration and availability detection
lang.lua            per-language conventions, build/run, Fortran form detection
tests/probe.lua     offline self-tests
```

### Why `core/acp.lua` has an injectable transport

The protocol state machine is the part most likely to break and the hardest to
test, because tests normally need a real agent process and piped stdio. `acp.new`
accepts a `transport` with `spawn`/`write`/`kill`, so the tests script frames
directly into the client and assert on what it writes. That is what makes
`acp: newline framing and id correlation` and the other protocol tests runnable in
CI with no network.

**Do not remove that seam.** If you refactor, keep the ability to drive the client
from a fake peer.

### Why there are two UI panels

- `outline.lua` answers "what is in this file" and refreshes on buffer/window events.
- `project_tree.lua` answers "what is in this project" and owns a cached,
  chunked index.

Both read the same extractor. Keeping them separate avoids one panel paying for
the other's indexing, and lets the project tree use a fold-based layout while the
outline stays flat and cheap to refresh.

### Why extraction runs two passes

`symbols.extract_file` runs the regex extractor **and** tree-sitter, then merges.
This is not paranoia: tree-sitter was observed returning a nested `type` while
missing the enclosing `module` on Fortran, and because the old code treated any
tree-sitter result as authoritative, the whole module disappeared from the outline
and the project report.

Rules for the merge:

- The regex pass is the baseline that always runs; it must keep working with no
  parser installed.
- tree-sitter results win collisions (more accurate ranges).
- Deduplication is by `name@line@kind`, then loosely by `name@kind`, so a slightly
  different line from each pass does not produce two entries.

Two further details are load-bearing:

- **BOM stripping.** Windows editors write a UTF-8 BOM by default, and a leading
  BOM makes `^module`/`^program` fail on the first line. This was a real bug: the
  first declaration of every file was invisible.
- **No tree-sitter calls from a libuv fast-event context.** `try_treesitter`
  returns `nil` when `vim.in_fast_event()` is true, because touching the parser
  there raises. The chunked scanners therefore dispatch their work through
  `vim.schedule`.

## 4. Concurrency rules

Indexing a large tree must not block the UI, and must not corrupt state:

- Both scanners batch work (40 files per batch in `project/`, 12 in the project
  tree) driven by a one-shot `vim.uv` timer, with the batch body running on the
  main loop via `vim.schedule`.
- Callbacks that touch the UI run through `vim.schedule`.
- The sidebar throttles transcript re-rendering; streaming chunks arrive far
  faster than a redraw is useful, and repainting on every chunk also steals the
  cursor from the input buffer.
- One-shot jobs have timeouts and a cancel path. The agent imposes no approval
  deadline, so the client must.

**Do not add a synchronous LSP call.** `vim.lsp.buf_request_sync` parked the main
loop forever on Neovim 0.12 when a server did not answer, which froze the editor
on every outline refresh. Use `vim.lsp.buf_request_all` plus a `vim.wait`
deadline, as `context.lua` and `outline.lua` now do.

## 5. Testing

Three layers, all runnable offline.

```bash
# 1. Lua syntax, self-contained (no toolchain, no network)
node tests/lua_syntax_check.js ./nvim-deepseek-studio

# 2. Real Lua 5.1 grammar (independent second opinion; needs luaparse)
npm install --no-save luaparse
node tests/lua_parse_check.js ./nvim-deepseek-studio

# 3. Module reference resolution
node tests/check_requires.js ./nvim-deepseek-studio

# 4. The behavioural tests, inside Neovim
nvim --headless --cmd "set rtp+=$PWD/nvim-deepseek-studio" \
     -c "lua require('dshstudio.tests.probe').main()"
```

Inside the editor: `:DshSelfTest`, or one case at a time with
`:lua require('dshstudio.tests.probe').run_one('acp: cancel is a notification')`.

### Continuous integration

The workflow that runs all of the above on Linux, macOS and Windows is kept at
[`docs/ci.yml`](ci.yml) rather than in `.github/workflows/`, because a personal
access token without the `workflow` scope cannot create files in that directory.
To enable CI, copy it into place:

```bash
mkdir -p .github/workflows && cp docs/ci.yml .github/workflows/ci.yml
```

It runs three jobs: the self-contained syntax check plus the Lua 5.1 grammar parse
and module-reference check, the behavioural suite on all three platforms against a
downloaded Neovim, and a "configuration loads without plugins" regression test —
which is the guard for this project's central rule that a missing optional piece
must never break startup.

### Why both a custom checker and luaparse

They catch different things, and each has caught a real defect:

| Checker | Catches | Missed |
|---|---|---|
| `lua_syntax_check.js` | unbalanced `end`/`do`/`then`, unterminated strings, reserved words used as bare table keys | some expression-level errors |
| `lua_parse_check.js` | everything the Lua 5.1 grammar rejects | needs a dependency |

The custom checker exists because the project must be checkable with nothing but
Node installed. It is explicitly **not** a parser and must not be trusted as one.

### What to add a test for

Any bug you fix. The existing suite is organised as "one case per way the
integration can break", and the two most valuable cases came directly from real
failures found by running against Neovim:

- `headless: system output normalisation` — `vim.system` returns a string with
  `text = true`, not a list; assuming a list crashed on every successful call.
- `symbols: BOM tolerance and module nesting` — a BOM hid the first declaration.

## 6. Coding conventions

- Lua 5.1 / LuaJIT only. No `goto`, no integer division, no `//`.
- `local uv = vim.uv or vim.loop` for compatibility with older builds.
- Require siblings lazily, inside functions.
- Every public function documents its parameters with `---@param` and its return
  with `---@return`.
- Comments explain **why**. The code already says what.
- Never write to a user's file outside the project root without a prompt.
- Keep user-visible strings in English in the source; the Chinese documentation is
  separate rather than duplicating strings in code.

## 7. Adding a language

1. Add the extension mapping and language name in `project/scan.lua`.
2. Add an extraction branch in `project/symbols.lua`:
   - a regex matcher set (required — this is the offline baseline),
   - optionally a tree-sitter candidate list in `TS_CANDIDATES`.
3. Add per-filetype indent/comment rules in `lang.lua`.
4. Add a server entry in `lsp.lua` with its root markers and binary.
5. Add the parser to `treesitter_ensure` in `config.lua`.
6. Extend `tests/probe.lua` with an extraction case for the new language.

## 8. Changing the DeepSeek integration

Read [ACP.md](ACP.md) first; it is the verified wire contract, including the parts
that are easy to get wrong (the `model` value is a JSON-encoded *string*; a changed
`configOptionUpdate` replaces the whole option set; permission answers use the
doubled `outcome` key; `stopReason` alone cannot detect cancellation).

If you change the bridge:

1. Re-run `:DshPing` against a real harness.
2. Re-run `:DshSelfTest` for the framing and state machine.
3. Update `docs/ACP.md` in the same commit.

## 9. Release checklist

- [ ] `node tests/lua_syntax_check.js` clean
- [ ] `node tests/lua_parse_check.js` clean
- [ ] `node tests/check_requires.js` clean
- [ ] `:DshSelfTest` all green on Neovim 0.11 *and* the current stable
- [ ] `:DshHealth` renders without error on a machine with no language servers
- [ ] Installer runs on a clean Windows/macOS/Linux account
- [ ] No token, credential, or personal path committed (`git diff --cached`)
- [ ] `docs/ACP.md` matches the code
