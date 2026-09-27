-- Plugin specifications for DSH Studio.
--
-- Design rule: nothing here may be required at startup unless the editor is
-- unusable without it. Treesitter, LSP, picker and UI plugins load on demand so
-- a slow first clone cannot block the editor from opening a file.

local function gh(repo) return 'https://github.com/' .. repo end

return {
  -- ---------------------------------------------------------------------
  -- Look and feel
  -- ---------------------------------------------------------------------
  {
    'folke/tokyonight.nvim',
    lazy = false,
    priority = 1000,
    opts = { style = 'night', transparent = false },
  },
  {
    'nvim-lualine/lualine.nvim',
    event = 'VeryLazy',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = function()
      -- Surface the live DSH session state in the statusline.
      local function dsh_component()
        local ok, s = pcall(require, 'dshstudio.core.session')
        if not ok then return '' end
        local st = s.agent_status()
        if not st.connected then return ' DSH:off ' end
        local model = s.model_label()
        if s.is_busy() then return ' DSH:' .. model .. ' * ' end
        return ' DSH:' .. model .. ' '
      end
      local function dsh_analysis()
        local ok, a = pcall(require, 'dshstudio.project.analysis')
        if not ok or not a.status then return '' end
        local ok2, text = pcall(a.status)
        return ok2 and text or ''
      end
      return {
        options = {
          theme = 'auto',
          globalstatus = true,
          component_separators = { left = '', right = '' },
          section_separators = { left = '', right = '' },
        },
        sections = {
          lualine_a = { 'mode' },
          lualine_b = { 'branch', 'diff', 'diagnostics' },
          lualine_c = { { 'filename', path = 1 } },
          lualine_x = { dsh_analysis, dsh_component, 'filetype' },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
      }
    end,
  },
  {
    'nvim-tree/nvim-web-devicons',
    lazy = true,
  },
  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts = {
      spec = {
        { '<leader>d', group = 'DeepSeek' },
        { '<leader>g', group = 'goto' },
        { '<leader>f', group = 'find/format' },
      },
    },
  },
  {
    'folke/snacks.nvim',
    priority = 900,
    lazy = false,
    opts = {
      notifier = { enabled = true, timeout = 3000 },
      input = { enabled = true },
      bigfile = { enabled = true },
      quickfile = { enabled = true },
      statuscolumn = { enabled = true },
      words = { enabled = false },
      dashboard = { enabled = false },
      terminal = { enabled = true },
    },
  },

  -- ---------------------------------------------------------------------
  -- Navigation and editing
  -- ---------------------------------------------------------------------
  {
    'nvim-telescope/telescope.nvim',
    cmd = 'Telescope',
    dependencies = {
      'nvim-lua/plenary.nvim',
      {
        'nvim-telescope/telescope-fzf-native.nvim',
        build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release',
        cond = function() return vim.fn.executable('cmake') == 1 end,
      },
    },
    keys = {
      { '<leader>ff', '<cmd>Telescope find_files<cr>', desc = 'Find files' },
      { '<leader>fg', '<cmd>Telescope live_grep<cr>', desc = 'Live grep' },
      { '<leader>fb', '<cmd>Telescope buffers<cr>', desc = 'Buffers' },
      { '<leader>fs', '<cmd>Telescope lsp_document_symbols<cr>', desc = 'Document symbols' },
      { '<leader>fw', '<cmd>Telescope lsp_workspace_symbols<cr>', desc = 'Workspace symbols' },
      { '<leader>fd', '<cmd>Telescope diagnostics<cr>', desc = 'Diagnostics' },
      { '<leader>fr', '<cmd>Telescope lsp_references<cr>', desc = 'References' },
      { '<leader>fh', '<cmd>Telescope help_tags<cr>', desc = 'Help' },
    },
    opts = function()
      local actions = require('telescope.actions')
      return {
        defaults = {
          mappings = {
            i = {
              ['<C-j>'] = actions.move_selection_next,
              ['<C-k>'] = actions.move_selection_previous,
              ['<Esc>'] = actions.close,
            },
          },
          file_ignore_patterns = { '^%.git/', 'node_modules/', 'build/', '_build/', '__pycache__/', '%.o$', '%.mod$' },
        },
      }
    end,
    config = function(_, opts)
      require('telescope').setup(opts)
      pcall(require('telescope').load_extension, 'fzf')
    end,
  },
  {
    'nvim-tree/nvim-tree.lua',
    cmd = { 'NvimTreeToggle', 'NvimTreeFocus' },
    keys = { { '<leader>e', '<cmd>NvimTreeToggle<cr>', desc = 'File tree' } },
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = {
      disable_netrw = true,
      hijack_netrw = true,
      view = { width = 34, side = 'left' },
      renderer = { group_empty = true, indent_markers = { enable = true } },
      filters = { dotfiles = false, custom = { '^%.git$', 'node_modules', '__pycache__' } },
      git = { enable = true },
      update_focused_file = { enable = true, update_root = false },
    },
  },
  {
    'lewis6991/gitsigns.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },
  {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    opts = {},
  },
  {
    'numToStr/Comment.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {},
  },

  -- ---------------------------------------------------------------------
  -- Syntax highlighting and completion
  -- ---------------------------------------------------------------------
  {
    -- Pinned to `master`: the `main` rewrite drops `nvim-treesitter.configs`,
    -- and this configuration relies on that module (with a runtime fallback).
    'nvim-treesitter/nvim-treesitter',
    branch = 'master',
    lazy = false,
    build = ':TSUpdate',
  },

  -- ---------------------------------------------------------------------
  -- LSP: server installation and rich completion
  -- ---------------------------------------------------------------------
  {
    'williamboman/mason.nvim',
    cmd = 'Mason',
    opts = {
      ui = { border = 'rounded' },
    },
  },
  {
    'williamboman/mason-lspconfig.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = { 'williamboman/mason.nvim', 'neovim/nvim-lspconfig' },
    opts = {
      -- fortls has no mason recipe on every platform, so it is best-effort here
      -- and the LSP module falls back to a pip-installed binary.
      ensure_installed = { 'clangd', 'pyright', 'lua_ls' },
      automatic_installation = true,
    },
  },
  {
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = { 'williamboman/mason.nvim' },
  },
  {
    'saghen/blink.cmp',
    event = { 'InsertEnter', 'CmdlineEnter' },
    version = '1.*',
    dependencies = { 'rafamadriz/friendly-snippets' },
    opts = {
      keymap = { preset = 'default', ['<C-y>'] = { 'select_and_accept' } },
      appearance = { nerd_font_variant = 'mono' },
      sources = { default = { 'lsp', 'path', 'snippets', 'buffer' } },
      completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 300 },
        ghost_text = { enabled = false },
      },
      signature = { enabled = true },
    },
  },

  -- ---------------------------------------------------------------------
  -- Markdown (report reading inside the editor)
  -- ---------------------------------------------------------------------
  {
    'MeanderingProgrammer/render-markdown.nvim',
    ft = { 'markdown' },
    opts = {
      heading = { sign = false },
      code = { sign = false },
    },
  },
}
