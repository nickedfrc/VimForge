# Credits, licences and legal notices

DSH Studio is an **independent, unofficial configuration distribution**. It is not
produced by, endorsed by, or affiliated with the Neovim project, the Vim project,
Neovide, DeepSeek, or any plugin author listed below.

The names "Vim", "Neovim", "Neovide" and "DeepSeek" are used only to describe
compatibility and interoperability. No project's name, logo, or branding is
claimed as our own, and this repository contains **no vendored third-party source
code** — only configuration and integration code that we wrote.

## What this repository contains

| Content | Licence |
|---|---|
| All Lua files under `nvim-deepseek-studio/` (configuration + integration) | MIT (see [LICENSE](LICENSE)) |
| Installer scripts under `scripts/` | MIT (same licence) |
| Documentation under `docs/` and the READMEs | MIT (same licence) |

Everything else is downloaded by the installer or by the plugin manager at
install time and remains under its own licence.

## Runtime dependencies (not distributed here)

The editor is Neovim; this project only configures it.

| Project | Role | Licence |
|---|---|---|
| [Neovim](https://github.com/neovim/neovim) | the editor itself (required) | Apache-2.0 (with Vim licence for inherited parts) |
| [Vim](https://github.com/vim/vim) | Neovim's ancestry; the `:help` lineage | Vim licence (GPL-compatible, charityware) |
| [Neovide](https://github.com/neovide/neovide) | optional GUI front-end | MIT |
| [lazy.nvim](https://github.com/folke/lazy.nvim) | plugin manager | Apache-2.0 |
| [DeepSeek Harness (`@deepseek-ai/dsh`)](https://www.npmjs.com/package/@deepseek-ai/dsh) | the agent this integrates with | see its package licence |

## Plugins configured by this distribution

Each is fetched from its own repository at install time and is used unmodified.

| Plugin | Licence |
|---|---|
| [tokyonight.nvim](https://github.com/folke/tokyonight.nvim) | Apache-2.0 |
| [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) | MIT |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) | MIT |
| [which-key.nvim](https://github.com/folke/which-key.nvim) | Apache-2.0 |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Apache-2.0 |
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) | MIT |
| [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) | MIT |
| [telescope-fzf-native.nvim](https://github.com/nvim-telescope/telescope-fzf-native.nvim) | MIT |
| [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) | MIT |
| [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) | MIT |
| [nvim-autopairs](https://github.com/windwp/nvim-autopairs) | MIT |
| [Comment.nvim](https://github.com/numToStr/Comment.nvim) | MIT |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Apache-2.0 |
| [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) | Apache-2.0 |
| [mason.nvim](https://github.com/williamboman/mason.nvim) | Apache-2.0 |
| [mason-lspconfig.nvim](https://github.com/williamboman/mason-lspconfig.nvim) | Apache-2.0 |
| [blink.cmp](https://github.com/Saghen/blink.cmp) | MIT |
| [friendly-snippets](https://github.com/rafamadriz/friendly-snippets) | MIT |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) | MIT |

Licence identifiers above follow each project's own statement at the time of
writing. If you redistribute this configuration, verify the current licence of
every dependency you ship alongside it.

## Language servers

Installed separately, under their own licences:

| Server | Licence |
|---|---|
| [clangd (LLVM)](https://clangd.llvm.org/) | Apache-2.0 with LLVM exceptions |
| [pyright](https://github.com/microsoft/pyright) | MIT |
| [fortls](https://github.com/fortran-lang/fortls) | MIT |
| [lua-language-server](https://github.com/LuaLS/lua-language-server) | MIT |

## Why the naming avoids a trademark problem

- The repository is not called "Neovim…" or "Vim…", so it cannot be mistaken for
  an official release or an official spin.
- The README states in its first paragraph that this is a distribution *of*
  Neovim, built on it, and not affiliated with it.
- No upstream branding, icons, or artwork is copied into this repository.
- The binary that the installer downloads is the official upstream Neovim build,
  fetched from the Neovim project's own release page and left unmodified.

If you fork this and publish it, keep those three properties (own name, clear
non-affiliation statement, no upstream branding) and you stay on the right side of
the trademark question.

## Changes made to upstream defaults

For transparency, this is everything the distribution does *on top of* stock
Neovim rather than through it:

1. Sets options, keymaps and per-filetype indentation (including fixed/free-form
   Fortran handling).
2. Configures the **built-in** LSP client (`vim.lsp.config`/`vim.lsp.enable`) —
   it does not fork or patch any language server.
3. Configures tree-sitter highlighting through the public plugin API.
4. Adds one first-party plugin (`dshstudio`) that talks ACP to DeepSeek Harness
   and builds project reports.

No upstream file is patched on disk. If you delete this configuration directory,
the upstream projects are untouched.
