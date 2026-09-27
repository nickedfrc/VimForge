-- dshstudio/project/report.lua
--
-- Markdown renderer for DSH Studio's deepwiki-style project analysis.
--
-- `M.build(ctx)` is a pure function over already-computed analysis tables; it
-- never reads the filesystem (except for `write`/`open`) and never throws.
-- Cell content is always escaped and flattened: a table row never contains a
-- raw newline or a bare `|`.
--
-- Lua 5.1 / LuaJIT compatible. Neovim 0.11+ APIs only.

local M = {}

local MAX_FUNC_ROWS = 400
local MAX_TREE_LINES = 400

--------------------------------------------------------------------------------
-- markdown helpers
--------------------------------------------------------------------------------

local function esc(value)
  local t = tostring(value == nil and '' or value)
  t = t:gsub('[\r\n]+', ' ')
  t = t:gsub('\t', ' ')
  t = t:gsub('|', '\\|')
  return t
end

M.esc = esc

local function short(value, limit)
  local t = tostring(value == nil and '' or value)
  limit = tonumber(limit) or 160
  if #t > limit then t = t:sub(1, limit - 1) .. '...' end
  return t
end

local function cell(value, limit)
  return esc(short(value, limit or 160))
end

local function table_lines(headers, rows)
  local out = {}
  if type(headers) ~= 'table' or #headers == 0 then return out end
  local head = {}
  for i = 1, #headers do head[i] = esc(headers[i]) end
  out[#out + 1] = '| ' .. table.concat(head, ' | ') .. ' |'
  local seps = {}
  for i = 1, #headers do seps[i] = '---' end
  out[#out + 1] = '| ' .. table.concat(seps, ' | ') .. ' |'
  for _, r in ipairs(rows or {}) do
    local cells = {}
    for i = 1, #headers do
      cells[i] = cell(type(r) == 'table' and r[i] or nil)
    end
    out[#out + 1] = '| ' .. table.concat(cells, ' | ') .. ' |'
  end
  return out
end

M.table_lines = table_lines

local function join_capped(list, max)
  local out = {}
  max = tonumber(max) or 6
  local n = 0
  for _, v in ipairs(list or {}) do
    n = n + 1
    if n <= max then out[#out + 1] = tostring(v) end
  end
  local text = table.concat(out, ', ')
  if n > max then text = text .. (' (+%d more)'):format(n - max) end
  if text == '' then return '-' end
  return text
end

M.join_capped = join_capped

local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl or {}) do
    if type(k) == 'string' then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

local function basename(p)
  return (tostring(p or ''):match('([^/\\]+)$')) or tostring(p or '')
end

local function human_bytes(n)
  n = tonumber(n) or 0
  if n < 1024 then return ('%d B'):format(n) end
  local units = { 'KB', 'MB', 'GB', 'TB' }
  local v = n / 1024
  local i = 1
  while v >= 1024 and i < #units do
    v = v / 1024
    i = i + 1
  end
  return ('%.1f %s'):format(v, units[i])
end

--------------------------------------------------------------------------------
-- directory tree
--------------------------------------------------------------------------------

---Render a depth-limited directory tree from scan file entries.
---@param files table[] entries with `rel`
---@param root string
---@param max_depth integer|nil default 3
---@return string[] lines
function M.render_tree(files, root, max_depth)
  local lines = {}
  local ok = pcall(function()
    local depth_limit = tonumber(max_depth) or 3
    if depth_limit < 1 then depth_limit = 1 end

    local tree = { name = basename(root or '.'), dirs = {}, file_names = {}, count = 0, dir_names = {} }
    local inserted = 0

    for _, f in ipairs(files or {}) do
      local rel = type(f) == 'table' and f.rel or nil
      if type(rel) == 'string' and rel ~= '' and not rel:match('^%.%.') and not rel:match('/%.%./') then
        local parts = {}
        for seg in rel:gmatch('[^/]+') do parts[#parts + 1] = seg end
        if #parts > 0 then
          local node = tree
          node.count = node.count + 1
          for i = 1, #parts - 1 do
            local d = node.dirs[parts[i]]
            if not d then
              d = { name = parts[i], dirs = {}, file_names = {}, count = 0, dir_names = {} }
              node.dirs[parts[i]] = d
            end
            d.count = d.count + 1
            node = d
          end
          node.file_names[#node.file_names + 1] = parts[#parts]
          inserted = inserted + 1
        end
      end
    end

    local function sort_node(node)
      table.sort(node.file_names)
      local names = {}
      for name in pairs(node.dirs) do names[#names + 1] = name end
      table.sort(names)
      node.dir_names = names
      for _, name in ipairs(names) do sort_node(node.dirs[name]) end
    end
    sort_node(tree)

    lines[#lines + 1] = ('%s/  (%d files)'):format(tree.name, tree.count)

    local function emit(node, prefix, depth)
      if #lines > MAX_TREE_LINES then return end
      local children = {}
      for _, name in ipairs(node.dir_names) do
        children[#children + 1] = { dir = node.dirs[name] }
      end
      for _, name in ipairs(node.file_names) do
        children[#children + 1] = { file = name }
      end
      for i, ch in ipairs(children) do
        if #lines > MAX_TREE_LINES then break end
        local last = (i == #children)
        local branch = last and '└── ' or '├── '
        local cont = last and '    ' or '│   '
        if ch.dir then
          local d = ch.dir
          if depth < depth_limit then
            lines[#lines + 1] = prefix .. branch .. d.name .. ('/  (%d files)'):format(d.count)
            emit(d, prefix .. cont, depth + 1)
          else
            lines[#lines + 1] = prefix .. branch .. d.name
              .. ('/  (%d files, collapsed)'):format(d.count)
          end
        else
          lines[#lines + 1] = prefix .. branch .. ch.file
        end
      end
    end

    emit(tree, '', 1)

    if #lines > MAX_TREE_LINES then
      lines[#lines + 1] = ('... (tree truncated; %d files total)'):format(inserted)
    end
  end)
  if not ok then return {} end
  return lines
end

--------------------------------------------------------------------------------
-- context unpacking
--------------------------------------------------------------------------------

local function split_inputs(ctx)
  local usage = type(ctx.usage) == 'table' and ctx.usage or nil
  local cdeps, pydeps = nil, nil
  local deps = ctx.deps

  if type(deps) == 'table' then
    if deps.fortran or deps.c or deps.python then
      if not usage and type(deps.fortran) == 'table' then usage = deps.fortran end
      if type(deps.c) == 'table' then cdeps = deps.c end
      if type(deps.python) == 'table' then pydeps = deps.python end
    end
    if not pydeps and type(deps.imports) == 'table' then pydeps = deps end
    if not cdeps and type(deps.includes) == 'table' then
      local first = nil
      for _, v in pairs(deps.includes) do
        first = v
        break
      end
      if first == nil or (type(first) == 'table' and first.system ~= nil) then
        cdeps = deps
      end
    end
  end
  return usage, cdeps, pydeps
end

local function flatten_symbols(symbols)
  local out = {}
  pcall(function()
    if type(symbols) ~= 'table' then return end
    local rels = sorted_keys(symbols)
    for _, rel in ipairs(rels) do
      local list = symbols[rel]
      if type(list) == 'table' then
        for _, s in ipairs(list) do
          if type(s) == 'table' and type(s.name) == 'string' then
            out[#out + 1] = {
              rel = rel,
              name = s.name,
              kind = s.kind or 'global',
              line = s.line,
              end_line = s.end_line,
              signature = s.signature,
              parent = s.parent,
            }
          end
        end
      end
    end
  end)
  return out
end

--------------------------------------------------------------------------------
-- sections
--------------------------------------------------------------------------------

local function section_metadata(ctx, scan)
  local files, lines_total, bytes = 0, 0, 0
  pcall(function()
    for _, f in ipairs(scan and scan.files or {}) do
      files = files + 1
      lines_total = lines_total + (tonumber(f.lines) or 0)
      bytes = bytes + (tonumber(f.bytes) or 0)
    end
  end)
  local langs = {}
  pcall(function()
    for lang in pairs(scan and scan.by_lang or {}) do langs[#langs + 1] = lang end
    table.sort(langs)
  end)

  local rows = {
    { 'Root', esc(ctx.root or (scan and scan.root) or '(unknown)') },
    { 'Generated', esc(ctx.generated_at or os.date('%Y-%m-%d %H:%M:%S')) },
    { 'Files', tostring(files) },
    { 'Total lines', tostring(lines_total) },
    { 'Total size', human_bytes(bytes) },
    { 'Languages', esc(table.concat(langs, ', ')) },
  }
  if ctx.version then rows[#rows + 1] = { 'Tool version', esc(ctx.version) } end
  if scan and scan.truncated then
    rows[#rows + 1] = { 'Note', 'file collection was truncated by max_files' }
  end
  if scan and (tonumber(scan.skipped) or 0) > 0 then
    rows[#rows + 1] = { 'Skipped files', tostring(scan.skipped) }
  end

  local out = { '| Field | Value |', '| --- | --- |' }
  for _, r in ipairs(rows) do
    out[#out + 1] = ('| %s | %s |'):format(esc(r[1]), esc(r[2]))
  end
  return out
end

local function language_rows(scan)
  local rows = {}
  local function fallback()
    rows = {}
    local by_lang = (type(scan) == 'table' and scan.by_lang) or {}
    for _, lang in ipairs(sorted_keys(by_lang)) do
      local agg = by_lang[lang] or {}
      rows[#rows + 1] = {
        lang, tostring(agg.count or 0), tostring(agg.lines or 0), human_bytes(agg.bytes or 0),
      }
    end
    table.sort(rows, function(a, b)
      local na, nb = tonumber(a[2]) or 0, tonumber(b[2]) or 0
      if na == nb then return a[1] < b[1] end
      return na > nb
    end)
  end

  pcall(function()
    if type(scan) ~= 'table' then return end
    local scan_ok, scan_mod = pcall(require, 'dshstudio.project.scan')
    if scan_ok and type(scan_mod) == 'table' and type(scan_mod.language_table) == 'function' then
      local list = scan_mod.language_table(scan)
      for _, e in ipairs(list or {}) do
        rows[#rows + 1] = {
          e.lang, tostring(e.count or 0), tostring(e.lines or 0), human_bytes(e.bytes or 0),
        }
      end
    end
  end)

  if #rows == 0 then fallback() end
  return rows
end

local function section_overview(scan)
  local rows = language_rows(scan)
  if #rows == 0 then rows[#rows + 1] = { '(no files detected)', '0', '0', '0 B' } end
  return table_lines({ 'Language', 'Files', 'Lines', 'Size' }, rows)
end

local function section_modules(ctx, flat)
  local structure = type(ctx.structure) == 'table' and ctx.structure or {}
  local out = {}

  local module_rows = {}
  if type(structure.modules) == 'table' and #structure.modules > 0 then
    for _, m in ipairs(structure.modules) do
      module_rows[#module_rows + 1] = {
        m.name, m.kind or 'module', m.rel, tostring(m.line or ''),
      }
    end
  else
    for _, s in ipairs(flat) do
      if s.kind == 'module' or s.kind == 'namespace' then
        module_rows[#module_rows + 1] = { s.name, s.kind, s.rel, tostring(s.line or '') }
      end
    end
  end
  out[#out + 1] = ('**Modules / namespaces: %d**'):format(#module_rows)
  out[#out + 1] = ''
  if #module_rows > 0 then
    for _, line in ipairs(table_lines({ 'Name', 'Kind', 'Defined in', 'Line' }, module_rows)) do
      out[#out + 1] = line
    end
  else
    out[#out + 1] = '_No modules or namespaces were detected._'
  end
  out[#out + 1] = ''

  local type_rows = {}
  if type(structure.types) == 'table' and #structure.types > 0 then
    for _, t in ipairs(structure.types) do
      type_rows[#type_rows + 1] = {
        t.name, t.kind or 'type', t.rel, tostring(t.line or ''), t.parent or '-',
      }
    end
  else
    local TYPE_KINDS = { type = true, class = true, struct = true, enum = true, union = true }
    for _, s in ipairs(flat) do
      if TYPE_KINDS[s.kind] then
        type_rows[#type_rows + 1] = {
          s.name, s.kind, s.rel, tostring(s.line or ''), s.parent or '-',
        }
      end
    end
  end
  out[#out + 1] = ('**Key types: %d**'):format(#type_rows)
  out[#out + 1] = ''
  if #type_rows > 0 then
    if #type_rows > 200 then
      out[#out + 1] = ('_Showing the first 200 of %d types._'):format(#type_rows)
      out[#out + 1] = ''
      while #type_rows > 200 do table.remove(type_rows) end
    end
    for _, line in ipairs(table_lines({ 'Name', 'Kind', 'Defined in', 'Line', 'Parent' }, type_rows)) do
      out[#out + 1] = line
    end
  else
    out[#out + 1] = '_No types were detected._'
  end
  return out
end

local function section_functions(flat)
  local out = {}
  local callable = {}
  for _, s in ipairs(flat) do
    local kind = s.kind
    if kind == 'subroutine' or kind == 'function' or kind == 'method'
      or kind == 'procedure' or kind == 'program' then
      callable[#callable + 1] = s
    end
  end

  if #callable == 0 then
    out[#out + 1] = '_No subroutines, functions or programs were detected._'
    return out
  end

  local by_file = {}
  local order = {}
  for _, s in ipairs(callable) do
    local list = by_file[s.rel]
    if not list then
      list = {}
      by_file[s.rel] = list
      order[#order + 1] = s.rel
    end
    list[#list + 1] = s
  end
  table.sort(order)

  local rows_total = 0
  local truncated = false
  for _, rel in ipairs(order) do
    local list = by_file[rel]
    out[#out + 1] = ('#### %s'):format(esc(rel))
    out[#out + 1] = ''
    local rows = {}
    for _, s in ipairs(list) do
      if rows_total >= MAX_FUNC_ROWS then
        truncated = true
        break
      end
      rows_total = rows_total + 1
      rows[#rows + 1] = {
        tostring(s.line or ''),
        tostring(s.end_line or ''),
        s.kind,
        s.name,
        s.parent or '-',
        cell(s.signature, 120),
      }
    end
    for _, line in ipairs(table_lines({ 'Line', 'End', 'Kind', 'Name', 'Parent', 'Signature' }, rows)) do
      out[#out + 1] = line
    end
    out[#out + 1] = ''
    if truncated then break end
  end

  if truncated then
    out[#out + 1] = ('_Function table truncated at %d rows._'):format(MAX_FUNC_ROWS)
  end
  return out
end

local function section_dependencies(usage, cdeps, pydeps)
  local out = {}

  -- Local includes (C/C++)
  local include_rows = {}
  pcall(function()
    for _, rel in ipairs(sorted_keys(cdeps and cdeps.includes or {})) do
      local entry = cdeps.includes[rel]
      local local_list = type(entry) == 'table' and entry['local'] or {}
      if #local_list > 0 then
        include_rows[#include_rows + 1] = { rel, join_capped(local_list, 8) }
      end
    end
    -- Fortran INCLUDE statements are local file references too.
    for _, rel in ipairs(sorted_keys(usage and usage.includes or {})) do
      local list = usage.includes[rel]
      if type(list) == 'table' and #list > 0 then
        include_rows[#include_rows + 1] = { rel, join_capped(list, 8) }
      end
    end
    table.sort(include_rows, function(a, b) return a[1] < b[1] end)
  end)
  out[#out + 1] = '### 5.1 Local includes (C/C++) and Fortran INCLUDE'
  out[#out + 1] = ''
  if #include_rows > 0 then
    for _, line in ipairs(table_lines({ 'File', 'Local includes / INCLUDE' }, include_rows)) do
      out[#out + 1] = line
    end
  else
    out[#out + 1] = '_No local `#include "..."` directives or `INCLUDE` statements were found._'
  end
  out[#out + 1] = ''

  -- Fortran USE modules
  local use_rows = {}
  pcall(function()
    for _, name in ipairs(sorted_keys(usage and usage.modules or {})) do
      local m = usage.modules[name]
      local used_by = type(m.used_by) == 'table' and m.used_by or {}
      use_rows[#use_rows + 1] = {
        name,
        m.defined_in or '(external)',
        tostring(#used_by),
        join_capped(used_by, 6),
      }
    end
    table.sort(use_rows, function(a, b)
      local na, nb = tonumber(a[3]) or 0, tonumber(b[3]) or 0
      if na == nb then return a[1] < b[1] end
      return na > nb
    end)
  end)
  out[#out + 1] = '### 5.2 Fortran module usage'
  out[#out + 1] = ''
  if #use_rows > 0 then
    local shown = use_rows
    if #shown > 200 then
      shown = {}
      for i = 1, 200 do shown[i] = use_rows[i] end
      out[#out + 1] = ('_Showing the 200 most used of %d modules._'):format(#use_rows)
      out[#out + 1] = ''
    end
    for _, line in ipairs(table_lines({ 'Module', 'Defined in', 'Used by', 'Users' }, shown)) do
      out[#out + 1] = line
    end
  else
    out[#out + 1] = '_No `USE` statements were found._'
  end
  out[#out + 1] = ''

  -- Python imports
  local py_rows = {}
  pcall(function()
    for _, rel in ipairs(sorted_keys(pydeps and pydeps.imports or {})) do
      local entry = pydeps.imports[rel]
      if type(entry) == 'table' then
        local local_list = entry['local'] or {}
        local external = entry.external or {}
        if #local_list > 0 or #external > 0 then
          py_rows[#py_rows + 1] = {
            rel, join_capped(local_list, 8), join_capped(external, 8),
          }
        end
      end
    end
  end)
  out[#out + 1] = '### 5.3 Python imports'
  out[#out + 1] = ''
  if #py_rows > 0 then
    for _, line in ipairs(table_lines({ 'File', 'Internal modules', 'External modules' }, py_rows)) do
      out[#out + 1] = line
    end
  else
    out[#out + 1] = '_No Python imports were found._'
  end
  out[#out + 1] = ''

  -- External dependencies (system headers / unresolved imports / external modules)
  local external = {}
  pcall(function()
    local seen = {}
    for _, rel in ipairs(sorted_keys(cdeps and cdeps.includes or {})) do
      local entry = cdeps.includes[rel]
      for _, name in ipairs(type(entry) == 'table' and entry.system or {}) do
        if not seen[name] then
          seen[name] = true
          external[#external + 1] = name
        end
      end
    end
    for _, rel in ipairs(sorted_keys(pydeps and pydeps.imports or {})) do
      local entry = pydeps.imports[rel]
      for _, name in ipairs(type(entry) == 'table' and entry.external or {}) do
        local key = name .. ' (python)'
        if not seen[key] then
          seen[key] = true
          external[#external + 1] = key
        end
      end
    end
    for _, name in ipairs(sorted_keys(usage and usage.modules or {})) do
      local m = usage.modules[name]
      if not m.defined_in then
        local key = name .. ' (fortran module)'
        if not seen[key] then
          seen[key] = true
          external[#external + 1] = key
        end
      end
    end
    table.sort(external)
  end)

  out[#out + 1] = '### 5.4 External dependencies'
  out[#out + 1] = ''
  if #external > 0 then
    out[#out + 1] = ('%d external dependencies detected:'):format(#external)
    out[#out + 1] = ''
    local shown = external
    if #shown > 300 then
      shown = {}
      for i = 1, 300 do shown[i] = external[i] end
    end
    for _, name in ipairs(shown) do
      out[#out + 1] = ('- %s'):format(esc(name))
    end
    if #external > 300 then
      out[#out + 1] = ('- ... and %d more'):format(#external - 300)
    end
  else
    out[#out + 1] = '_No external dependencies were detected._'
  end
  return out
end

local function section_call_graph(ctx)
  local out = {}
  local graph = type(ctx.graph) == 'table' and ctx.graph or {}
  local top = {}

  local static_ok, static_mod = pcall(require, 'dshstudio.project.static')
  if static_ok and type(static_mod) == 'table' and type(static_mod.top_callees) == 'function' then
    local ok, res = pcall(static_mod.top_callees, graph, 30)
    if ok and type(res) == 'table' then top = res end
  end
  if #top == 0 then
    for name, node in pairs(graph) do
      if type(node) == 'table' then
        local callers = node.called_by or {}
        top[#top + 1] = { name = name, count = #callers, callers = callers, calls = #(node.calls or {}) }
      end
    end
    table.sort(top, function(a, b)
      if a.count == b.count then return a.name < b.name end
      return a.count > b.count
    end)
    while #top > 30 do table.remove(top) end
  end

  if #top == 0 then
    out[#out + 1] = '_No call relationships were detected._'
    return out
  end

  local rows = {}
  for _, entry in ipairs(top) do
    rows[#rows + 1] = {
      entry.name,
      tostring(entry.count or 0),
      tostring(entry.calls or 0),
      join_capped(entry.callers or {}, 6),
    }
  end
  for _, line in ipairs(table_lines({ 'Callee', 'Callers', 'Outgoing', 'Called by' }, rows)) do
    out[#out + 1] = line
  end
  out[#out + 1] = ''
  out[#out + 1] = '_Call attribution is file-level: a call is credited to every function '
    .. 'defined in the calling file. Standard library and intrinsic names are filtered out._'
  return out
end

local function section_entry_points(ctx)
  local structure = type(ctx.structure) == 'table' and ctx.structure or {}
  local rows = {}
  local KIND_LABEL = {
    program = 'Fortran program',
    main = 'C/C++ main()',
    python_main = 'Python __main__ guard',
  }
  for _, e in ipairs(type(structure.entry_points) == 'table' and structure.entry_points or {}) do
    rows[#rows + 1] = {
      e.rel,
      e.name or '-',
      KIND_LABEL[e.kind] or (e.kind or '-'),
      e.line and tostring(e.line) or '-',
    }
  end
  if #rows == 0 then
    return { '_No entry points were detected._' }
  end
  return table_lines({ 'File', 'Name', 'Kind', 'Line' }, rows)
end

local function section_largest(ctx, scan)
  local structure = type(ctx.structure) == 'table' and ctx.structure or {}
  local rows = {}
  if type(structure.largest) == 'table' and #structure.largest > 0 then
    for i, f in ipairs(structure.largest) do
      rows[#rows + 1] = { tostring(i), f.rel, tostring(f.lines or 0) }
    end
  else
    local list = {}
    pcall(function()
      for _, f in ipairs(scan and scan.files or {}) do
        if f.lang ~= 'binary' then list[#list + 1] = { rel = f.rel, lines = tonumber(f.lines) or 0 } end
      end
    end)
    table.sort(list, function(a, b)
      if a.lines == b.lines then return a.rel < b.rel end
      return a.lines > b.lines
    end)
    for i = 1, math.min(15, #list) do
      rows[#rows + 1] = { tostring(i), list[i].rel, tostring(list[i].lines) }
    end
  end
  if #rows == 0 then return { '_No files to rank._' } end
  return table_lines({ '#', 'File', 'Lines' }, rows)
end

--------------------------------------------------------------------------------
-- build
--------------------------------------------------------------------------------

---Build the complete Markdown report. Always returns a string.
---@param ctx table {
---   root, scan, symbols, usage, deps, graph, structure,
---   ai_section = string|nil, generated_at = string|nil, version = string|nil }
---@return string markdown
function M.build(ctx)
  local ok, doc = pcall(function()
    ctx = type(ctx) == 'table' and ctx or {}
    local scan = type(ctx.scan) == 'table' and ctx.scan or nil
    local usage, cdeps, pydeps = split_inputs(ctx)
    local flat = flatten_symbols(ctx.symbols)

    local root = ctx.root or (scan and scan.root) or '.'
    local out = {}
    local function add(lines)
      if type(lines) == 'string' then
        out[#out + 1] = lines
      elseif type(lines) == 'table' then
        for _, line in ipairs(lines) do out[#out + 1] = line end
      end
    end

    add('# DSH Studio Project Analysis')
    add('')
    add('_Generated by DSH Studio deepwiki-style static analysis._')
    add('')
    add(section_metadata(ctx, scan))
    add('')

    add('## 1. Project Overview')
    add('')
    add(section_overview(scan))
    add('')

    add('## 2. Directory Structure')
    add('')
    add('```text')
    add(M.render_tree(scan and scan.files or {}, root, 3))
    add('```')
    add('')

    add('## 3. Modules and Key Types')
    add('')
    add(section_modules(ctx, flat))
    add('')

    add('## 4. Subroutines and Functions')
    add('')
    add(section_functions(flat))
    add('')

    add('## 5. Dependency Analysis')
    add('')
    add(section_dependencies(usage, cdeps, pydeps))
    add('')

    add('## 6. Call Graph Highlights')
    add('')
    add(section_call_graph(ctx))
    add('')

    add('## 7. Entry Points')
    add('')
    add(section_entry_points(ctx))
    add('')

    add('## 8. Largest Files')
    add('')
    add(section_largest(ctx, scan))
    add('')

    add('## 9. AI Architecture Notes')
    add('')
    if type(ctx.ai_section) == 'string' and ctx.ai_section ~= '' then
      add(ctx.ai_section)
    else
      add('_No AI architecture notes were generated for this run._')
    end
    add('')

    return table.concat(out, '\n')
  end)

  if ok and type(doc) == 'string' then return doc end
  return table.concat({
    '# DSH Studio Project Analysis',
    '',
    '_Report generation failed; partial analysis was not recoverable._',
    '',
  }, '\n')
end

--------------------------------------------------------------------------------
-- side effects
--------------------------------------------------------------------------------

---Write the report to disk, creating parent directories. Never throws.
---@param ctx table
---@param out_path string
---@return boolean written
function M.write(ctx, out_path)
  local ok = pcall(function()
    if type(out_path) ~= 'string' or out_path == '' then error('no output path') end
    local dir = out_path:match('^(.*)[/\\][^/\\]*$')
    if dir and dir ~= '' then
      pcall(vim.fn.mkdir, dir, 'p')
    end
    local doc = M.build(ctx)
    local f = io.open(out_path, 'w')
    if not f then error('cannot open ' .. out_path) end
    f:write(doc)
    f:close()
    return true
  end)
  return ok == true
end

---Open a report in a buffer. Never throws.
---@param ctx table|string|nil optional; `ctx.open_cmd` selects the command
---@param out_path string|nil
---@return boolean opened
function M.open(ctx, out_path)
  local opened = false
  pcall(function()
    local path = out_path
    if type(ctx) == 'string' and path == nil then path = ctx end
    if type(path) ~= 'string' or path == '' then return end
    local cmd = type(ctx) == 'table' and ctx.open_cmd or nil
    if type(cmd) ~= 'string' or cmd == '' then cmd = 'edit' end
    if cmd ~= 'edit' and cmd ~= 'tabnew' and cmd ~= 'vsplit' and cmd ~= 'split' then
      cmd = 'edit'
    end
    vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
    pcall(function() vim.bo.filetype = 'markdown' end)
    pcall(function() vim.bo.swapfile = false end)
    opened = true
  end)
  return opened
end

return M
