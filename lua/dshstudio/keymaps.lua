-- dshstudio/keymaps.lua
--
-- Default keymaps for DSH Studio.
--
-- Design rules:
--   * every cross-module call goes through `try()`/`try_list()`, which pcall the
--     require AND the call and report a friendly message -- a module that is
--     missing or mid-refactor must never make a keymap explode;
--   * LSP mappings live in a buffer-local LspAttach autocmd so they only exist
--     where a language server is attached (and never shadow the global ones
--     elsewhere);
--   * `keymaps = false` in the config disables the whole set.

local M = {}

local unpack = table.unpack or unpack

---Lazy notify (never a hard dependency on dshstudio.util).
---@param msg string
---@param level string|number|nil
local function notify(msg, level)
  local ok, util = pcall(require, 'dshstudio.util')
  if ok and type(util) == 'table' and type(util.notify) == 'function' then
    pcall(util.notify, msg, level)
    return
  end
  pcall(vim.notify, msg, vim.log.levels.INFO, { title = 'DSH Studio' })
end

---Call mod.fn(...) with full protection.
---@param mod string module name, e.g. 'dshstudio.ui.tree'
---@param fn string function name on that module
---@return any result of the call, or nil when it could not be made
local function try(mod, fn, ...)
  local n = select('#', ...)
  local args = { ... }
  local ok, loaded = pcall(require, mod)
  if not ok then
    notify(('%s is unavailable: %s'):format(mod, tostring(loaded)), 'warn')
    return nil
  end
  if type(loaded) ~= 'table' then
    notify(('%s did not return a table'):format(mod), 'warn')
    return nil
  end
  local target = loaded[fn]
  if type(target) ~= 'function' then
    notify(('%s.%s() is not implemented yet'):format(mod, fn), 'warn')
    return nil
  end
  local called, result = pcall(target, unpack(args, 1, n))
  if not called then
    notify(('%s.%s() failed: %s'):format(mod, fn, tostring(result)), 'error')
    return nil
  end
  return result
end

---Like try(), but walks a list of {module, function} candidates so a module that
---gets renamed only costs a notification, not a dead key.
---@param candidates table[] list of {mod, fn}
---@return any
local function try_list(candidates, ...)
  if type(candidates) ~= 'table' then
    return nil
  end
  for _, candidate in ipairs(candidates) do
    local mod, fn = candidate[1], candidate[2]
    if type(mod) == 'string' and type(fn) == 'string' then
      local ok, loaded = pcall(require, mod)
      if ok and type(loaded) == 'table' and type(loaded[fn]) == 'function' then
        local n = select('#', ...)
        local args = { ... }
        local called, result = pcall(loaded[fn], unpack(args, 1, n))
        if called then
          return result
        end
        notify(('%s.%s() failed: %s'):format(mod, fn, tostring(result)), 'error')
        return nil
      end
    end
  end
  local first = candidates[1] or { '?', '?' }
  notify(('%s.%s() is not available in this build'):format(first[1], first[2]), 'warn')
  return nil
end

---Run a vim.lsp builtin with a guard (an LSP call without a server throws).
---@param fn string name under vim.lsp.buf
---@param opts table|nil
local function lsp(fn, opts)
  local target = vim.lsp and vim.lsp.buf and vim.lsp.buf[fn]
  if type(target) ~= 'function' then
    notify(('vim.lsp.buf.%s is unavailable (Neovim too old?)'):format(fn), 'warn')
    return
  end
  local ok, err = pcall(target, opts)
  if not ok then
    notify(('vim.lsp.buf.%s failed: %s'):format(fn, tostring(err)), 'error')
  end
end

---Call a telescope builtin, accepting a fallback name list.
---@param names string|string[]
---@param opts table|nil
local function telescope(names, opts)
  local ok, builtin = pcall(require, 'telescope.builtin')
  if not ok or type(builtin) ~= 'table' then
    notify('telescope.nvim is not installed or not loaded', 'warn')
    return
  end
  local list = type(names) == 'table' and names or { names }
  for _, name in ipairs(list) do
    local picker = builtin[name]
    if type(picker) == 'function' then
      local called, err = pcall(picker, opts)
      if not called then
        -- A missing fd/ripgrep is the usual cause and worth naming explicitly.
        notify(('telescope.%s failed: %s (is fd/ripgrep installed?)'):format(name, tostring(err)), 'error')
      end
      return
    end
  end
  notify(('telescope.%s is not available'):format(list[1]), 'warn')
end

-- Context helpers ------------------------------------------------------------

---Lines of the last visual selection, or the whole buffer.
---@return string[]|nil lines, string source ('selection'|'buffer')
local function gather_context()
  local ok, lines, source = pcall(function()
    local mode = vim.fn.mode()
    local visual = mode == 'v' or mode == 'V' or mode == '\22'
    if visual then
      local start = vim.fn.getpos("'<")
      local finish = vim.fn.getpos("'>")
      local first_line, last_line = start[2], finish[2]
      if first_line > 0 and last_line >= first_line then
        local chunk = vim.api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
        if #chunk > 0 then
          local start_col, end_col = start[3], finish[3]
          if #chunk == 1 then
            chunk[1] = chunk[1]:sub(start_col, end_col)
          else
            chunk[1] = chunk[1]:sub(start_col)
            chunk[#chunk] = chunk[#chunk]:sub(1, end_col)
          end
          return chunk, 'selection'
        end
      end
    end
    return vim.api.nvim_buf_get_lines(0, 0, -1, false), 'buffer'
  end)
  if not ok then
    return nil, 'buffer'
  end
  return lines, source
end

---Send the editor context to the agent.
---The sidebar owns the prompt UI and the context-mode plumbing
---(core/context.lua accepts the modes 'none' | 'file' | 'selection'), so prefer
---it and only fall back to a direct session prompt when the sidebar is absent.
---@param source string 'selection'|'buffer'
local function ask_with_context(source)
  local mode = (source == 'selection') and 'selection' or 'file'

  local ok_sidebar, sidebar = pcall(require, 'dshstudio.ui.sidebar')
  if ok_sidebar and type(sidebar) == 'table' then
    if source == 'selection' and type(sidebar.ask_selection) == 'function' then
      local called, err = pcall(sidebar.ask_selection)
      if called then
        return
      end
      notify(('dshstudio.ui.sidebar.ask_selection() failed: %s'):format(tostring(err)), 'error')
    end
    if type(sidebar.ask) == 'function' then
      local called, err = pcall(sidebar.ask, nil, mode)
      if called then
        return
      end
      notify(('dshstudio.ui.sidebar.ask() failed: %s'):format(tostring(err)), 'error')
    end
  end

  -- Fallback: hand the gathered text straight to the session transport.
  local lines, origin = gather_context()
  if type(lines) ~= 'table' or #lines == 0 then
    notify('Nothing to send: the buffer is empty', 'warn')
    return
  end
  local text = table.concat(lines, '\n')
  local session = {
    { 'dshstudio.core.session', 'prompt' },
    { 'dshstudio.core.session', 'ask_with_context' },
    { 'dshstudio.core.session', 'ask' },
    { 'dshstudio.core.session', 'send' },
  }
  local sent = false
  for _, candidate in ipairs(session) do
    local mod, fn = candidate[1], candidate[2]
    local loaded_ok, loaded = pcall(require, mod)
    if loaded_ok and type(loaded) == 'table' and type(loaded[fn]) == 'function' then
      local called, err = pcall(loaded[fn], text, { source = origin or source, mode = mode, lines = lines })
      if not called then
        called, err = pcall(loaded[fn], text)
      end
      if called then
        sent = true
      else
        notify(('%s.%s() failed: %s'):format(mod, fn, tostring(err)), 'error')
      end
      break
    end
  end
  if not sent then
    notify('No session module found (expected dshstudio.core.session.prompt)', 'warn')
  end
end

---Copy a git permalink-ish reference for the current position to the clipboard.
local function copy_git_reference()
  local ok, reference = pcall(function()
    local util_ok, util = pcall(require, 'dshstudio.util')
    if not (util_ok and type(util) == 'table') then
      return nil
    end
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(buf)
    if path == '' then
      return nil
    end
    local dir = vim.fn.fnamemodify(path, ':p:h')
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local root = util.find_root(dir, { '.git' })
    if not root then
      return nil
    end
    local rev_ok, rev = util.run_capture({ 'git', 'rev-parse', '--short', 'HEAD' }, root, 5000)
    local url_ok, url = util.run_capture({ 'git', 'remote', 'get-url', 'origin' }, root, 5000)
    local relative = util.relpath(path, root)
    if type(relative) ~= 'string' or relative == '' then
      relative = vim.fn.fnamemodify(path, ':t')
    end
    relative = relative:gsub('\\', '/')
    local anchor = 'L' .. line
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' or mode == '\22' then
      local finish = vim.fn.getpos("'>")[2]
      local start = vim.fn.getpos("'<")[2]
      if finish > start then
        anchor = ('L%d-L%d'):format(start, finish)
      end
    end
    if url_ok and type(url) == 'string' then
      url = util.trim(url)
      if url ~= '' then
        -- git@host:owner/repo.git -> https://host/owner/repo
        url = url:gsub('^git@([^:]+):', 'https://%1/')
        url = url:gsub('^ssh://git@', 'https://')
        url = url:gsub('%.git$', '')
        if url:match('^https?://') then
          if rev_ok and type(rev) == 'string' and util.trim(rev) ~= '' then
            return ('%s/blob/%s/%s#%s'):format(url, util.trim(rev), relative, anchor)
          end
          return ('%s/blob/HEAD/%s#%s'):format(url, relative, anchor)
        end
      end
    end
    return ('%s:%d'):format(relative, line)
  end)
  if not ok or type(reference) ~= 'string' or reference == '' then
    notify('No git reference available for this buffer', 'warn')
    return
  end
  local copied = pcall(function()
    vim.fn.setreg('+', reference)
  end)
  if not copied then
    pcall(vim.fn.setreg, '"', reference)
  end
  notify('Copied: ' .. reference, 'info')
end

-- Mapping helpers ------------------------------------------------------------

---@param mode string|string[]
---@param lhs string
---@param rhs function
---@param desc string
local function map(mode, lhs, rhs, desc)
  pcall(vim.keymap.set, mode, lhs, rhs, { silent = true, noremap = true, desc = 'DSH: ' .. desc })
end

-- Buffer that the LSP maps currently being created belong to. LspAttach can fire
-- while another buffer is current, so `buffer = true` is not good enough.
local attach_buf = nil

---@param mode string|string[]
---@param lhs string
---@param rhs function
---@param desc string
local function map_buf(mode, lhs, rhs, desc)
  pcall(vim.keymap.set, mode, lhs, rhs, {
    silent = true,
    noremap = true,
    buffer = attach_buf or true,
    desc = 'DSH: ' .. desc,
  })
end

---Diagnostic jumps: `vim.diagnostic.jump` is the 0.11 API, goto_* the fallback.
---@param delta integer -1 for previous, 1 for next
local function diagnostic_jump(delta)
  local ok = pcall(function()
    if vim.diagnostic and type(vim.diagnostic.jump) == 'function' then
      vim.diagnostic.jump({ count = delta, float = true })
      return
    end
    if delta < 0 then
      vim.diagnostic.goto_prev({ float = true })
    else
      vim.diagnostic.goto_next({ float = true })
    end
  end)
  if not ok then
    notify('Diagnostic navigation is unavailable', 'warn')
  end
end

---Format the current buffer through whichever formatter is available.
local function format_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok = pcall(function()
    vim.lsp.buf.format({ bufnr = bufnr, async = true, timeout_ms = 3000 })
  end)
  if ok then
    return
  end
  -- No LSP formatter: fall back to a configured gq-based reformat.
  local util_ok, util = pcall(require, 'dshstudio.util')
  local msg = 'No formatter attached to this buffer'
  if util_ok and type(util) == 'table' and type(util.notify) == 'function' then
    pcall(util.notify, msg, 'info')
  else
    notify(msg, 'info')
  end
end

---Buffer-local LSP mappings (registered from LspAttach).
---@param buf integer
local function attach_lsp_maps(buf)
  attach_buf = buf
  map_buf('n', 'gd', function()
    lsp('definition')
  end, 'Go to definition')
  map_buf('n', 'gD', function()
    lsp('declaration')
  end, 'Go to declaration')
  map_buf('n', 'gi', function()
    lsp('implementation')
  end, 'Go to implementation')
  map_buf('n', 'gr', function()
    lsp('references')
  end, 'Go to references')
  map_buf('n', 'K', function()
    lsp('hover')
  end, 'Hover documentation')
  map_buf('n', '<C-k>', function()
    lsp('signature_help')
  end, 'Signature help')
  map_buf('n', '[d', function()
    diagnostic_jump(-1)
  end, 'Previous diagnostic')
  map_buf('n', ']d', function()
    diagnostic_jump(1)
  end, 'Next diagnostic')
  map_buf('n', '<leader>rn', function()
    lsp('rename')
  end, 'Rename symbol')
  map_buf({ 'n', 'x' }, '<leader>ca', function()
    lsp('code_action')
  end, 'Code action')
  map_buf({ 'n', 'x' }, '<leader>f', function()
    format_buffer()
  end, 'Format buffer')
  -- Keep a marker handy for other modules (statusline, sidebar).
  pcall(function()
    vim.b[buf].dshstudio_lsp_mapped = true
  end)
end

---Install every keymap. Re-runnable: vim.keymap.set overwrites in place.
---@return nil
function M.setup()
  local config_ok, config = pcall(require, 'dshstudio.config')
  if config_ok and type(config) == 'table' and type(config.get) == 'function' then
    local enabled = true
    pcall(function()
      enabled = config.get('keymaps', true)
    end)
    if enabled == false then
      return
    end
  end

  -- Space leader. Only claim it when nothing else has: an explicit user leader
  -- must win (it is usually set in init.lua before this module loads).
  pcall(function()
    if vim.g.mapleader == nil or vim.g.mapleader == '' or vim.g.mapleader == '\\' then
      vim.g.mapleader = ' '
    end
    if vim.g.maplocalleader == nil or vim.g.maplocalleader == '' or vim.g.maplocalleader == '\\' then
      vim.g.maplocalleader = ' '
    end
  end)

  -- File / buffer navigation -------------------------------------------------
  map('n', '<leader>e', function()
    try_list({
      { 'dshstudio.ui.tree', 'toggle' },
      { 'dshstudio.ui.filetree', 'toggle' },
      { 'dshstudio.ui.explorer', 'toggle' },
    })
  end, 'Toggle file tree')
  map('n', '<leader>ff', function()
    telescope('find_files')
  end, 'Find files')
  map('n', '<leader>fg', function()
    telescope('live_grep')
  end, 'Live grep')
  map('n', '<leader>fb', function()
    telescope('buffers')
  end, 'Find buffers')
  map('n', '<leader>fs', function()
    telescope('lsp_document_symbols')
  end, 'Document symbols')
  map('n', '<leader>fw', function()
    telescope({ 'lsp_dynamic_workspace_symbols', 'lsp_workspace_symbols' })
  end, 'Workspace symbols')
  map('n', '<leader>o', function()
    try_list({
      { 'dshstudio.ui.outline', 'toggle' },
      { 'dshstudio.ui.symbols', 'toggle' },
    })
  end, 'Toggle symbol outline')

  -- DSH agent ---------------------------------------------------------------
  map('n', '<leader>dd', function()
    try_list({
      { 'dshstudio.core.session', 'toggle' },
      { 'dshstudio.ui.sidebar', 'toggle' },
    })
  end, 'Toggle DSH sidebar')
  map('n', '<leader>da', function()
    ask_with_context('buffer')
  end, 'Ask DSH with buffer context')
  map('x', '<leader>da', function()
    -- Leave visual mode first so the '< / '> marks are final.
    pcall(vim.cmd, 'normal! \27')
    ask_with_context('selection')
  end, 'Ask DSH with selection')
  map('n', '<leader>dp', function()
    try_list({
      { 'dshstudio.project.analysis', 'menu' },
      { 'dshstudio.project.analysis', 'open' },
      { 'dshstudio.project.analysis', 'run' },
    })
  end, 'Project deep analysis')
  map('n', '<leader>dm', function()
    try_list({
      { 'dshstudio.ui.sidebar', 'pick_model' },
      { 'dshstudio.core.session', 'pick_model' },
    })
  end, 'Pick model')
  map('n', '<leader>dc', function()
    try_list({
      { 'dshstudio.core.session', 'clear' },
      { 'dshstudio.ui.sidebar', 'clear' },
    })
  end, 'Clear conversation')
  map('n', '<leader>dn', function()
    try_list({
      { 'dshstudio.ui.sidebar', 'new_session' },
      { 'dshstudio.core.session', 'new_session' },
      { 'dshstudio.core.session', 'new' },
    })
  end, 'New session')
  map('n', '<leader>dq', function()
    try_list({
      { 'dshstudio.core.session', 'cancel' },
    })
  end, 'Cancel the running turn')
  map('n', '<leader>de', function()
    try_list({
      { 'dshstudio.ui.sidebar', 'pick_effort' },
    })
  end, 'Pick reasoning effort')
  map('n', '<leader>di', function()
    try_list({
      { 'dshstudio.ui.sidebar', 'insert_last_reply' },
    })
  end, 'Insert the last reply')
  map('n', '<leader>dy', function()
    try_list({
      { 'dshstudio.ui.sidebar', 'copy_last_reply' },
    })
  end, 'Copy the last reply')
  map('n', '<leader>dS', function()
    local ok, probe = pcall(require, 'dshstudio.tests.probe')
    if not ok then
      vim.notify('self-test module unavailable: ' .. tostring(probe), vim.log.levels.ERROR)
      return
    end
    probe.run_all()
  end, 'Run offline self-tests')
  map('n', '<leader>dH', function()
    vim.cmd('DshHealth')
  end, 'Environment health report')
  map('n', '<leader>dk', function()
    try_list({
      { 'dshstudio.core.auth', 'manage' },
    })
  end, 'Manage model providers / API keys')
  map('n', '<leader>dw', function()
    try_list({
      { 'dshstudio.core.session', 'pick_workspace' },
    })
  end, 'Choose the agent workspace (project directory)')
  map('n', '<leader>dK', function()
    local ok, auth = pcall(require, 'dshstudio.core.auth')
    if not ok then
      vim.notify('auth module unavailable: ' .. tostring(auth), vim.log.levels.ERROR)
      return
    end
    local providers = auth.providers()
    if #providers == 0 then
      vim.notify('no providers advertised yet — open the panel once (<leader>dd)', vim.log.levels.WARN)
      return
    end
    local lines = {}
    for _, p in ipairs(providers) do
      lines[#lines + 1] = ('%s: key %s (%s), %d models'):format(
        p.label or p.provider, p.key_set and 'SET' or 'missing', p.key_source or '-', #p.models)
    end
    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'DSH providers' })
  end, 'Provider and key status')

  -- Outline and project tree ------------------------------------------------
  map('n', '<leader>ot', function()
    try_list({
      { 'dshstudio.ui.project_tree', 'toggle' },
      { 'dshstudio.ui.outline', 'project_symbols' },
    })
  end, 'Project symbol tree')
  map('n', '<leader>op', function()
    try_list({
      { 'dshstudio.ui.project_tree', 'pick' },
      { 'dshstudio.ui.outline', 'pick' },
    })
  end, 'Pick a symbol')
  map('n', '<leader>or', function()
    try_list({
      { 'dshstudio.ui.project_tree', 'refresh' },
      { 'dshstudio.ui.outline', 'refresh' },
    })
  end, 'Refresh the outline / re-index')

  -- Git ---------------------------------------------------------------------
  map({ 'n', 'x' }, '<leader>gy', function()
    copy_git_reference()
  end, 'Copy git reference')

  -- LSP (global; the buffer-local set in LspAttach takes over where relevant) --
  map('n', '<leader>rn', function()
    lsp('rename')
  end, 'Rename symbol')
  map({ 'n', 'x' }, '<leader>ca', function()
    lsp('code_action')
  end, 'Code action')
  map('n', '<leader>gd', function()
    lsp('definition')
  end, 'Go to definition')
  map('n', '<leader>gD', function()
    lsp('declaration')
  end, 'Go to declaration')
  map('n', '<leader>gi', function()
    lsp('implementation')
  end, 'Go to implementation')
  map('n', '<leader>gr', function()
    lsp('references')
  end, 'Go to references')
  map('n', '<leader>k', function()
    lsp('hover')
  end, 'Hover documentation')
  -- NOTE: <leader>f is a prefix of <leader>ff/fg/fb/fs/fw, so it only fires after
  -- 'timeoutlen' (400ms). <leader>fm is the unambiguous alias.
  map({ 'n', 'x' }, '<leader>f', function()
    format_buffer()
  end, 'Format buffer')
  map({ 'n', 'x' }, '<leader>fm', function()
    format_buffer()
  end, 'Format buffer (alias)')

  -- Buffer-local LSP maps ---------------------------------------------------
  local group = vim.api.nvim_create_augroup('DshStudioKeymaps', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      pcall(attach_lsp_maps, args.buf)
    end,
    desc = 'DSH Studio: buffer-local LSP keymaps',
  })

  -- Servers already attached before this autocmd existed (config reload).
  pcall(function()
    -- `vim.lsp` is lazily loaded and can fail while the runtime path is still
    -- being assembled; without this guard the whole config errors out.
    local ok_lsp, lsp = pcall(require, 'vim.lsp')
    if not ok_lsp or type(lsp) ~= 'table' or type(lsp.get_clients) ~= 'function' then return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and #lsp.get_clients({ bufnr = buf }) > 0 then
        attach_lsp_maps(buf)
      end
    end
  end)
end

---Expose the helpers so other modules (and tests) can reuse the guarded calls.
M.try = try
M.try_list = try_list

return M
