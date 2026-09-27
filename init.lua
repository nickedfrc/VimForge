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

---Run a git clone, returning (ok, output).
---@param extra string[]  additional `-c key=value` overrides
local function git_clone(extra)
  local cmd = { 'git' }
  vim.list_extend(cmd, extra or {})
  -- No `--branch`: lazy.nvim publishes only its default branch, and requesting a
  -- `stable` branch fails outright (verified: the ref does not exist).
  vim.list_extend(cmd, { 'clone', '--filter=blob:none', 'https://github.com/folke/lazy.nvim.git', lazypath })
  local out = vim.fn.system(cmd)
  return vim.v.shell_error == 0, out
end

if not (vim.uv or vim.loop).fs_stat(lazy_entry) then
  local ok, out = git_clone(nil)
  if not ok then
    -- A stale proxy in the user's git config is the most common cause of a failed
    -- first run (an unreachable http.proxy makes every clone fail). Retry once
    -- with the proxy bypassed and let git pick its own TLS backend, which is
    -- harmless when no proxy is configured.
    local retry_ok, retry_out = git_clone({
      '-c', 'http.proxy=',
      '-c', 'https.proxy=',
      '-c', 'http.sslBackend=openssl',
    })
    if retry_ok then
      vim.schedule(function()
        vim.notify(
          'lazy.nvim was cloned with the configured git proxy bypassed: your git '
          .. 'config points at a proxy that is not reachable.\n'
          .. 'If plugin installs are slow or fail later, unset it:\n'
          .. '    git config --global --unset http.proxy\n'
          .. '    git config --global --unset https.proxy',
          vim.log.levels.WARN, { title = 'DSH Studio' })
      end)
    else
      ok = false
      out = out .. '\n--- retry with the proxy bypassed ---\n' .. retry_out
    end
  end
  if not ok then
    vim.schedule(function()
      vim.notify(
        'Could not download the plugin manager (lazy.nvim), so plugins are off.\n'
        .. 'The editor, the symbol outline, the project tree, project analysis\n'
        .. 'and the DeepSeek panel still work.\n\n'
        .. 'To fix it, make git able to reach github.com. Usually:\n'
        .. '    git config --global --unset http.proxy\n'
        .. '    git config --global --unset https.proxy\n'
        .. 'then restart and run :Lazy sync.\n\n'
        .. 'git said:\n' .. tostring(out):sub(1, 400),
        vim.log.levels.WARN, { title = 'DSH Studio' })
    end)
  end
end
vim.opt.rtp:prepend(lazypath)

local lazy_ok, lazy = pcall(require, 'lazy')
if lazy_ok then
  local ok, err = pcall(lazy.setup, load_module('dshstudio.plugins') or {}, {
    install = {
      colorscheme = { 'tokyonight', 'habamax' },
      -- Do not attempt installs during setup. Plugins fetched without git
      -- metadata (a tarball install, a vendored copy, an offline bundle) make
      -- lazy's lockfile update call Git.info() on them, which returns nil and
      -- aborts setup inside assert(). Missing plugins are still reported by
      -- `:Lazy` and installed by `:Lazy sync` on request.
      missing = false,
    },
    checker = { enabled = false },
    change_detection = { notify = false },
    ui = { border = 'rounded' },
    performance = {
      rtp = {
        disabled_plugins = { 'gzip', 'tar', 'zip', 'tohtml', 'netrwPlugin' },
      },
    },
  })
  if not ok then
    vim.schedule(function()
      vim.notify('lazy.nvim setup failed: ' .. tostring(err)
        .. '\nPlugins are loaded by the fallback loader instead; the editor, outline, '
        .. 'project tree, project analysis and the DeepSeek panel are unaffected.',
        vim.log.levels.WARN, { title = 'DSH Studio' })
    end)
    -- Make the already-downloaded plugins usable anyway.
    local fallback = load_module('dshstudio.fallback')
    if fallback and fallback.load_plugins then
      pcall(fallback.load_plugins)
    end
  else
    -- lazy.nvim only manages plugins it recognises as installed, which requires
    -- git metadata. Plugins fetched as tarballs, vendored, or shipped inside an
    -- offline bundle have none, so lazy leaves them off the runtime path and the
    -- editor looks bare. Detect that and load them directly.
    local on_rtp = 0
    for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
      if dir:find('/lazy/', 1, true) and not dir:match('lazy%.nvim') then
        on_rtp = on_rtp + 1
      end
    end
    if on_rtp == 0 then
      local fallback = load_module('dshstudio.fallback')
      if fallback and fallback.load_plugins then
        local loaded = select(2, pcall(fallback.load_plugins))
        if type(loaded) == 'number' and loaded > 0 then
          vim.schedule(function()
            vim.notify(('%d plugins were found on disk but are not managed by lazy.nvim '
              .. '(no git metadata), so they were loaded directly. Run :Lazy sync to '
              .. 'have them managed normally.'):format(loaded),
              vim.log.levels.INFO, { title = 'DSH Studio' })
          end)
        end
      end
    end
  end
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

-- If the editor was started on a directory, treat that as the project to work in.
-- Launching from a file manager sets the working directory to wherever the
-- launcher lives (the install folder), so the agent would otherwise be confined
-- to the wrong tree. A directory argument is an unambiguous statement of intent.
do
  local argv0 = vim.fn.argv(0)
  if argv0 ~= '' and vim.fn.isdirectory(argv0) == 1 then
    local ok, session = pcall(require, 'dshstudio.core.session')
    if ok and session and session.detect_workspace_root then
      local dir = session.detect_workspace_root(vim.fn.fnamemodify(argv0, ':p'))
      pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(dir))
      -- Drop the directory from the argument list so it is not opened as a file.
      pcall(vim.cmd, 'silent! argdelete ' .. vim.fn.fnameescape(argv0))
      vim.g.dshstudio_start_dir = dir
    end
  end
end

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
