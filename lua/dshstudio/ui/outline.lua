-- dshstudio/ui/outline.lua
--
-- Symbol outline: the subroutine/function list the editor is expected to show.
--
-- Sources, best first:
--   1. LSP `textDocument/documentSymbol` for the active buffer (accurate ranges,
--      nesting, and kind information)
--   2. the offline extractor in `dshstudio.project.symbols` (regex/tree-sitter),
--      which also covers Fortran projects with no language server running
--
-- Opens as a left-hand split sharing the file-tree slot, and folds by depth so
-- a large module still reads as a tree.

local M = {}

local S = {
  win = nil,
  buf = nil,
  open = false,
  entries = {},   -- flat render rows: { depth, name, kind, line, end_line, file }
  rows = {},      -- row (1-based) -> entry
  source = '',
}

local FUNCTION_LIKE = {
  [6] = true,  -- Method
  [9] = true,  -- Constructor
  [12] = true, -- Function
}

local KIND_LABEL = {
  [1] = 'File', [2] = 'Module', [3] = 'Namespace', [4] = 'Package', [5] = 'Class',
  [6] = 'Method', [7] = 'Property', [8] = 'Field', [9] = 'Ctor', [10] = 'Enum',
  [11] = 'Interface', [12] = 'Function', [13] = 'Var', [14] = 'Const', [15] = 'String',
  [16] = 'Number', [17] = 'Bool', [18] = 'Array', [19] = 'Object', [20] = 'Key',
  [21] = 'Null', [22] = 'EnumMember', [23] = 'Struct', [24] = 'Event', [25] = 'Operator',
  [26] = 'TypeParam',
}

local KIND_ICON = {
  Module = '▣', Namespace = '▣', Package = '▣', Class = '◆', Struct = '◆',
  Interface = '◇', Enum = '◇', TypeParam = '◇', Function = 'ƒ', Method = 'ƒ',
  Ctor = 'ƒ', subroutine = 'ƒ', ['function'] = 'ƒ', program = '▶', type = '◆',
  procedure = 'ƒ', macro = '#',
}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

local function config()
  local ok, mod = pcall(require, 'dshstudio.config')
  if ok and mod.get then return mod end
  return { get = function(_, default) return default end }
end

-- ---------------------------------------------------------------------------
-- Collecting symbols
-- ---------------------------------------------------------------------------

---LSP document symbols for a buffer, flattened into rows.
---
---Uses the asynchronous request API with a deadline rather than
---`vim.lsp.buf_request_sync`, which can park Neovim's main loop indefinitely
---(observed on 0.12: a headless run hung forever). A hang here would freeze the
---editor every time the outline refreshed.
---@param bufnr integer
---@return table[]|nil
local function from_lsp(bufnr)
  -- `vim.lsp` is lazily loaded and can fail to load while the runtime path is
  -- still being assembled (observed from a release-bundle config directory). The
  -- offline extractor below is the fallback, so a failure here is recoverable.
  local ok_mod, lsp = pcall(require, 'vim.lsp')
  if not ok_mod or type(lsp) ~= 'table' then return nil end
  if type(lsp.get_clients) ~= 'function' or type(lsp.buf_request_all) ~= 'function' then return nil end

  local ok, clients = pcall(lsp.get_clients, { bufnr = bufnr })
  if not ok or type(clients) ~= 'table' or #clients == 0 then return nil end

  local done = false
  local responses = nil
  local requested = pcall(lsp.buf_request_all, bufnr, 'textDocument/documentSymbol', {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, function(results)
    responses = results
    done = true
  end)
  if not requested then return nil end
  pcall(vim.wait, 800, function() return done end, 10)
  if not done or type(responses) ~= 'table' then return nil end

  local out = {}
  local function walk(nodes, depth)
    if depth > 6 then return end
    for _, node in ipairs(nodes or {}) do
      local range = node.range
      if not range and node.location then range = node.location.range end
      local line = range and (range.start.line + 1) or 0
      local end_line = range and range['end'] and (range['end'].line + 1) or line
      local label = KIND_LABEL[node.kind] or 'Symbol'
      table.insert(out, {
        depth = depth,
        name = node.name or '?',
        kind = label,
        line = line,
        end_line = end_line,
        is_function = FUNCTION_LIKE[node.kind] == true,
      })
      if node.children then walk(node.children, depth + 1) end
    end
  end
  for _, entry in pairs(responses) do
    -- buf_request_all yields { [client_id] = { err = ..., result = ... } }.
    local result = entry and (entry.result or entry)
    if type(result) == 'table' then walk(result, 0) end
  end
  if #out == 0 then return nil end
  return out
end

---Offline extraction for the buffer.
---@param bufnr integer
---@return table[]|nil
local function from_offline(bufnr)
  local ok, symbols = pcall(require, 'dshstudio.project.symbols')
  if not ok or not symbols.extract_file then return nil end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then return nil end
  local ft = vim.bo[bufnr].filetype
  local lang = ({ cpp = 'cpp', c = 'c', python = 'python', fortran = 'fortran', lua = 'lua' })[ft]
  if not lang then return nil end
  local list = symbols.extract_file(path, lang)
  if type(list) ~= 'table' or #list == 0 then return nil end

  local out = {}
  local by_parent = {}
  for _, sym in ipairs(list) do
    by_parent[sym.parent or ''] = by_parent[sym.parent or ''] or {}
    table.insert(by_parent[sym.parent or ''], sym)
  end
  local function walk(parent, depth)
    if depth > 6 then return end
    for _, sym in ipairs(by_parent[parent] or {}) do
      table.insert(out, {
        depth = depth,
        name = sym.name,
        kind = sym.kind or 'symbol',
        line = sym.line or 0,
        end_line = sym.end_line or sym.line or 0,
        is_function = sym.kind == 'subroutine' or sym.kind == 'function'
          or sym.kind == 'procedure' or sym.kind == 'method',
        signature = sym.signature,
      })
      walk(sym.name, depth + 1)
    end
  end
  -- Anything without a resolvable parent starts the walk.
  walk('', 0)
  local seen = {}
  for _, e in ipairs(out) do seen[e.name] = true end
  -- Orphaned children (parent name not present) are appended flat.
  for _, sym in ipairs(list) do
    if sym.parent and sym.parent ~= '' and not seen[sym.parent] then
      table.insert(out, {
        depth = 1, name = sym.name, kind = sym.kind or 'symbol',
        line = sym.line or 0, is_function = true,
      })
    end
  end
  table.sort(out, function(a, b) return (a.line or 0) < (b.line or 0) end)
  if #out == 0 then return nil end
  return out
end

---Refresh the outline for a buffer (or the current one).
---@param bufnr integer|nil
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local entries = from_lsp(bufnr)
  local source = 'lsp'
  if not entries then
    entries = from_offline(bufnr)
    source = 'offline'
  end
  S.entries = entries or {}
  S.source = entries and source or 'none'
  S.bufnr = bufnr
  if S.open then M.render() end
  return S.entries
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function render_lines()
  local rows = {}
  local lines = {}
  local file = vim.api.nvim_buf_get_name(S.bufnr or 0)
  table.insert(lines, ('  %s  [%s]'):format(vim.fn.fnamemodify(file, ':t'), S.source))
  table.insert(lines, '')
  for _, entry in ipairs(S.entries) do
    local icon = KIND_ICON[entry.kind] or '·'
    local indent = string.rep('  ', entry.depth)
    local sig = entry.signature and ('  ' .. entry.signature:sub(1, 60)) or ''
    table.insert(lines, ('%s%s %s  %s:%d%s'):format(indent, icon, entry.name, entry.kind, entry.line, sig))
    rows[#lines] = entry
  end
  if #S.entries == 0 then
    table.insert(lines, '  (no symbols found)')
    table.insert(lines, '  Is a language server running?')
    table.insert(lines, '  Try :DshHealth')
  end
  return lines, rows
end

local ns = vim.api.nvim_create_namespace('dshstudio.outline')

function M.render()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  local lines, rows = render_lines()
  S.rows = rows
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for row, entry in pairs(rows) do
    local group = entry.is_function and 'Function' or 'Identifier'
    pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, group, row - 1, 0, -1)
    if entry.line and entry.line > 0 then
      pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, 'LineNr', row - 1, 0, #(lines[row] or ''))
    end
  end
  vim.bo[S.buf].modifiable = false
  -- Fold by indentation depth.
  vim.wo[S.win].foldmethod = 'indent'
  vim.wo[S.win].foldlevel = 1
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then return S.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  S.buf = buf
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'dshstudio_outline'
  vim.api.nvim_buf_set_name(buf, 'dsh://outline')

  local function jump()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local entry = S.rows[row]
    if not entry then return end
    local target_buf = S.bufnr
    if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
      util().notify('the source buffer is gone', vim.log.levels.WARN)
      return
    end
    -- Prefer the file-tree window if present, else the previous window.
    vim.api.nvim_set_current_buf(target_buf)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, entry.line or 1), 0 })
    vim.cmd('normal! zz')
  end

  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map('<CR>', jump, 'Jump to symbol')
  map('<Tab>', jump, 'Jump to symbol')
  map('o', jump, 'Jump to symbol')
  map('q', function() M.close() end, 'Close outline')
  map('r', function()
    M.refresh(S.bufnr)
    util().notify('outline refreshed', vim.log.levels.INFO)
  end, 'Refresh')
  map('p', function() M.pick() end, 'Fuzzy pick')
  map('g?', function()
    util().notify('CR/o jump · r refresh · p fuzzy pick · q close · [f filter functions only',
      vim.log.levels.INFO)
  end, 'Help')
  map('[f', function()
    local entries = {}
    for _, e in ipairs(S.entries) do
      if e.is_function then table.insert(entries, e) end
    end
    S.entries = entries
    S.source = S.source .. ' (functions)'
    M.render()
  end, 'Functions only')

  vim.api.nvim_create_autocmd({ 'BufWipeout' }, {
    buffer = buf,
    callback = function() S.buf = nil end,
  })
  return buf
end

function M.open_panel()
  if M.is_open() then
    vim.api.nvim_set_current_win(S.win)
    return
  end
  local width = tonumber(config().get('outline_width')) or 34
  vim.cmd('topleft vertical new')
  local win = vim.api.nvim_get_current_win()
  S.win = win
  vim.api.nvim_win_set_buf(win, ensure_buf())
  vim.api.nvim_win_set_width(win, width)
  pcall(vim.api.nvim_set_option_value, 'number', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'relativenumber', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'signcolumn', 'no', { win = win })
  pcall(vim.api.nvim_set_option_value, 'cursorline', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'wrap', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'winfixwidth', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'foldcolumn', '1', { win = win })
  pcall(vim.api.nvim_set_option_value, 'winbar', '%#DshSidebarBar# Outline %= ', { win = win })
  S.open = true

  -- Follow buffer switches and LSP updates while the panel is visible.
  local group = vim.api.nvim_create_augroup('DshOutline', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group = group,
    callback = function()
      if not M.is_open() then return end
      local buf = vim.api.nvim_get_current_buf()
      if buf == S.buf then return end
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client:supports_method('textDocument/documentSymbol') then
        vim.api.nvim_buf_attach(args.buf, false, {
          on_lines = function()
            if not M.is_open() or S.bufnr ~= args.buf then return end
            if S.debounce then return end
            S.debounce = true
            vim.defer_fn(function()
              S.debounce = false
              if M.is_open() and S.bufnr == args.buf then M.refresh(args.buf) end
            end, 700)
          end,
        })
      end
    end,
  })

  M.refresh(vim.api.nvim_get_current_buf())
  M.render()
end

function M.close()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  S.win = nil
  S.open = false
  pcall(vim.api.nvim_del_augroup_by_name, 'DshOutline')
end

function M.is_open()
  return S.open and S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
end

function M.toggle()
  if M.is_open() then M.close() else M.open_panel() end
end

---Fuzzy-pick a symbol from the current file, jumping to it.
function M.pick()
  local bufnr = vim.api.nvim_get_current_buf()
  if S.buf and bufnr == S.buf then
    bufnr = S.bufnr or bufnr
  end
  local entries = from_lsp(bufnr) or from_offline(bufnr) or {}
  if #entries == 0 then
    util().notify('no symbols in this file — is a language server running?', vim.log.levels.WARN)
    return
  end
  local target = bufnr
  vim.ui.select(entries, {
    prompt = 'Symbol',
    format_item = function(e)
      return ('%s%s  [%s] L%d'):format(string.rep('  ', e.depth), e.name, e.kind, e.line or 0)
    end,
  }, function(choice)
    if not choice then return end
    vim.api.nvim_set_current_buf(target)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, choice.line or 1), 0 })
    vim.cmd('normal! zz')
  end)
end

---Pick a symbol across the whole project using the offline extractor.
---Runs in chunks so a large tree stays responsive.
function M.project_symbols()
  local scan = select(1, pcall(require, 'dshstudio.project.scan'))
  local symbols = select(1, pcall(require, 'dshstudio.project.symbols'))
  if not scan or not symbols then
    util().notify('project symbol support unavailable', vim.log.levels.ERROR)
    return
  end
  local root = nil
  if scan.detect_root then root = scan.detect_root(vim.fn.getcwd()) end
  root = root or vim.fn.getcwd()
  util().notify('indexing project symbols under ' .. root .. ' …', vim.log.levels.INFO)
  local result = scan.collect(root, { max_files = 2000 })
  local flat = {}
  local by_file = {}
  for _, file in ipairs(result.files or {}) do
    local lang = file.lang
    if lang == 'fortran' or lang == 'c' or lang == 'cpp' or lang == 'python' or lang == 'lua' then
      local list = symbols.extract_file(file.path, lang)
      for _, sym in ipairs(list or {}) do
        table.insert(flat, {
          name = sym.name, kind = sym.kind, line = sym.line,
          file = file.rel, path = file.path,
        })
      end
      by_file[file.rel] = true
    end
  end
  if #flat == 0 then
    util().notify('no symbols indexed', vim.log.levels.WARN)
    return
  end
  vim.ui.select(flat, {
    prompt = ('Project symbols (%d in %d files)'):format(#flat, vim.tbl_count(by_file)),
    format_item = function(e)
      return ('%s  %s  [%s] %s:%d'):format(e.kind or '?', e.name, e.kind or '?', e.file, e.line or 0)
    end,
  }, function(choice)
    if not choice then return end
    vim.cmd('edit ' .. vim.fn.fnameescape(choice.path))
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, choice.line or 1), 0 })
    vim.cmd('normal! zz')
  end)
end

---Refresh when the panel is open (hook used by other modules).
function M.maybe_refresh()
  if M.is_open() then M.refresh(vim.api.nvim_get_current_buf()) end
end

return M
