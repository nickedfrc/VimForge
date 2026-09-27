-- dshstudio/ui/project_tree.lua
--
-- Project-wide symbol tree: directories -> files -> declared symbols.
--
-- The outline panel answers "what is in this file"; this answers "what is in
-- this project", which is the tree view Fortran and mixed C/Fortran projects
-- need because a subroutine's home is rarely obvious from the file list.
--
-- Symbol extraction is the offline extractor, so the tree works with no language
-- server. Indexing runs in chunks on the event loop so a large tree never blocks
-- the UI, and results are cached per root until asked to refresh.

local M = {}

local uv = vim.uv or vim.loop

local ns = vim.api.nvim_create_namespace('dshstudio.project_tree')

local S = {
  win = nil,
  buf = nil,
  open = false,
  root = nil,
  rows = {},        -- display row (1-based) -> entry
  folded = {},      -- rel path -> true when collapsed
  index = nil,      -- cached { tree = ..., files = n, symbols = n, at = time }
}

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

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
-- Indexing
-- ---------------------------------------------------------------------------

local KIND_ICON = {
  module = '▣', program = '▶', subroutine = 'ƒ', ['function'] = 'ƒ',
  procedure = 'ƒ', interface = '◇', type = '◆', class = '◆', struct = '◆',
  method = 'ƒ', macro = '#', enum = '◇', union = '◆', namespace = '▣',
  global = '●',
}

local INDEXABLE = {
  fortran = true, c = true, cpp = true, python = true, lua = true,
}

---Build a nested tree { dirs = {name -> node}, files = { {name, path, rel, symbols} } }
---from a scan result, then extract symbols in chunked batches.
---@param root string
---@param opts { on_done:fun(index:table), on_progress:fun(done:integer, total:integer)|nil,
---              max_files:integer|nil, langs:table|nil }
function M.build_index(root, opts)
  opts = opts or {}
  local on_done = opts.on_done or function() end
  local scan = select(1, pcall(require, 'dshstudio.project.scan'))
  local symbols = select(1, pcall(require, 'dshstudio.project.symbols'))
  if not scan or not symbols then
    util().notify('project indexing unavailable (scan/symbols module missing)', vim.log.levels.ERROR)
    on_done(nil)
    return
  end

  local collected = scan.collect(root, { max_files = opts.max_files or 3000 })
  local files = {}
  for _, file in ipairs(collected.files or {}) do
    if INDEXABLE[file.lang] then table.insert(files, file) end
  end
  table.sort(files, function(a, b) return a.rel < b.rel end)

  local total = #files
  local extracted = 0
  local done = false

  local function assemble()
    local tree = { dirs = {}, files = {}, label = '' }
    local function dir_for(rel)
      local node = tree
      local parts = vim.split(rel, '/')
      -- Drop the file name; walk/create the directory chain.
      for i = 1, #parts - 1 do
        local name = parts[i]
        node.dirs[name] = node.dirs[name] or { dirs = {}, files = {}, label = name }
        node = node.dirs[name]
      end
      return node
    end
    for _, file in ipairs(files) do
      local node = dir_for(file.rel)
      table.insert(node.files, {
        name = vim.fn.fnamemodify(file.rel, ':t'),
        rel = file.rel,
        path = file.path,
        lang = file.lang,
        symbols = file.symbols or {},
      })
    end
    return tree
  end

  local timer = uv.new_timer()
  local cursor = 1
  local CHUNK = 12
  timer:start(0, 1, function()
    if done then return end
    local processed = 0
    while cursor <= total and processed < CHUNK do
      local file = files[cursor]
      cursor = cursor + 1
      processed = processed + 1
      local ok, list = pcall(symbols.extract_file, file.path, file.lang)
      file.symbols = ok and list or {}
      extracted = extracted + 1
    end
    if opts.on_progress then
      pcall(opts.on_progress, extracted, total)
    end
    if cursor > total then
      done = true
      timer:stop()
      timer:close()
      local tree = assemble()
      vim.schedule(function()
        on_done({
          root = root,
          tree = tree,
          file_count = total,
          symbol_count = (function()
            local n = 0
            for _, f in ipairs(files) do n = n + #(f.symbols or {}) end
            return n
          end)(),
          truncated = collected.truncated,
          at = os.time(),
        })
      end)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function render_node(node, prefix, depth, lines, rows, folded)
  -- Directories first, sorted; then files, sorted.
  local dir_names = vim.tbl_keys(node.dirs or {})
  table.sort(dir_names)
  for _, name in ipairs(dir_names) do
    local child = node.dirs[name]
    local child_rel = (prefix == '' and name or (prefix .. '/' .. name))
    local is_folded = folded[child_rel] == true
    local marker = is_folded and '▸' or '▾'
    local file_count = 0
    local function count_files(n)
      for _ in ipairs(n.files or {}) do file_count = file_count + 1 end
      for _, c in pairs(n.dirs or {}) do count_files(c) end
    end
    count_files(child)
    table.insert(lines, ('%s%s %s/  (%d)'):format(string.rep('  ', depth), marker, name, file_count))
    rows[#lines] = { kind = 'dir', rel = child_rel, label = name }
    if not is_folded then
      render_node(child, child_rel, depth + 1, lines, rows, folded)
    end
  end

  local files = node.files or {}
  for _, file in ipairs(files) do
    local is_folded = folded[file.rel] == true
    local marker = is_folded and '▸' or '▾'
    local n = #(file.symbols or {})
    table.insert(lines, ('%s%s %s  (%d)'):format(string.rep('  ', depth), marker, file.name, n))
    rows[#lines] = { kind = 'file', rel = file.rel, path = file.path, label = file.name }
    if not is_folded then
      for _, sym in ipairs(file.symbols or {}) do
        local icon = KIND_ICON[sym.kind] or '·'
        local parent = sym.parent and (sym.parent .. ' :: ') or ''
        table.insert(lines, ('%s    %s %s%s  L%d'):format(
          string.rep('  ', depth), icon, parent, sym.name, sym.line or 0))
        rows[#lines] = {
          kind = 'symbol', path = file.path, line = sym.line,
          label = sym.name, sym_kind = sym.kind,
        }
      end
    end
  end
end

function M.render()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  local lines = {}
  local rows = {}
  local index = S.index

  if not index then
    table.insert(lines, '  (indexing…)')
  else
    table.insert(lines, ('  %s'):format(vim.fn.fnamemodify(index.root, ':t')))
    table.insert(lines, ('  %d files · %d symbols%s'):format(
      index.file_count, index.symbol_count, index.truncated and ' · truncated' or ''))
    table.insert(lines, '')
    render_node(index.tree, '', 0, lines, rows, S.folded)
    if #lines <= 3 then
      table.insert(lines, '  (no source files with recognised symbols)')
    end
  end

  S.rows = rows
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)

  local hl = {
    dir = 'Directory',
    file = 'Title',
    symbol = 'Function',
  }
  for row, entry in pairs(rows) do
    local group = hl[entry.kind]
    if group then
      pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, group, row - 1, 0, -1)
    end
  end
  vim.bo[S.buf].modifiable = false
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function toggle_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = S.rows[row]
  if not entry then return end
  if entry.kind == 'symbol' then
    if entry.path then
      vim.cmd('edit ' .. vim.fn.fnameescape(entry.path))
      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, entry.line or 1), 0 })
      vim.cmd('normal! zz')
    end
    return
  end
  if entry.kind == 'file' then
    if S.folded[entry.rel] then
      S.folded[entry.rel] = nil
    else
      S.folded[entry.rel] = true
    end
    M.render()
    return
  end
  if entry.kind == 'dir' then
    if S.folded[entry.rel] then
      S.folded[entry.rel] = nil
    else
      S.folded[entry.rel] = true
    end
    M.render()
  end
end

local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then return S.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  S.buf = buf
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'dshstudio_project_tree'
  vim.api.nvim_buf_set_name(buf, 'dsh://project-tree')

  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map('<CR>', toggle_at_cursor, 'Open symbol / fold')
  map('<Tab>', toggle_at_cursor, 'Open symbol / fold')
  map('o', toggle_at_cursor, 'Open symbol / fold')
  map('za', toggle_at_cursor, 'Fold')
  map('r', function() M.refresh(true) end, 'Re-index the project')
  map('q', function() M.close() end, 'Close')
  map('p', function() M.pick() end, 'Fuzzy pick a symbol')
  map('g?', function()
    util().notify('CR/open jump · r re-index · p fuzzy pick · q close', vim.log.levels.INFO)
  end, 'Help')

  vim.api.nvim_create_autocmd('BufWipeout', {
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
  vim.api.nvim_win_set_width(win, math.max(width, 40))
  pcall(vim.api.nvim_set_option_value, 'number', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'relativenumber', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'signcolumn', 'no', { win = win })
  pcall(vim.api.nvim_set_option_value, 'cursorline', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'wrap', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'winfixwidth', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'winbar', '%#DshSidebarBar# Project tree %= r re-index ', { win = win })
  S.open = true
  M.refresh(false)
end

---Index the project (or re-index) and render.
---@param force boolean|nil
function M.refresh(force)
  local scan = select(1, pcall(require, 'dshstudio.project.scan'))
  local cwd = vim.fn.getcwd()
  local root = (scan and scan.detect_root and scan.detect_root(cwd)) or cwd
  if S.index and S.index.root == root and not force then
    M.render()
    return
  end

  S.index = nil
  S.folded = {}
  M.render()
  util().notify('indexing ' .. root .. ' …', vim.log.levels.INFO)

  local frames = 0
  M.build_index(root, {
    on_progress = function(done, total)
      frames = (frames % #SPINNER) + 1
      if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
        vim.schedule(function()
          if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
          pcall(vim.api.nvim_buf_set_lines, S.buf, 0, 1, false,
            { ('  %s indexing %d/%d …'):format(SPINNER[frames], done, total) })
        end)
      end
    end,
    on_done = function(index)
      S.index = index
      if not index then
        util().notify('indexing failed', vim.log.levels.ERROR)
        return
      end
      if M.open then M.render() end
      util().notify(('indexed %d files, %d symbols'):format(index.file_count, index.symbol_count),
        vim.log.levels.INFO)
    end,
  })
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

function M.toggle()
  if M.is_open() then M.close() else M.open_panel() end
end

---Flatten the cached index into a list for fuzzy picking.
function M.symbol_list()
  local out = {}
  local index = S.index
  if not index then return out end
  local function walk(node, prefix)
    for _, file in ipairs(node.files or {}) do
      for _, sym in ipairs(file.symbols or {}) do
        table.insert(out, {
          name = sym.name, kind = sym.kind, line = sym.line,
          rel = file.rel, path = file.path,
          parent = sym.parent,
        })
      end
    end
    for name, child in pairs(node.dirs or {}) do
      walk(child, prefix == '' and name or (prefix .. '/' .. name))
    end
  end
  walk(index.tree, '')
  return out
end

---Fuzzy-pick a project symbol, indexing first when needed.
function M.pick()
  local function choose()
    local list = M.symbol_list()
    if #list == 0 then
      util().notify('no symbols indexed — press r to re-index', vim.log.levels.WARN)
      return
    end
    vim.ui.select(list, {
      prompt = ('Project symbols (%d)'):format(#list),
      format_item = function(e)
        local parent = e.parent and (e.parent .. ' :: ') or ''
        return ('%s  %s%s  %s:%d'):format(e.kind or '?', parent, e.name, e.rel, e.line or 0)
      end,
    }, function(choice)
      if not choice then return end
      vim.cmd('edit ' .. vim.fn.fnameescape(choice.path))
      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, choice.line or 1), 0 })
      vim.cmd('normal! zz')
    end)
  end

  if S.index then
    local scan = select(1, pcall(require, 'dshstudio.project.scan'))
    local cwd = vim.fn.getcwd()
    local root = (scan and scan.detect_root and scan.detect_root(cwd)) or cwd
    if S.index.root == root then
      choose()
      return
    end
  end
  -- Nothing cached for this root yet: index first, then present.
  local scan = select(1, pcall(require, 'dshstudio.project.scan'))
  local cwd = vim.fn.getcwd()
  local root = (scan and scan.detect_root and scan.detect_root(cwd)) or cwd
  M.build_index(root, {
    on_done = function(index)
      S.index = index
      choose()
    end,
  })
end

---Short status string for the statusline.
function M.status()
  if not S.index then return '' end
  return ('tree:%d'):format(S.index.symbol_count)
end

return M
