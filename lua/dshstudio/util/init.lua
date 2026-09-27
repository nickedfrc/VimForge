-- dshstudio/util/init.lua
--
-- Tiny, dependency-free helpers shared by every DSH Studio module.
--
-- Contract for the whole module:
--   * no function ever throws -- everything that can fail is pcall-guarded;
--   * no function notifies on its own (except M.notify itself), so callers keep
--     control over what the user sees;
--   * nothing here requires another dshstudio module, which keeps the module
--     safe to load very early during startup.

local M = {}

---Notify through vim.notify, always tagged with the product title.
---@param msg string|any
---@param level string|number|nil 'trace'|'debug'|'info'|'warn'|'error' or vim.log.levels.*
---@return boolean ok
function M.notify(msg, level)
  local ok = pcall(function()
    local levels = vim.log.levels
    local resolved = levels.INFO
    if type(level) == 'number' then
      resolved = level
    elseif type(level) == 'string' then
      resolved = levels[level:upper()] or levels.INFO
    end
    local opts = { title = 'DSH Studio' }
    -- Errors should stay on screen long enough to be read; info is transient.
    if resolved >= levels.ERROR then
      opts.timeout = 8000
    elseif resolved == levels.WARN then
      opts.timeout = 5000
    end
    vim.notify(tostring(msg), resolved, opts)
  end)
  return ok
end

---True when running on Windows.
---@return boolean
function M.is_windows()
  local ok, res = pcall(function()
    return vim.fn.has('win32') == 1 or package.config:sub(1, 1) == '\\'
  end)
  return ok and res == true
end

---Native path separator.
---@return string
function M.path_sep()
  if M.is_windows() then
    return '\\'
  end
  return '/'
end

---Join path fragments, tolerating nil/empty parts and mixed separators.
---@param ... string|nil
---@return string
function M.join(...)
  -- Capture the varargs before entering the pcall closure: '...' is not visible
  -- inside a nested (non-vararg) function.
  local count = select('#', ...)
  local parts = { ... }
  local ok, joined = pcall(function()
    local out = nil
    for i = 1, count do
      local part = parts[i]
      if type(part) == 'string' and part ~= '' then
        if out == nil then
          out = part
        else
          out = out:gsub('[/\\]+$', '')
          local tail = part:gsub('^[/\\]+', '')
          out = out .. M.path_sep() .. tail
        end
      end
    end
    return out or ''
  end)
  if ok and type(joined) == 'string' then
    return joined
  end
  return ''
end

---Read a whole file as text (LF preserved, CR kept so callers may detect CRLF).
---@param path string
---@return string|nil
function M.read_file(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  local ok, data = pcall(function()
    local fd = io.open(path, 'rb')
    if not fd then
      return nil
    end
    local content = fd:read('*a')
    fd:close()
    return content
  end)
  if ok and type(data) == 'string' then
    return data
  end
  return nil
end

---Write text to a file, creating parent directories. Binary mode keeps the
---bytes exactly as given (no CRLF translation).
---@param path string
---@param data string
---@return boolean
function M.write_file(path, data)
  if type(path) ~= 'string' or path == '' or type(data) ~= 'string' then
    return false
  end
  local dir = nil
  pcall(function()
    dir = vim.fn.fnamemodify(path, ':p:h')
  end)
  if type(dir) == 'string' and dir ~= '' then
    M.mkdirp(dir)
  end
  local ok = pcall(function()
    local fd = io.open(path, 'wb')
    if not fd then
      return false
    end
    local wrote = fd:write(data)
    fd:close()
    return wrote ~= nil
  end)
  return ok == true
end

---Create a directory and any missing parents.
---@param path string
---@return boolean
function M.mkdirp(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local ok, created = pcall(vim.fn.mkdir, path, 'p')
  if ok then
    -- vim.fn.mkdir returns 1 on success and 0 when the directory already
    -- existed, so confirm with isdirectory before reporting failure.
    local exists = false
    pcall(function()
      exists = vim.fn.isdirectory(path) == 1
    end)
    return created == 1 or exists
  end
  return false
end

---Trim leading/trailing whitespace. Non-strings yield ''.
---@param s string|nil
---@return string
function M.trim(s)
  if type(s) ~= 'string' then
    return ''
  end
  local ok, trimmed = pcall(function()
    return s:match('^%s*(.-)%s*$')
  end)
  if ok and type(trimmed) == 'string' then
    return trimmed
  end
  return s
end

---Split into lines: accepts LF and CRLF, drops the empty element produced by a
---trailing newline (callers expect a plain line list).
---@param s string|nil
---@return string[]
function M.split_lines(s)
  if type(s) ~= 'string' or s == '' then
    return {}
  end
  local ok, lines = pcall(function()
    local out = vim.split(s, '\n', { plain = true })
    for i = 1, #out do
      if out[i]:sub(-1) == '\r' then
        out[i] = out[i]:sub(1, -2)
      end
    end
    if #out > 0 and out[#out] == '' then
      table.remove(out)
    end
    return out
  end)
  if ok and type(lines) == 'table' then
    return lines
  end
  return {}
end

---Read a file into a line list (nil when unreadable).
---@param path string
---@return string[]|nil
function M.read_lines(path)
  local data = M.read_file(path)
  if data == nil then
    return nil
  end
  return M.split_lines(data)
end

---Path relative to `base` when `path` lives underneath it; otherwise `path`.
---Comparison is case-insensitive on Windows; no '..' traversal is produced.
---@param path string
---@param base string
---@return string
function M.relpath(path, base)
  if type(path) ~= 'string' or path == '' then
    return path
  end
  if type(base) ~= 'string' or base == '' then
    return path
  end
  local ok, rel = pcall(function()
    local function norm(p)
      local abs = vim.fn.fnamemodify(p, ':p')
      abs = abs:gsub('[/\\]+$', '')
      if M.is_windows() then
        abs = abs:gsub('/', '\\')
      end
      return abs
    end
    local p = norm(path)
    local b = norm(base)
    local cmp_p, cmp_b = p, b
    if M.is_windows() then
      cmp_p = p:lower()
      cmp_b = b:lower()
    end
    if cmp_p == cmp_b then
      return '.'
    end
    local sep = M.path_sep()
    if cmp_p:sub(1, #cmp_b + 1) == cmp_b .. sep then
      return p:sub(#cmp_b + 2)
    end
    return path
  end)
  if ok and type(rel) == 'string' then
    return rel
  end
  return path
end

---Walk upward from `start` looking for any of the marker file/dir names.
---@param start string|nil file or directory to start from (default cwd)
---@param markers string[]|nil
---@return string|nil project root
function M.find_root(start, markers)
  local ok, root = pcall(function()
    if type(markers) ~= 'table' or #markers == 0 then
      return nil
    end
    local dir = start
    if type(dir) ~= 'string' or dir == '' then
      dir = vim.fn.getcwd()
    end
    if vim.fn.isdirectory(dir) == 0 then
      dir = vim.fn.fnamemodify(dir, ':h')
    end
    dir = vim.fn.fnamemodify(dir, ':p'):gsub('[/\\]+$', '')
    -- Bound the walk so a pathological path can never spin forever.
    for _ = 1, 64 do
      if dir == '' then
        return nil
      end
      for _, marker in ipairs(markers) do
        if type(marker) == 'string' and marker ~= '' then
          local candidate = M.join(dir, marker)
          if vim.fn.isdirectory(candidate) == 1 or vim.fn.filereadable(candidate) == 1 then
            return dir
          end
        end
      end
      local parent = vim.fn.fnamemodify(dir, ':h')
      if parent == dir or parent == '' then
        return nil
      end
      dir = parent
    end
    return nil
  end)
  if ok and type(root) == 'string' and root ~= '' then
    return root
  end
  return nil
end

---Run a program without a shell and capture its output.
---@param argv string[] non-empty argv list
---@param cwd string|nil
---@param timeout_ms number|nil default 10000
---@return boolean ok, string stdout, string stderr
function M.run_capture(argv, cwd, timeout_ms)
  if type(argv) ~= 'table' or #argv == 0 then
    return false, '', 'run_capture: argv must be a non-empty list'
  end
  if type(vim.system) ~= 'function' then
    return false, '', 'run_capture: vim.system is unavailable (Neovim 0.10+ required)'
  end
  local ok, res = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true }):wait(timeout_ms or 10000)
  end)
  if not ok or type(res) ~= 'table' then
    return false, '', tostring(res)
  end
  local stdout = type(res.stdout) == 'string' and res.stdout or ''
  local stderr = type(res.stderr) == 'string' and res.stderr or ''
  if res.code == 0 then
    return true, stdout, stderr
  end
  if res.code == nil then
    return false, stdout, stderr ~= '' and stderr or 'process was terminated (timeout or signal)'
  end
  return false, stdout, stderr
end

---Quote a single argument for the user's shell.
---@param s string|nil
---@return string
function M.shellescape(s)
  if type(s) ~= 'string' then
    return "''"
  end
  local ok, quoted = pcall(function()
    if M.is_windows() then
      -- shellescape(..., 1) asks Vim to special-case the Windows shell.
      return vim.fn.shellescape(s, 1)
    end
    return vim.fn.shellescape(s)
  end)
  if ok and type(quoted) == 'string' and quoted ~= '' then
    return quoted
  end
  return '"' .. s:gsub('"', '""') .. '"'
end

---Does a file or directory exist?
---@param path string|nil
---@return boolean
function M.exists(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local ok, found = pcall(function()
    return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
  end)
  return ok and found == true
end

---Filename without directory.
---@param path string|nil
---@return string
function M.basename(path)
  if type(path) ~= 'string' or path == '' then
    return ''
  end
  local ok, base = pcall(vim.fn.fnamemodify, path, ':t')
  if ok and type(base) == 'string' then
    return base
  end
  return path
end

---Directory part of a path ('/a/b/c.txt' -> '/a/b').
---@param path string|nil
---@return string
function M.dirname(path)
  if type(path) ~= 'string' or path == '' then
    return ''
  end
  local ok, dir = pcall(vim.fn.fnamemodify, path, ':p:h')
  if ok and type(dir) == 'string' then
    return dir
  end
  return ''
end

---Expand '~' and environment variables in a path.
---@param path string|nil
---@return string
function M.expand(path)
  if type(path) ~= 'string' or path == '' then
    return ''
  end
  local ok, expanded = pcall(vim.fn.expand, path)
  if ok and type(expanded) == 'string' then
    return expanded
  end
  return path
end

---Split a command line into argv (whitespace separated, no quoting support).
---@param cmdline string|nil
---@return string[]
function M.tokenize(cmdline)
  local out = {}
  if type(cmdline) ~= 'string' then
    return out
  end
  pcall(function()
    for token in cmdline:gmatch('%S+') do
      out[#out + 1] = token
    end
  end)
  return out
end

return M
