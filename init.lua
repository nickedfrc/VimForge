-- DSH Studio — editor entry point.
--
-- Boot order matters and is explicit here:
--   1. options that lazy.nvim itself reads (`mapleader`, `maplocalleader`)
--   2. lazy.nvim bootstrap (clones the plugin manager on first launch)
--   3. plugin loading
--   4. first-party modules (config -> editor -> treesitter -> lsp -> keymaps)
--
-- Every first-party step is pcall-guarded: a broken optional feature must never
-- stop the editor from opening a file.

-- Neovim 0.11 is the floor (built-in `vim.lsp.config`/`vim.lsp.enable`).
if vim.fn.has('nvim-0.11') == 0 then
  vim.notify(
    'DSH Studio requires Neovim 0.11 or newer. Running versions are unsupported.',
    vim.log.levels.ERROR, { title = 'DSH Studio' })
end

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- netrw clashes with nvim-tree; the plugin file owns the flags so it happens
-- before the runtime loads netrw's own plugin script.
vim.g.dshstudio_loaded = (vim.g.dshstudio_loaded or 0) + 1

local function load_module(name)
  local ok, mod = pcall(require, name)
  if not ok then
    vim.schedule(function()
      vim.notify(('DSH Studio: module `%s` failed to load: %s'):format(name, tostring(mod)),
        vim.log.levels.ERROR, { title = 'DSH Studio' })
    end)
    return nil
  end
  return mod
end

-- ---------------------------------------------------------------------------
-- lazy.nvim bootstrap
-- ---------------------------------------------------------------------------

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
-- Check for the module entry point, not just the directory: an interrupted
-- clone can leave the directory present but empty, which would make this
-- bootstrap skip the clone and then fail to load the plugin manager entirely.
local lazy_entry = lazypath .. '/lua/lazy/init.lua'
if not (vim.uv or vim.loop).fs_stat(lazy_entry) then
  local repo = 'https://github.com/folke/lazy.nvim.git'
  -- No `--branch`: lazy.nvim publishes only its default branch, and requesting a
  -- `stable` branch fails outright (verified: the ref does not exist).
  local out = vim.fn.system({ 'git', 'clone', '--filter=blob:none', repo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.notify('Failed to clone lazy.nvim:\n' .. out, vim.log.levels.ERROR, { title = 'DSH Studio' })
    -- Continue with built-in features only rather than refusing to start.
  end
end
vim.opt.rtp:prepend(lazypath)

local lazy_ok, lazy = pcall(require, 'lazy')
if lazy_ok then
  lazy.setup(load_module('dshstudio.plugins') or {}, {
    install = { colorscheme = { 'tokyonight', 'habamax' } },
    checker = { enabled = false },
    change_detection = { notify = false },
    ui = { border = 'rounded' },
    performance = {
      rtp = {
        disabled_plugins = { 'gzip', 'tar', 'zip', 'tohtml', 'netrwPlugin' },
      },
    },
  })
else
  vim.notify('lazy.nvim unavailable — plugin features are disabled, core editor features remain.',
    vim.log.levels.WARN, { title = 'DSH Studio' })
end

-- ---------------------------------------------------------------------------
-- First-party setup
-- ---------------------------------------------------------------------------

local config = load_module('dshstudio.config')
if config and config.setup then pcall(config.setup) end

local function setup(name, method)
  local mod = load_module(name)
  if mod and method and mod[method] then
    local ok, err = pcall(mod[method])
    if not ok then
      vim.schedule(function()
        vim.notify(('DSH Studio: %s.%s failed: %s'):format(name, method, tostring(err)),
          vim.log.levels.ERROR, { title = 'DSH Studio' })
      end)
    end
  end
  return mod
end

setup('dshstudio.editor', 'setup')
setup('dshstudio.treesitter', 'setup')
setup('dshstudio.lsp', 'setup')
setup('dshstudio.lang', 'setup')
setup('dshstudio.keymaps', 'setup')

-- Make the integration discoverable. Every DeepSeek feature sits behind a
-- <leader> map or a :Dsh* command, and without this a first run shows an empty
-- buffer with no hint that a panel, a model picker or a project report exist.
-- Shown once per profile, only when no file was given, and suppressed by
-- `vim.g.dshstudio_welcome = false`.
do
  local welcome = load_module('dshstudio.ui.welcome')
  if welcome and welcome.maybe_show then
    local ok, err = pcall(welcome.maybe_show)
    if not ok then
      vim.schedule(function()
        vim.notify('welcome panel failed: ' .. tostring(err), vim.log.levels.DEBUG,
          { title = 'DSH Studio' })
      end)
    end
  end
end

-- Personal overrides load last, so they win over every default. `user.lua` is
-- git-ignored and optional: copy `user.example.lua` to create it. Loading it by
-- module name (rather than a fixed path) means a syntax error there is reported
-- like any other module failure instead of breaking startup silently.
local has_user = pcall(require, 'dshstudio.user')
if not has_user then
  -- Not an error: the file simply has not been created yet.
  vim.g.dshstudio_user_loaded = false
else
  vim.g.dshstudio_user_loaded = true
end

-- Share the config directory with the syntax files shipped in after/ftplugin.
vim.g.dshstudio_repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')

-- Colour the DSH panel without depending on a colourscheme's own groups.
vim.api.nvim_set_hl(0, 'DshSidebarUser', { fg = '#7aa2f7', bold = true })
vim.api.nvim_set_hl(0, 'DshSidebarAgent', { fg = '#9ece6a', bold = true })
vim.api.nvim_set_hl(0, 'DshSidebarUserText', { link = 'Normal' })
vim.api.nvim_set_hl(0, 'DshSidebarAgentText', { link = 'Normal' })
vim.api.nvim_set_hl(0, 'DshSidebarThought', { fg = '#565f89', italic = true })
vim.api.nvim_set_hl(0, 'DshSidebarTool', { fg = '#e0af68' })
vim.api.nvim_set_hl(0, 'DshSidebarToolDetail', { fg = '#737aa2' })
vim.api.nvim_set_hl(0, 'DshSidebarSystem', { fg = '#f7768e' })
vim.api.nvim_set_hl(0, 'DshSidebarHint', { fg = '#565f89' })
vim.api.nvim_set_hl(0, 'DshSidebarBar', { fg = '#bb9af7', bold = true })
vim.api.nvim_set_hl(0, 'DshSidebarBarDim', { fg = '#565f89' })
