-- dshstudio/project/scan.lua
--
-- Project scanner for DSH Studio's deepwiki-style analysis.
--
-- Responsibilities:
--   * detect a project root by walking upward from a start directory
--   * collect source/config files (iteratively, with ignore rules)
--   * classify every file by language and count its lines with ONE read
--
-- Every public function is total: it never throws, on any input. Unreadable
-- directories and files are skipped silently and reported through counters.
--
-- Lua 5.1 / LuaJIT compatible. Neovim 0.11+ APIs only (`vim.fs`, `vim.uv`).

local M = {}

local uv = vim.uv or vim.loop

M.MAX_DEPTH = 48

-- Directories that are never descended into (matched by basename).
M.IGNORE_DIRS = {
  ['.git'] = true,
  ['.svn'] = true,
  ['node_modules'] = true,
  ['build'] = true,
  ['_build'] = true,
  ['dist'] = true,
  ['target'] = true,
  ['__pycache__'] = true,
  ['.venv'] = true,
  ['venv'] = true,
  ['.dshstudio'] = true,
  ['.cache'] = true,
  ['CMakeFiles'] = true,
  ['.idea'] = true,
  ['.vscode'] = true,
}

-- Extension -> language. Keys are lower case, without the dot.
M.LANG_BY_EXT = {
  f90 = 'fortran',
  f95 = 'fortran',
  f03 = 'fortran',
  f08 = 'fortran',
  f77 = 'fortran',
  f = 'fortran',
  ['for'] = 'fortran',
  fpp = 'fortran',
  c = 'c',
  h = 'c',
  cpp = 'cpp',
  cc = 'cpp',
  cxx = 'cpp',
  ['c++'] = 'cpp',
  hpp = 'cpp',
  hh = 'cpp',
  hxx = 'cpp',
  ['h++'] = 'cpp',
  py = 'python',
  pyi = 'python',
  lua = 'lua',
  sh = 'bash',
  bash = 'bash',
  zsh = 'bash',
  md = 'markdown',
  markdown = 'markdown',
  json = 'config',
  yaml = 'config',
  yml = 'config',
  toml = 'config',
  cfg = 'config',
  ini = 'config',
  cmake = 'cmake',
}

-- Exact (lower case) file names that carry a language on their own.
M.LANG_BY_NAME = {
  ['cmakelists.txt'] = 'cmake',
  ['cmakecache.txt'] = 'cmake',
  ['makefile'] = 'make',
  ['gnumakefile'] = 'make',
  ['meson.build'] = 'make',
  ['sconstruct'] = 'make',
}

-- Root markers, strongest first.
M.ROOT_MARKERS = {
  '.git',
  'CMakeLists.txt',
  'fpm.toml',
  'pyproject.toml',
  'setup.py',
  'Makefile',
  'compile_commands.json',
}

local function normalize(p)
  if type(p) ~= 'string' or p == '' then return p end
  local ok, out = pcall(vim.fs.normalize, p)
  if ok and type(out) == 'string' and out ~= '' then return out end
  return (p:gsub('\\', '/'))
end

M.normalize = normalize

local function join(dir, name)
  if dir:sub(-1) == '/' then return dir .. name end
  return dir .. '/' .. name
end

local function basename(p)
  return (tostring(p or ''):match('([^/\\]+)$')) or tostring(p or '')
end

local function extension(p)
  local name = basename(p)
  local ext = name:match('%.([%w_+%-]+)$')
  if not ext then return '' end
  return ext:lower()
end

---Translate a shell-ish glob ("*", "?") into a Lua pattern and match a name.
---Also matches when the ignore entry equals the name.
local function ignore_matches(pat, name)
  if type(pat) ~= 'string' or pat == '' or type(name) ~= 'string' then return false end
  if pat == name then return true end
  if not pat:find('[%*%?]') then return false end
  local lua_pat = pat:gsub('[%^%$%(%)%.%[%]%+%-%%]', '%%%0')
  lua_pat = lua_pat:gsub('%*', '.*'):gsub('%?', '.')
  local ok, found = pcall(string.find, name, '^' .. lua_pat .. '$')
  return ok and found ~= nil
end

M.ignore_matches = ignore_matches

---Language of a file, from its name (and optionally a pre-split extension).
---@param path string
---@param name string|nil
---@return string
function M.lang_for(path, name)
  local ok, lang = pcall(function()
    local n = name or basename(path)
    local lower = n:lower()
    local by_name = M.LANG_BY_NAME[lower]
    if by_name then return by_name end
    local ext = extension(path)
    if ext ~= '' and M.LANG_BY_EXT[ext] then return M.LANG_BY_EXT[ext] end
    -- `CMakeLists.txt` and friends may arrive with a directory prefix only.
    if lower == 'cmakelists.txt' then return 'cmake' end
    return 'other'
  end)
  if ok and type(lang) == 'string' then return lang end
  return 'other'
end

---True when the language is a source language we can extract symbols from.
function M.is_source_lang(lang)
  return lang == 'fortran' or lang == 'c' or lang == 'cpp' or lang == 'python'
end

local function dir_entries(dir)
  local entries = {}
  local ok = pcall(function()
    for name, kind in vim.fs.dir(dir) do
      entries[#entries + 1] = { name = name, kind = kind }
    end
  end)
  if not ok then return nil end
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

local function is_dir(path)
  local ok, st = pcall(uv.fs_stat, path)
  if ok and st and st.type == 'directory' then return true end
  return false
end

M.is_dir = is_dir

local function dir_has_fortran(dir)
  local entries = dir_entries(dir)
  if not entries then return false end
  local seen = 0
  for _, e in ipairs(entries) do
    seen = seen + 1
    if seen > 4000 then break end
    if e.kind == 'file' then
      local lower = e.name:lower()
      if lower:match('%.f%d*$') or lower:match('%.for$') or lower:match('%.fpp$') then
        return true
      end
    end
  end
  return false
end

---Walk upward from `start_dir` looking for a project root marker.
---@param start_dir string|nil  defaults to the current working directory
---@return string|nil normalized absolute root
function M.detect_root(start_dir)
  local ok, root = pcall(function()
    local start = start_dir
    if type(start) ~= 'string' or start == '' then
      local cwd_ok, cwd = pcall(uv.cwd)
      start = (cwd_ok and cwd) or '.'
    end
    start = normalize(start)

    -- A file path (or a non-existent path) starts the walk at its directory.
    if not is_dir(start) then
      local parent_ok, parent = pcall(vim.fs.dirname, start)
      if parent_ok and type(parent) == 'string' and parent ~= '' then start = parent end
    end

    local dir = start
    for _ = 1, M.MAX_DEPTH do
      if type(dir) ~= 'string' or dir == '' then break end
      for _, marker in ipairs(M.ROOT_MARKERS) do
        local stat_ok, st = pcall(uv.fs_stat, join(dir, marker))
        if stat_ok and st ~= nil then return dir end
      end
      if dir_has_fortran(dir) then return dir end
      local parent_ok, parent = pcall(vim.fs.dirname, dir)
      if not parent_ok or type(parent) ~= 'string' then break end
      if parent == '' or parent == dir then break end
      dir = parent
    end

    -- Nothing found: fall back to the start directory when it exists.
    if is_dir(start) then return start end
    return nil
  end)
  if ok and type(root) == 'string' then return root end
  return nil
end

local function read_stats(path, max_bytes)
  local ok, data, reason = pcall(function()
    local f = io.open(path, 'rb')
    if not f then return nil, 'unreadable' end
    local chunk = f:read(max_bytes + 1)
    f:close()
    if not chunk then return nil, 'unreadable' end
    if #chunk > max_bytes then return nil, 'large' end
    return chunk, nil
  end)
  if not ok then return nil, 'unreadable' end
  if data == nil then return nil, reason or 'unreadable' end
  return data, nil
end

local function count_lines(data)
  if type(data) ~= 'string' or data == '' then return 0 end
  local _, newlines = data:gsub('\n', '')
  if data:sub(-1) == '\n' then return newlines end
  return newlines + 1
end

M.count_lines = count_lines

---Build one file entry. Returns nil plus a reason when the file is skipped.
local function build_entry(abs, rel, name, max_bytes)
  local lang = M.lang_for(abs, name)

  local size = nil
  local stat_ok, st = pcall(uv.fs_stat, abs)
  if stat_ok and st and st.type == 'file' then size = tonumber(st.size) end
  if size and size > max_bytes then return nil, 'large' end

  local data, reason = read_stats(abs, max_bytes)
  if not data then return nil, reason end

  if lang == 'other' or lang == 'config' then
    if data:find('%z') then lang = 'binary' end
  end
  if lang == 'binary' then
    return {
      path = abs,
      rel = rel,
      lang = 'binary',
      ext = extension(abs),
      bytes = size or #data,
      lines = 0,
    }, nil
  end

  return {
    path = abs,
    rel = rel,
    lang = lang,
    ext = extension(abs),
    bytes = size or #data,
    lines = count_lines(data),
  }, nil
end

---Collect files below `root`.
---@param root string
---@param opts table|nil { max_files = 4000, max_bytes_per_file = 2MiB, extra_ignore = {string} }
---@return table scan result
function M.collect(root, opts)
  local res = {
    root = nil,
    files = {},
    by_lang = {},
    skipped = 0,
    truncated = false,
  }

  local ok = pcall(function()
    opts = opts or {}
    if type(opts) ~= 'table' then opts = {} end
    local max_files = tonumber(opts.max_files) or 4000
    if max_files < 1 then max_files = 1 end
    local max_bytes = tonumber(opts.max_bytes_per_file) or (2 * 1024 * 1024)
    if max_bytes < 1024 then max_bytes = 1024 end

    local extra = {}
    if type(opts.extra_ignore) == 'table' then
      for _, v in ipairs(opts.extra_ignore) do
        if type(v) == 'string' and v ~= '' then
          extra[#extra + 1] = (v:gsub('/+$', ''))
        end
      end
    end

    local function ignored(name, rel)
      if M.IGNORE_DIRS[name] then return true end
      for _, pat in ipairs(extra) do
        if ignore_matches(pat, name) or ignore_matches(pat, rel) then return true end
      end
      return false
    end

    res.root = normalize(root)
    if type(res.root) ~= 'string' or res.root == '' or not is_dir(res.root) then
      return
    end

    local stack = { { dir = res.root, rel = '', depth = 0 } }
    while #stack > 0 do
      local cur = table.remove(stack)
      if cur and cur.depth <= M.MAX_DEPTH then
        local entries = dir_entries(cur.dir)
        if entries then
          for _, e in ipairs(entries) do
            local rel = (cur.rel == '') and e.name or (cur.rel .. '/' .. e.name)
            local abs = join(cur.dir, e.name)
            local skip = ignored(e.name, rel)

            local kind = e.kind
            if kind == 'link' then
              local stat_ok, st = pcall(uv.fs_stat, abs)
              if stat_ok and st then kind = st.type else kind = 'other' end
            end

            if kind == 'directory' then
              if not skip then
                stack[#stack + 1] = { dir = abs, rel = rel, depth = cur.depth + 1 }
              end
            elseif kind == 'file' then
              if not skip then
                if #res.files >= max_files then
                  res.truncated = true
                else
                  local entry, _reason = build_entry(abs, rel, e.name, max_bytes)
                  if entry then
                    res.files[#res.files + 1] = entry
                    local agg = res.by_lang[entry.lang]
                    if not agg then
                      agg = { count = 0, bytes = 0, lines = 0 }
                      res.by_lang[entry.lang] = agg
                    end
                    agg.count = agg.count + 1
                    agg.bytes = agg.bytes + (entry.bytes or 0)
                    agg.lines = agg.lines + (entry.lines or 0)
                  else
                    res.skipped = res.skipped + 1
                  end
                end
              end
            end
          end
        end
      end
    end

    table.sort(res.files, function(a, b) return a.rel < b.rel end)
  end)

  if not ok then
    -- Keep whatever was collected so far; report a degraded but valid shape.
    if type(res.files) ~= 'table' then res.files = {} end
    if type(res.by_lang) ~= 'table' then res.by_lang = {} end
  end

  return res
end

---All file entries of one language.
---@param scan_result table
---@param lang string
---@return table[] list of file entries (possibly empty)
function M.find_by_lang(scan_result, lang)
  local out = {}
  pcall(function()
    if type(scan_result) ~= 'table' or type(lang) ~= 'string' then return end
    for _, f in ipairs(scan_result.files or {}) do
      if f and f.lang == lang then out[#out + 1] = f end
    end
  end)
  return out
end

---All file entries whose language is one of `langs` (or all source languages).
---@param scan_result table
---@param langs table|nil set or list of languages
---@return table[]
function M.find_source_files(scan_result, langs)
  local out = {}
  pcall(function()
    if type(scan_result) ~= 'table' then return end
    local want = nil
    if type(langs) == 'table' then
      want = {}
      for k, v in pairs(langs) do
        if type(v) == 'string' then want[v] = true end
        if type(k) == 'string' and type(v) == 'boolean' and v then want[k] = true end
      end
    end
    for _, f in ipairs(scan_result.files or {}) do
      if f and type(f.lang) == 'string' then
        local keep
        if want then keep = want[f.lang] == true else keep = M.is_source_lang(f.lang) end
        if keep then out[#out + 1] = f end
      end
    end
  end)
  return out
end

---Total counts across all collected files.
---@return integer files, integer lines, integer bytes
function M.totals(scan_result)
  local files, lines, bytes = 0, 0, 0
  pcall(function()
    if type(scan_result) ~= 'table' then return end
    for _, f in ipairs(scan_result.files or {}) do
      files = files + 1
      lines = lines + (tonumber(f.lines) or 0)
      bytes = bytes + (tonumber(f.bytes) or 0)
    end
  end)
  return files, lines, bytes
end

---Languages sorted by file count (descending), for reports.
---@return table[] { { lang = string, count = int, lines = int, bytes = int }, ... }
function M.language_table(scan_result)
  local out = {}
  pcall(function()
    if type(scan_result) ~= 'table' then return end
    for lang, agg in pairs(scan_result.by_lang or {}) do
      out[#out + 1] = {
        lang = lang,
        count = tonumber(agg.count) or 0,
        lines = tonumber(agg.lines) or 0,
        bytes = tonumber(agg.bytes) or 0,
      }
    end
    table.sort(out, function(a, b)
      if a.count == b.count then return a.lang < b.lang end
      return a.count > b.count
    end)
  end)
  return out
end

---Human readable size, e.g. "12.4 KB".
function M.human_bytes(n)
  local ok, s = pcall(function()
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
  end)
  if ok then return s end
  return tostring(n)
end

---Short single-line summary of a scan, for notifications and statuslines.
function M.summary(scan_result)
  local ok, text = pcall(function()
    if type(scan_result) ~= 'table' then return 'no scan' end
    local files, lines = M.totals(scan_result)
    return ('%d files, %d lines%s'):format(
      files,
      lines,
      scan_result.truncated and ' (truncated)' or ''
    )
  end)
  if ok then return text end
  return 'scan unavailable'
end

return M
