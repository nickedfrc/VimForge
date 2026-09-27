-- dshstudio/ui/calltree.lua
--
-- Browseable program tree for a file or a folder.
--
-- Two views share one panel, because "analyse the program tree" means different
-- things and the user should not have to guess which command to reach:
--
--   calls  the call hierarchy around a root symbol: `calls` expands downward
--          (what it invokes) and `called_by` upward (what invokes it), which is
--          how a subroutine's role in a program becomes visible.
--   symbols the declaration tree: modules, types, subroutines and functions,
--          nested by containment.
--
-- The target is a path the caller chooses, so a single file or a whole folder can
-- be analysed rather than only the current workspace.

local M = {}

local S = {
  buf = nil,
  win = nil,
  open = false,
  mode = 'calls',       -- 'calls' | 'symbols'
  root_name = nil,
  target = nil,
  rows = {},            -- rendered row -> entry
  expanded = {},        -- node key -> true
  graph = nil,
  symbols = nil,        -- { [rel] = list }
  files = nil,          -- rel -> absolute path
  loading = false,
}

local MAX_CHILDREN = 200

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

local function notify(message, level)
  pcall(util().notify, message, level)
end

-- ---------------------------------------------------------------------------
-- Data collection
-- ---------------------------------------------------------------------------

---Collect symbols and a call graph for a file or a directory.
---@param target string  absolute path to a file or a directory
---@param on_done fun(ok:boolean, err:string|nil)
function M.build(target, on_done)
  on_done = on_done or function() end
  target = vim.fn.fnamemodify(target, ':p'):gsub('/$', '')

  local ok_scan, scan = pcall(require, 'dshstudio.project.scan')
  local ok_sym, symbols_mod = pcall(require, 'dshstudio.project.symbols')
  local ok_static, static = pcall(require, 'dshstudio.project.static')
  if not (ok_scan and ok_sym and ok_static) then
    return false, 'project analysis modules are unavailable'
  end

  local scan_result
  if vim.fn.isdirectory(target) == 1 then
    scan_result = scan.collect(target, { max_files = 3000 })
  else
    -- A single file: present it as a one-entry scan so every later stage works
    -- the same way for both targets.
    local rel = vim.fn.fnamemodify(target, ':t')
    local lang = scan.lang_for and scan.lang_for(target, rel) or 'other'
    local lines = vim.fn.readfile(target)
    scan_result = {
      root = vim.fn.fnamemodify(target, ':h'),
      files = { { path = target, rel = rel, lang = lang, ext = vim.fn.fnamemodify(target, ':e'),
        bytes = vim.fn.getfsize(target), lines = #lines } },
      by_lang = { [lang] = { count = 1, bytes = 0, lines = #lines } },
      skipped = 0, truncated = false,
    }
  end

  local by_file = {}
  local paths = {}
  for _, f in ipairs(scan_result.files or {}) do
    local list = symbols_mod.extract_file(f.path, f.lang)
    by_file[f.rel] = list or {}
    paths[f.rel] = f.path
  end

  local deps = static.all_deps(scan_result)
  local done = false
  local graph = nil
  static.call_graph(deps, by_file, function(g)
    graph = g
    done = true
  end)
  -- call_graph may complete asynchronously; give it a bounded chance to land.
  if not done then vim.wait(20000, function() return done end, 100) end

  S.graph = graph or {}
  S.symbols = by_file
  S.files = paths
  S.target = target
  S.expanded = {}
  on_done(true, nil)
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t or {}) do
    if type(k) == 'string' then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

---Roots for the call view: symbols that nothing in this target calls, plus the
---most-called symbols, so a file with no clear entry point is still useful.
---@return string[]
local function call_roots()
  local graph = S.graph or {}
  local roots, fallback = {}, {}
  for name, entry in pairs(graph) do
    local called_by = entry.called_by or {}
    if #called_by == 0 then
      roots[#roots + 1] = name
    end
    fallback[#fallback + 1] = name
  end
  table.sort(roots)
  table.sort(fallback)
  if #roots > 0 then return roots end
  return fallback
end

local function render_call_node(name, depth, lines, rows, seen)
  local entry = (S.graph or {})[name] or {}
  local key = name
  local margin = string.rep('  ', depth)
  local marker = S.expanded[key] and '▾' or '▸'
  local calls = entry.calls or {}
  local called_by = entry.called_by or {}
  local note = ''
  if #calls > 0 or #called_by > 0 then
    note = ('  (→%d ←%d)'):format(#calls, #called_by)
  end
  table.insert(lines, ('%s%s %s%s'):format(margin, marker, name, note))
  rows[#lines] = { kind = 'call', name = name }
  if not S.expanded[key] then return end
  if seen[name] then
    table.insert(lines, ('%s    (cycle)'):format(margin))
    return
  end
  seen[name] = true

  if #called_by > 0 then
    table.insert(lines, ('%s  called by:'):format(margin))
    for i, caller in ipairs(called_by) do
      if i > MAX_CHILDREN then
        table.insert(lines, ('%s    … %d more'):format(margin, #called_by - MAX_CHILDREN))
        break
      end
      table.insert(lines, ('%s    ← %s'):format(margin, caller))
      rows[#lines] = { kind = 'call', name = caller }
    end
  end
  if #calls > 0 then
    table.insert(lines, ('%s  calls:'):format(margin))
    for i, callee in ipairs(calls) do
      if i > MAX_CHILDREN then
        table.insert(lines, ('%s    … %d more'):format(margin, #calls - MAX_CHILDREN))
        break
      end
      render_call_node(callee, depth + 2, lines, rows, seen)
    end
  end
  seen[name] = nil
end

local function render_symbol_node(list, parent, depth, lines, rows)
  for _, sym in ipairs(list or {}) do
    local sym_parent = sym.parent
    local matches = (parent == nil and (sym_parent == nil or sym_parent == ''))
      or (parent ~= nil and sym_parent == parent)
    if matches then
      local kind = sym.kind or 'symbol'
      local line = tonumber(sym.line) or 0
      local key = ('%s:%s:%d'):format(tostring(parent), sym.name, line)
      local margin = string.rep('  ', depth)
      table.insert(lines, ('%s%s  %s  L%d'):format(margin, kind, sym.name, line))
      rows[#lines] = { kind = 'symbol', sym = sym }
      render_symbol_node(list, sym.name, depth + 1, lines, rows)
    end
  end
end

function M.render()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  local lines, rows = {}, {}
  local target_label = S.target and vim.fn.fnamemodify(S.target, ':t') or '(no target)'

  table.insert(lines, ('  %s   [%s]'):format(target_label, S.mode))
  table.insert(lines, ('  %s'):format(vim.fn.fnamemodify(S.target or '', ':~')))
  table.insert(lines, '')
  table.insert(lines, '  Tab: calls/symbols   Enter: expand or jump   r: reload   q: close')
  table.insert(lines, '')

  if S.loading then
    table.insert(lines, '  (analysing…)')
  elseif S.mode == 'calls' then
    local roots = call_roots()
    if #roots == 0 then
      table.insert(lines, '  (no calls found)')
      table.insert(lines, '  The call graph comes from static scanning; a target with')
      table.insert(lines, '  no detected calls may still have a symbol tree - press Tab.')
    else
      local seen = {}
      for _, name in ipairs(roots) do
        render_call_node(name, 0, lines, rows, seen)
      end
    end
  else
    local rels = sorted_keys(S.symbols)
    if #rels == 0 then
      table.insert(lines, '  (no symbols found)')
    end
    for _, rel in ipairs(rels) do
      table.insert(lines, ('▾ %s'):format(rel))
      rows[#lines] = { kind = 'file', rel = rel }
      render_symbol_node(S.symbols[rel], nil, 1, lines, rows)
      table.insert(lines, '')
    end
  end

  S.rows = rows
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(S.buf, vim.api.nvim_create_namespace('dshstudio.calltree'), 0, -1)
  vim.bo[S.buf].modifiable = false
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

---Jump to the file that defines a symbol.
---@param name string
local function jump_to_symbol(name)
  for rel, list in pairs(S.symbols or {}) do
    for _, sym in ipairs(list or {}) do
      if sym.name == name then
        local path = (S.files or {})[rel]
        if path and vim.fn.filereadable(path) == 1 then
          vim.cmd('edit ' .. vim.fn.fnameescape(path))
          pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, tonumber(sym.line) or 1), 0 })
          vim.cmd('normal! zz')
          return true
        end
      end
    end
  end
  return false
end

local function activate()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = S.rows[row]
  if not entry then return end
  if entry.kind == 'call' then
    S.expanded[entry.name] = not S.expanded[entry.name]
    M.render()
  elseif entry.kind == 'symbol' then
    if not jump_to_symbol(entry.sym.name) then
      notify('could not locate ' .. tostring(entry.sym.name), vim.log.levels.WARN)
    end
  elseif entry.kind == 'file' then
    local path = (S.files or {})[entry.rel]
    if path then vim.cmd('edit ' .. vim.fn.fnameescape(path)) end
  end
end

local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then return S.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  S.buf = buf
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'dshstudio_calltree'
  vim.api.nvim_buf_set_name(buf, 'dsh://program-tree')

  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map('<CR>', activate, 'Expand, or jump to the definition')
  map('<Tab>', function()
    S.mode = (S.mode == 'calls') and 'symbols' or 'calls'
    M.render()
  end, 'Switch between the call tree and the symbol tree')
  map('q', function() M.close() end, 'Close')
  map('r', function()
    if S.target then
      S.loading = true
      M.render()
      M.build(S.target, function(ok, err)
        S.loading = false
        if not ok then notify(tostring(err), vim.log.levels.ERROR) end
        M.render()
      end)
    end
  end, 'Re-analyse')
  map('g?', function()
    notify('Enter expand/jump · Tab calls/symbols · r reload · q close', vim.log.levels.INFO)
  end, 'Help')

  vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, callback = function() S.buf = nil end })
  return buf
end

---Open the panel for a target and analyse it.
---@param target string|nil  defaults to the workspace
---@param mode string|nil    'calls' (default) or 'symbols'
function M.open(target, mode)
  target = target or (function()
    local ok, session = pcall(require, 'dshstudio.core.session')
    if ok and session.workspace then return session.workspace() end
    return vim.fn.getcwd()
  end)()

  if M.is_open() then
    vim.api.nvim_set_current_win(S.win)
  else
    vim.cmd('botright vertical new')
    local win = vim.api.nvim_get_current_win()
    S.win = win
    vim.api.nvim_win_set_buf(win, ensure_buf())
    vim.api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.5)))
    pcall(vim.api.nvim_set_option_value, 'number', false, { win = win })
    pcall(vim.api.nvim_set_option_value, 'relativenumber', false, { win = win })
    pcall(vim.api.nvim_set_option_value, 'signcolumn', 'no', { win = win })
    pcall(vim.api.nvim_set_option_value, 'wrap', false, { win = win })
    pcall(vim.api.nvim_set_option_value, 'winbar', '%#DshSidebarBar# Program tree %= Tab switches view ', { win = win })
    S.open = true
  end

  -- Default to the call view for a fresh target. Inheriting the previous view made
  -- `:DshTree <file>` show the symbol tree just because a symbol view had been
  -- used earlier, which is invisible state the user cannot account for.
  S.mode = mode or 'calls'
  S.loading = true
  M.render()
  M.build(target, function(ok, err)
    S.loading = false
    if not ok then
      notify('analysis failed: ' .. tostring(err), vim.log.levels.ERROR)
    else
      local calls = 0
      for _ in pairs(S.graph or {}) do calls = calls + 1 end
      notify(('program tree: %d symbols, %d call-graph nodes  (Tab switches view)'):format(
        (function()
          local n = 0
          for _, list in pairs(S.symbols or {}) do n = n + #(list or {}) end
          return n
        end)(), calls), vim.log.levels.INFO)
      -- Expand the first roots so the panel opens with content visible.
      local roots = call_roots()
      for i = 1, math.min(3, #roots) do S.expanded[roots[i]] = true end
    end
    M.render()
  end)
end

function M.close()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  S.win = nil
  S.open = false
end

function M.is_open()
  return S.open and S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
end

function M.toggle(target, mode)
  if M.is_open() then M.close() else M.open(target, mode) end
end

---Ask for a file or folder, then analyse it.
function M.pick_target()
  local start = (function()
    local ok, session = pcall(require, 'dshstudio.core.session')
    if ok and session.workspace then return session.workspace() end
    return vim.fn.getcwd()
  end)()
  vim.ui.input({ prompt = 'File or folder to analyse: ', default = start .. '/', completion = 'file' },
    function(input)
      if not input or input == '' then return end
      local resolved = vim.fn.fnamemodify(vim.fn.expand(input), ':p')
      resolved = resolved:gsub('/$', '')
      if vim.fn.isdirectory(resolved) == 0 and vim.fn.filereadable(resolved) == 0 then
        notify('not found: ' .. resolved, vim.log.levels.ERROR)
        return
      end
      M.open(resolved)
    end)
end

---Analyse the current file.
function M.current_file()
  local name = vim.api.nvim_buf_get_name(0)
  if name == '' then
    notify('this buffer has no file; save it first or use :DshTree <path>', vim.log.levels.WARN)
    return
  end
  M.open(name)
end

---Analyse the folder the current file lives in, or the workspace when unnamed.
function M.current_folder()
  local name = vim.api.nvim_buf_get_name(0)
  if name == '' then
    M.open()
    return
  end
  local ok, session = pcall(require, 'dshstudio.core.session')
  local dir = vim.fn.fnamemodify(name, ':p:h')
  if ok and session.detect_workspace_root then
    dir = session.detect_workspace_root(dir)
  end
  M.open(dir)
end

return M
