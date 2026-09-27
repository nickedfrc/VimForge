-- dshstudio/editor.lua
--
-- Editor behaviour for DSH Studio: sane global defaults, per-filetype indentation
-- for the supported scientific languages, treesitter folding, and explicit
-- buffer maintenance commands.
--
-- This module is loaded during startup: it only touches options/autocmds and
-- never requires another dshstudio module at load time (util is required lazily
-- inside the callbacks so a broken util cannot abort startup).

local M = {}

---Per-filetype settings applied with vim.opt_local inside a FileType autocmd.
---Keeping them in one table (instead of many small autocmds) makes the
---distribution's indentation policy auditable in a single place.
M.ft_options = {
  -- Fortran: the community standard is a 2-space free-form indent. Fixed-form
  -- code is handled by the same values (Vim's fortran ftplugin only adds
  -- comments/formatoptions), so 2 is safe for both source forms.
  fortran = {
    tabstop = 2,
    shiftwidth = 2,
    softtabstop = 2,
    expandtab = true,
    commentstring = '! %s',
    -- Free-form style: do not insert a comment leader when wrapping (fixed-form
    -- column rules make automatic wrapping actively harmful).
    formatoptions = 'cqj',
  },
  c = { tabstop = 4, shiftwidth = 4, softtabstop = 4, expandtab = true },
  cpp = { tabstop = 4, shiftwidth = 4, softtabstop = 4, expandtab = true },
  cuda = { tabstop = 4, shiftwidth = 4, softtabstop = 4, expandtab = true },
  python = {
    tabstop = 4,
    shiftwidth = 4,
    softtabstop = 4,
    expandtab = true,
    commentstring = '# %s',
    -- PEP 8 keeps the text width unbounded in practice; the 't' flag is what
    -- makes Vim hard-wrap on insert, which Python style guides do not want.
    formatoptions = 'cqj',
  },
  lua = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  vim = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  sh = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  bash = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  json = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  yaml = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
  markdown = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true, wrap = true },
  cmake = { tabstop = 2, shiftwidth = 2, softtabstop = 2, expandtab = true },
}

---Filetypes for which treesitter-based `foldexpr` is enabled when a parser
---exists. Kept separate from ft_options: folding is opt-in per language and
---depends on the parser being installed.
local FOLD_FILETYPES = {
  c = true,
  cpp = true,
  cuda = true,
  fortran = true,
  python = true,
  lua = true,
  vim = true,
  bash = true,
  sh = true,
  json = true,
  yaml = true,
  cmake = true,
}

---Apply a table of option names/values with vim.opt_local, ignoring failures
---(an unknown option in a user table must not break filetype loading).
---@param opts table<string, any>
---@param buf integer|nil
local function apply_local(opts, buf)
  if type(opts) ~= 'table' then
    return
  end
  for name, value in pairs(opts) do
    pcall(function()
      if buf ~= nil then
        -- Buffer-scoped options take { buf = ... }; window-local ones (markdown's
        -- 'wrap') may need the window, so fall back to opt_local in buf context.
        local ok = pcall(vim.api.nvim_set_option_value, name, value, { buf = buf })
        if ok then
          return
        end
        local in_buf = pcall(vim.api.nvim_buf_call, buf, function()
          vim.opt_local[name] = value
        end)
        if in_buf then
          return
        end
      end
      vim.opt_local[name] = value
    end)
  end
end

---Apply the configured indentation/wrapping for one filetype.
---@param ft string
---@param buf integer|nil
function M.set_indent(ft, buf)
  if type(ft) ~= 'string' or ft == '' then
    return false
  end
  local opts = M.ft_options[ft]
  if opts == nil then
    return false
  end
  apply_local(opts, buf)
  return true
end

---Strip trailing whitespace in a buffer. Deliberately NOT automatic: silently
---rewriting lines the user is editing causes noisy diffs and lost undo points.
---@param buf integer|nil defaults to the current buffer
---@return boolean changed
function M.strip_trailing_whitespace(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local ok, changed = pcall(function()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return false
    end
    if vim.bo[buf].modifiable == false then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local dirty = false
    for i = 1, #lines do
      local stripped = lines[i]:gsub('[ \t]+$', '')
      if stripped ~= lines[i] then
        lines[i] = stripped
        dirty = true
      end
    end
    if not dirty then
      return false
    end
    -- Preserve cursor/window state: a cleanup command must not move the view.
    local view = vim.fn.winsaveview()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if vim.api.nvim_get_current_buf() == buf then
      pcall(vim.fn.winrestview, view)
    end
    return true
  end)
  local did_change = ok and changed == true
  local util_ok, util = pcall(require, 'dshstudio.util')
  if util_ok and type(util) == 'table' and type(util.notify) == 'function' then
    if did_change then
      pcall(util.notify, 'Stripped trailing whitespace', 'info')
    else
      pcall(util.notify, 'No trailing whitespace to strip', 'info')
    end
  end
  return did_change
end

---Reload the current buffer from disk, ignoring 'autoread'.
---@param buf integer|nil
---@return boolean
function M.reload_from_disk(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local ok = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('edit!')
    end)
  end)
  return ok
end

---Friendly notice used by the FileChangedShellPost autocmd.
---@param name string|nil
---Tell the user a buffer was reloaded, and warn when a reload did NOT happen.
---
---The dangerous case is an external writer (the agent, a formatter, another
---editor) changing a file whose buffer has unsaved edits. Neovim then refuses to
---reload, so the buffer keeps the old text and the next `:w` silently discards
---whatever was written. Staying quiet there loses work, so this says plainly which
---file, which side, and what to do.
---@param name string|nil  the file reported by the event
---@param reloaded boolean|nil  true when the buffer was actually reloaded
local function notify_reloaded(name, reloaded)
  local util_ok, util = pcall(require, 'dshstudio.util')
  local function say(message, level)
    if util_ok and type(util) == 'table' and type(util.notify) == 'function' then
      pcall(util.notify, message, level)
    end
  end

  local label = name
  if type(label) ~= 'string' or label == '' then
    label = vim.fn.expand('%:t')
  end

  if reloaded == false then
    say(('%s changed on disk, but this buffer has unsaved changes, so it was NOT '
      .. 'reloaded.\nSaving now (:w) would discard the on-disk version. Choose one:\n'
      .. '  :e!          reload from disk, discarding your unsaved edits\n'
      .. '  :w           keep your edits and overwrite the file\n'
      .. '  :Diffsplit   compare the two versions first'):format(label),
      vim.log.levels.WARN)
    return
  end

  say(('Reloaded %s from disk (it changed outside Neovim)'):format(label), vim.log.levels.WARN)
end

---Set treesitter folding for one window/buffer when a parser is available.
---@param buf integer
local function enable_ts_folding(buf)
  pcall(function()
    local ft = vim.bo[buf].filetype
    if not FOLD_FILETYPES[ft] then
      return
    end
    if type(vim.treesitter) ~= 'table' or type(vim.treesitter.foldexpr) ~= 'function' then
      return
    end
    local lang = ft
    if ft == 'sh' then
      lang = 'bash'
    elseif ft == 'cuda' then
      lang = 'cpp'
    end
    local have_parser = false
    local ok_add = pcall(vim.treesitter.language.add, lang)
    have_parser = ok_add == true
    if not have_parser then
      -- Older/newer API shape: inspect() errors when the parser is missing.
      local ok_ins, info = pcall(vim.treesitter.language.inspect, lang)
      have_parser = ok_ins and info ~= nil
    end
    if not have_parser then
      return
    end
    local wins = vim.fn.win_findbuf(buf)
    if type(wins) ~= 'table' or #wins == 0 then
      wins = { vim.api.nvim_get_current_win() }
    end
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_set_option_value, 'foldmethod', 'expr', { win = win })
      pcall(vim.api.nvim_set_option_value, 'foldexpr', 'v:lua.vim.treesitter.foldexpr()', { win = win })
      pcall(vim.api.nvim_set_option_value, 'foldlevel', 99, { win = win })
    end
  end)
end

---Apply the global option defaults. Idempotent; safe to call twice.
---@return nil
function M.setup()
  -- Global/editor-wide options. Each is pcall'd: a single unsupported option
  -- (older Neovim, no clipboard provider, read-only undo dir) must not abort the
  -- rest of the configuration.
  local global = {
    number = true,
    relativenumber = true,
    signcolumn = 'yes',
    expandtab = true,
    tabstop = 4, -- C/C++/Python default; filetype autocmds refine per language
    shiftwidth = 4,
    softtabstop = 4,
    smartindent = true,
    autoindent = true,
    ignorecase = true,
    smartcase = true,
    incsearch = true,
    hlsearch = true,
    termguicolors = true,
    undofile = true,
    swapfile = false, -- editor crashes are rare; swap prompts are constant noise
    backup = false,
    writebackup = false,
    updatetime = 300, -- diagnostics/diagnostic-float latency
    timeoutlen = 400, -- leader prefix resolution (see dshstudio.keymaps)
    splitright = true,
    splitbelow = true,
    scrolloff = 4,
    wrap = false,
    mouse = 'a',
    completeopt = 'menu,menuone,noselect',
    cursorline = true,
    list = false,
    clipboard = 'unnamedplus',
    autoread = true, -- pairs with the checktime autocmd below
  }
  for name, value in pairs(global) do
    pcall(function()
      vim.opt[name] = value
    end)
  end

  -- listchars only matters once `list` is toggled on by the user.
  pcall(function()
    vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣', extends = '›', precedes = '‹' }
  end)

  -- Keep undo files inside the state directory so they never appear in a
  -- project tree (and survive a cache clean).
  pcall(function()
    local dir = vim.fn.stdpath('state') .. '/undo'
    local util_ok, util = pcall(require, 'dshstudio.util')
    if util_ok and type(util) == 'table' and type(util.mkdirp) == 'function' then
      pcall(util.mkdirp, dir)
    end
    vim.opt.undodir = dir
  end)

  local group = vim.api.nvim_create_augroup('DshStudioEditor', { clear = true })

  -- Per-filetype indentation/wrapping.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(args)
      local ft = args.match or vim.bo[args.buf].filetype
      M.set_indent(ft, args.buf)
    end,
    desc = 'DSH Studio: per-language indentation and wrapping',
  })

  -- Treesitter folding. Deferred with vim.schedule so parsers/plugins loaded by
  -- the same FileType event have settled before foldexpr is queried.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(args)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          enable_ts_folding(args.buf)
        end
      end)
    end,
    desc = 'DSH Studio: treesitter folding when a parser is available',
  })

  -- Reload files that changed on disk. 'autoread' alone only checks on certain
  -- events, so drive checktime explicitly when the editor regains focus.
  vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold', 'CursorHoldI', 'TermClose', 'TermLeave' }, {
    group = group,
    callback = function()
      pcall(function()
        -- Never run checktime while the command line is active: it can drop the
        -- user out of a partially typed command.
        if vim.fn.getcmdwintype() ~= '' then
          return
        end
        if vim.fn.mode() == 'c' then
          return
        end
        vim.cmd('checktime')
      end)
    end,
    desc = 'DSH Studio: pick up on-disk changes (autoread)',
  })

  vim.api.nvim_create_autocmd('FileChangedShellPost', {
    group = group,
    callback = function(args)
      notify_reloaded(args and args.file or nil, true)
    end,
    desc = 'DSH Studio: tell the user a buffer was reloaded',
  })

  -- Fires when a file changed on disk and Neovim decided what to do about it.
  -- A buffer with unsaved changes is left alone, which is the case worth warning
  -- about: the next write would discard the external change.
  vim.api.nvim_create_autocmd('FileChangedShell', {
    group = group,
    callback = function(args)
      local buf = args and args.buf
      if buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
        notify_reloaded(args.file, false)
      end
    end,
    desc = 'DSH Studio: warn when an external change cannot be reloaded',
  })

  -- Trailing whitespace is removed only through an explicit command.
  pcall(function()
    vim.api.nvim_create_user_command('DshStripWhitespace', function()
      M.strip_trailing_whitespace(0)
    end, { desc = 'DSH Studio: strip trailing whitespace in the current buffer' })
  end)

  pcall(function()
    vim.api.nvim_create_user_command('DshReloadFromDisk', function()
      M.reload_from_disk(0)
    end, { desc = 'DSH Studio: force-reload the current buffer from disk' })
  end)
end

return M
