# Migrating from your own Vim or Neovim setup

This distribution is Neovim with a fixed plugin set. Your own configuration is not
thrown away: almost everything in a normal `vimrc`/`init.lua` transfers, and the
plugin features you rely on for highlighting and jumping are either already present
or can be added back in one place.

Keep personal changes in **`lua/dshstudio/user.lua`** (copy
`lua/dshstudio/user.example.lua`). That file loads last, survives every upgrade,
and means you never edit upstream files.

---

## 1. What you already get

You very likely had these configured by hand. They are preconfigured here, so
delete the corresponding block from your old config rather than copying it over.

| Your old setup | Already here |
|---|---|
| `nvim-treesitter` + `ensure_installed` | Wired for Fortran, C, C++, Python, Lua, CMake, Markdown, JSON, YAML, Bash |
| `nvim-lspconfig` + `lspconfig.clangd.setup{}` | clangd, pyright, fortls, lua_ls with root detection and install hints |
| `nvim-cmp` / `cmp-nvim-lsp` | blink.cmp with LSP, snippets, path and buffer sources |
| `telescope.nvim` + keymaps | `<leader>ff/fg/fb/fs/fw/fd/fr/fh` |
| `nvim-tree` or `nerdtree` | `<leader>e` |
| `gitsigns.nvim` | Loaded on read |
| `lualine` / `vim-airline` | Statusline with LSP diagnostics and DSH session state |
| `nvim-autopairs`, `Comment.nvim` | Loaded on insert / read |
| `render-markdown` | For the analysis reports |

## 2. Keymap translation

`vim.keymap.set` accepts the same notation you already used, so most maps are a
mechanical rewrite.

| vimrc | Neovim |
|---|---|
| `nnoremap <leader>x :cmd<CR>` | `vim.keymap.set('n', '<leader>x', '<cmd>cmd<cr>')` |
| `inoremap jj <Esc>` | `vim.keymap.set('i', 'jj', '<Esc>')` |
| `vnoremap < <gv` | `vim.keymap.set('v', '<', '<gv')` |
| `map <F5> :make<CR>` | `vim.keymap.set('', '<F5>', '<cmd>make<cr>')` |
| `autocmd FileType python setlocal ...` | `vim.api.nvim_create_autocmd('FileType', { pattern='python', callback=... })` |
| `let g:foo = 1` | `vim.g.foo = 1` |
| `set number` | `vim.opt.number = true` |
| `setlocal shiftwidth=2` | `vim.bo.shiftwidth = 2` (buffer) / `vim.wo` (window) |
| `let mapleader=","` | `vim.g.mapleader = ','` — put this **before** lazy.nvim loads |

Leader-key note: the distribution uses `<Space>`. Changing `mapleader` to `,` is
supported but must happen in `user.lua`'s very first line if you also want lazy.nvim
to re-evaluate its `<leader>` specs — the reliable place is `init.lua` in your own
fork. Changing it in `user.lua` affects your maps only, which is usually enough.

## 3. Plugins you used that are not included

Add them in `user.lua`; lazy.nvim is already bootstrapped, so `lazy.setup` merges.

```lua
require('lazy').setup({
  { 'tpope/vim-fugitive', cmd = 'Git' },
  { 'christoomey/vim-tmux-navigator', event = 'VeryLazy' },
  { 'maxim/your-favourite-plugin', event = 'BufReadPre' },
})
```

Common cases and what to do instead:

| Old plugin | Recommendation |
|---|---|
| `vim-surround` | `nvim-surround` — same keymaps |
| `fzf.vim` | Telescope is preconfigured; keep fzf via `telescope-fzf-native` if you liked the speed |
| `ALE` | Use the built-in LSP here; ALE's linters can be re-added but duplicate the LSP diagnostics |
| `YouCompleteMe` | blink.cmp + clangd covers the same ground with less setup |
| `tagbar` | The built-in outline (`<leader>o`) already lists subroutines/functions/types |
| `nerdtree` | `nvim-tree` or netrw is disabled; use `<leader>e` |
| `coc.nvim` | Not compatible with the built-in LSP client — port the settings to `vim.lsp.config` |

## 4. Keeping your old highlighting

Tree-sitter highlighting is on by default because it is far more accurate for
modern Fortran and C++. If a parser disagrees with your dialect, fall back to the
classic syntax file for that filetype only:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'fortran' },
  callback = function()
    vim.treesitter.stop(0)
    vim.bo.syntax = 'fortran'
  end,
})
```

You can also keep both: leave tree-sitter on and add
`additional_vim_regex_highlighting` for the filetypes where you want regex
highlighting to fill gaps (the distribution already enables this for Fortran).

## 5. Fixed-form Fortran

Old Fortran projects are the most likely source of surprises. The distribution
decides free vs fixed form from the extension plus a content heuristic, then sets
tabs and indentation accordingly. To force it per file:

```vim
:let b:fortran_fixed_source = 1   " column-sensitive, .f style
:let b:fortran_free_source = 1    " free form regardless of extension
```

## 6. Jumping without a language server

If you relied on `ctags` in a project where no server runs, the built-in outline
and `:DshProjectSymbols` already work offline (they parse the source directly).
For a tag-based workflow, generate tags and use the standard commands:

```bash
ctags -R .
```

```lua
vim.keymap.set('n', '<C-]>', '<cmd>tag <cword><cr>')
vim.keymap.set('n', 'g]', '<cmd>tselect <cword><cr>')
```

## 7. Snippets and templates

`friendly-snippets` is installed. Your own snippets go in the usual place:

```
~/.config/dshstudio/snippets/          # Linux
~/AppData/Local/dshstudio/snippets/    # Windows
~/.config/dshstudio/snippets/          # macOS
```

(lazy.nvim loads them from the LuaSnip-compatible runtime path that blink.cmp
already reads.)

## 8. Checking the result

```vim
:DshHealth       " language servers found, parsers installed, CLI discovery
:DshSelfTest     " offline protocol tests
:Lazy            " plugin state; 'S' to sync, 'L' for the log
:checkhealth     " Neovim's own report
```

If something from your old config is missing, `:DshHealth` is the fastest way to
see whether the underlying tool (clangd, gfortran, a parser) is present at all —
most "my old setup did X" issues are a missing binary rather than a missing plugin.
