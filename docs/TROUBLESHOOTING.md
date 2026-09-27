# Troubleshooting

Ordered by how often each problem actually happens. The first command to run for
anything is **`:DshHealth`** — it prints the CLI discovery result, every language
server's status, and which tree-sitter parsers are installed.

If `:DshHealth` itself errors, run `:DshSelfTest`; if that errors too, the
configuration is damaged and reinstalling the `nvim-deepseek-studio` directory is
faster than debugging.

---

## The panel says the agent is missing

`:DshHealth` shows `Harness CLI: NOT FOUND`.

```bash
npm install -g @deepseek-ai/dsh
dsh --version          # confirm it is on PATH
```

If `dsh` is installed somewhere unusual, point the editor at it:

```lua
vim.g.dshstudio = { agent_command = { 'node', '/path/to/dsh/lib/bin.js' } }
```

or set `DSHSTUDIO_DSH_BIN` to the launcher path. Discovery order is: your config,
`DSHSTUDIO_DSH_BIN`, `dsh` on `PATH`, a known npx cache checkout, then `npx -y`.

**On Windows** the CLI is a `.cmd` shim. Discovery handles this by preferring the
real `node` binary when it can find the npx checkout; if you installed `dsh`
globally and it still is not found, add `{ 'cmd', '/c', 'dsh' }` as
`agent_command`.

## A model returns `401 Invalid API Key`

The panel reports this verbatim and appends a hint. The provider for the selected
model is simply not signed in.

- Run `dsh` once in a terminal and complete sign-in, **or**
- Pick a different model with `<leader>dm` (each option is labelled with its
  provider group, so you can see which one you are choosing).

Switching models itself always succeeds — the failure only appears on the next
prompt, because the provider is contacted then. This is upstream behaviour, not a
bug in the panel.

## Answers appear merged into one bubble, or text after reasoning looks wrong

This was a real bug in early builds; it is fixed and covered by
`session: transcript assembly` in `:DshSelfTest`. If you see it again, run that
test — a failure means the state machine regressed.

## The editor hangs when the sidebar or outline refreshes

Also a fixed bug: the outline and context builders used
`vim.lsp.buf_request_sync`, which can park Neovim's main loop indefinitely when a
language server does not answer. Both now use the asynchronous API with a
deadline. If you add code that calls LSP synchronously, do not.

## No subroutine or function list

1. `:DshHealth` — is a language server running for this filetype?
2. If not, that is fine: press `<leader>o`. The outline falls back to the built-in
   offline extractor, which needs no server.
3. If the outline is empty for a file the extractor should understand, check
   `:set filetype?`. The extractor keys off the filetype, so a `.F90` file that
   landed as `fortran77` or `text` will not be parsed.

The offline extractor recognises Fortran `module`, `program`, `subroutine`,
`function`, derived `type`, `interface`, and `module procedure` — including
`recursive`/`pure`/`elemental` prefixes and `contains` nesting. C and C++ yield
functions, `class`/`struct`/`union`/`enum`, `#define` and namespaces. Python yields
`def`, `async def` and `class`, nested by indentation.

## The project report says "0 modules" (or symbols are missing)

Fixed: the extractor used to trust tree-sitter alone when it returned anything, and
on Fortran the grammar can report a nested `type` while missing the enclosing
`module`. Extraction now runs both passes and merges them, and tolerates a
byte-order mark (Windows editors add one by default; a BOM used to hide the first
`module`/`program` line).

If a report looks thin, re-run after `:DshProjectTreeRefresh` and compare with the
outline of the individual files.

## Project analysis fails or hangs

- The static half is offline; if it fails, the message names the step.
- The AI half needs the harness. `:DshPing` checks that in isolation.
- A very large tree is capped (files and per-file bytes); the report notes when
  it truncated.
- The AI digest is written to `<root>/.dshstudio/` and read by the agent with its
  own tools, because the `headless` profile accepts its task only through argv and
  the Windows command line is limited to ~32k characters.

## clangd cannot find headers

clangd needs `compile_commands.json`:

```bash
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

For CMake projects `<leader>lb` already passes that flag. Otherwise set
`extra_include_dirs` in your config and run `<leader>lc` to write a `.clangd`.

## Fortran is coloured or indented wrongly

The form is decided from the extension, then from content for ambiguous `.f`
files. Force it per buffer:

```vim
:let b:fortran_free_source = 1
:let b:fortran_fixed_source = 1
```

Fixed form keeps tabs unexpanded and shifts by 6 columns; free form uses 2. To fall
back to the classic regex syntax file for a filetype, see
[docs/MIGRATING.md](MIGRATING.md) section 4.

## fortls is not found

`pip install fortran-language-server`, or install it through `:Mason` where a
recipe exists. Then `<leader>lf` writes a `.fortls` with your include paths. Until
then, Highlighting and the offline outline still work.

## Plugins did not install

Inside the editor: `:Lazy sync`. Check the log with `:Lazy log`.

- Behind a proxy, set `HTTPS_PROXY`/`HTTP_PROXY` before installing.
- `lazy.nvim` is bootstrapped by cloning on first launch. The bootstrap checks for
  the module entry point rather than the directory, so an interrupted first run
  self-heals on the next start.
- If `git` is missing entirely, the plugin manager cannot work; install git first.

## The desktop window does not open

`dshstudio-gui` falls back to the terminal when Neovide is absent, so a terminal
opening instead is the signal that Neovide is missing. Run the installer without
`--no-gui`/`-NoGui`, or install Neovide yourself and put it on `PATH`.

**Linux:** the Neovide AppImage needs FUSE. Without it, run the AppImage with
`--appimage-extract-and-run`, or use a distribution package.

## `:DshHealth` shows a language server as found=false but it is installed

`lsp.which()` caches lookups for the session. Run `:DshHealth` again after
restarting, or `:lua require('dshstudio.lsp').clear_cache()`. This usually means the
binary is installed outside the `PATH` Neovim inherited (a common macOS GUI case) —
start the editor from a shell that has it.

## Keymaps do not fire

- `<leader>` is `Space` unless you changed it before lazy.nvim loaded.
- `<leader>f` is a prefix of `<leader>ff`, `<leader>fg`, and friends, so it waits
  for `timeoutlen`. Use `<leader>fm` for the unambiguous format map.
- A bare `gr` waits behind Neovim 0.11's own `gra`/`grn` group; `<leader>gr` is
  immediate.

## Reinstalling cleanly

The distribution is isolated through `NVIM_APPNAME=dshstudio`, so it never touches
your normal Neovim configuration:

```bash
rm -rf ~/.local/share/dshstudio ~/.config/dshstudio     # Linux/macOS
```

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\DSHStudio"
```

Then re-run the installer. Your own `~/.config/nvim` is untouched either way.
