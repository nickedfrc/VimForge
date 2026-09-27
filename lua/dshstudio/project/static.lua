-- dshstudio/project/static.lua
--
-- Parser-free static dependency analysis for DSH Studio.
--
-- Everything here is best effort and total: a malformed file degrades to fewer
-- facts, never to an error. Heavy work is chunked in batches of 40 files and,
-- when an `on_done` callback is supplied, driven by a libuv timer so the UI is
-- never blocked for more than roughly one batch (~50ms).
--
-- Public functions accept an optional callback: pass `on_done` for the async
-- form (returns true) or omit it to get the result synchronously.
--
-- Lua 5.1 / LuaJIT compatible. Neovim 0.11+ APIs only.

local M = {}

local uv = vim.uv or vim.loop

local BATCH = 40
local MAX_LINES_BYTES = 8 * 1024 * 1024

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function read_lines(path)
  local ok, lines = pcall(function()
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read(MAX_LINES_BYTES)
    f:close()
    if not data then return nil end
    data = data:gsub('\r\n', '\n'):gsub('\r', '\n')
    local out = {}
    for line in (data .. '\n'):gmatch('([^\n]*)\n') do
      out[#out + 1] = line
    end
    if out[#out] == '' then out[#out] = nil end
    return out
  end)
  if ok and type(lines) == 'table' then return lines end
  return nil
end

local function basename(p)
  return (tostring(p or ''):match('([^/\\]+)$')) or tostring(p or '')
end

local function dirname_rel(rel)
  local dir = tostring(rel or ''):match('^(.*)/[^/]*$')
  return dir or ''
end

---Resolve `.` and `..` inside a `/`-separated relative path.
local function normalize_rel(p)
  local cleaned = tostring(p or ''):gsub('\\', '/')
  local parts = {}
  for seg in cleaned:gmatch('[^/]+') do
    if seg == '.' then -- luacheck: ignore
      -- skip
    elseif seg == '..' then
      if #parts > 0 and parts[#parts] ~= '..' then
        table.remove(parts)
      else
        parts[#parts + 1] = '..'
      end
    else
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, '/')
end

local function strip_fortran_comment(line)
  local s = tostring(line or '')
  local quote = nil
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if quote then
      if c == quote then quote = nil end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == '!' then
      return s:sub(1, i - 1)
    end
    i = i + 1
  end
  return s
end

---Strip C/C++ comments and literal bodies from one line (state carried in/out).
local function clean_c_line(line, in_block)
  local s = tostring(line or '')
  local t = trim(s)
  if t:sub(1, 1) == '#' then
    -- Preprocessor lines keep their quotes: #include "..." must survive.
    return s, in_block
  end
  local buf = {}
  local j = 1
  local n = #s
  local in_str = nil
  local block = in_block and true or false
  while j <= n do
    local c = s:sub(j, j)
    local c2 = s:sub(j + 1, j + 1)
    if block then
      if c == '*' and c2 == '/' then
        block = false
        j = j + 2
      else
        j = j + 1
      end
    elseif in_str then
      if c == '\\' then
        j = j + 2
      elseif c == in_str then
        in_str = nil
        buf[#buf + 1] = ' '
        j = j + 1
      else
        j = j + 1
      end
    elseif c == '/' and c2 == '*' then
      block = true
      j = j + 2
    elseif c == '/' and c2 == '/' then
      break
    elseif c == '"' or c == "'" then
      in_str = c
      buf[#buf + 1] = ' '
      j = j + 1
    else
      buf[#buf + 1] = c
      j = j + 1
    end
  end
  return table.concat(buf), block
end

local function files_for_langs(scan_result, langset)
  local out = {}
  if type(scan_result) ~= 'table' or type(langset) ~= 'table' then return out end
  for _, f in ipairs(scan_result.files or {}) do
    if type(f) == 'table' and type(f.path) == 'string' and langset[f.lang] then
      out[#out + 1] = f
    end
  end
  return out
end

---Run `step(index)` over `files` in batches.
---@return boolean async  true when `on_done` will be called later
local function chunked(files, step, finish, on_done)
  local total = #files

  if type(on_done) ~= 'function' then
    -- Synchronous path: run straight through, in batches, with NO yield.
    --
    -- This used to call `vim.wait(1, function() return false end)` after each
    -- batch as a courtesy yield. Measured on an 8-file project it cost ~1 second
    -- per batch - 3 seconds of pure idle for 2 ms of actual scanning - because
    -- vim.wait processes the event loop and can overshoot its timeout by orders of
    -- magnitude. Nothing between batches needs the loop: it is plain Lua plus file
    -- reads, so the yield is removed rather than shortened. Callers that need the
    -- UI to stay responsive pass an `on_done` callback and get the chunked path.
    local i = 1
    while i <= total do
      local stop = math.min(i + BATCH - 1, total)
      for j = i, stop do pcall(step, j) end
      i = stop + 1
    end
    if finish then pcall(finish) end
    return false
  end

  local i = 1
  local finished = false
  local timer = nil

  local function schedule(fn)
    local ok = pcall(vim.schedule, fn)
    if not ok then pcall(fn) end
  end

  local function done()
    if finished then return end
    finished = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
    if finish then pcall(finish) end
    pcall(on_done)
  end

  local function tick()
    if finished then return end
    local stop = math.min(i + BATCH - 1, total)
    for j = i, stop do pcall(step, j) end
    i = stop + 1
    if i > total then schedule(done) end
  end

  if total == 0 then
    schedule(done)
    return true
  end

  local started = false
  if uv and type(uv.new_timer) == 'function' then
    pcall(function()
      timer = uv.new_timer()
      if not timer then return end
      started = true
    end)
  end

  if started and timer then
    -- One timer shot per batch; the batch runs on the main loop through
    -- vim.schedule so callbacks may use the full Neovim API.
    local function arm()
      if finished or not timer then return end
      timer:start(0, 0, function()
        if finished then return end
        schedule(function()
          if finished then return end
          local ok = pcall(tick)
          if not ok then
            schedule(done)
            return
          end
          if not finished and i <= total then arm() end
        end)
      end)
    end
    arm()
    return true
  end

  local function chain()
    if finished then return end
    pcall(tick)
    if not finished and i <= total then schedule(chain) end
  end
  schedule(chain)
  return true
end

--------------------------------------------------------------------------------
-- standard library / intrinsic knowledge
--------------------------------------------------------------------------------

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

M.FORTRAN_INTRINSICS = set_of({
  'abs', 'achar', 'acos', 'acosd', 'acosh', 'adjustl', 'adjustr', 'aimag', 'aint', 'all',
  'allocated', 'anint', 'any', 'asin', 'asind', 'asinh', 'associated', 'atan', 'atan2',
  'atan2d', 'atand', 'atanh', 'bessel_j0', 'bessel_j1', 'bessel_jn', 'bessel_y0', 'bessel_y1',
  'bessel_yn', 'bit_size', 'ble', 'blt', 'btest', 'ceiling', 'char', 'cmplx', 'co_broadcast',
  'co_max', 'co_min', 'co_reduce', 'co_sum', 'command_argument_count', 'conjg', 'cos',
  'cosd', 'cosh', 'count', 'cpu_time', 'cshift', 'date_and_time', 'dble', 'digits', 'dim',
  'dot_product', 'dprod', 'dshiftl', 'dshiftr', 'eoshift', 'epsilon', 'erf', 'erfc',
  'erfc_scaled', 'event_query', 'execute_command_line', 'exp', 'exponent', 'extends_type_of',
  'failed_images', 'findloc', 'floor', 'fraction', 'gamma', 'get_command',
  'get_command_argument', 'get_environment_variable', 'get_team', 'huge', 'hypot', 'iachar',
  'iall', 'iand', 'iany', 'ibclr', 'ibits', 'ibset', 'ichar', 'ieor', 'image_index',
  'image_status', 'index', 'int', 'ior', 'iparity', 'is_iostat_end', 'is_iostat_eor',
  'ishft', 'ishftc', 'isnan', 'kind', 'lbound', 'lcobound', 'leadz', 'len', 'len_trim',
  'lge', 'lgt', 'lle', 'llt', 'log', 'log10', 'log_gamma', 'matmul', 'max', 'maxexponent',
  'maxloc', 'maxval', 'merge', 'merge_bits', 'min', 'minexponent', 'minloc', 'minval', 'mod',
  'modulo', 'move_alloc', 'mvbits', 'nearest', 'new_line', 'nint', 'norm2', 'not', 'null',
  'num_images', 'pack', 'parity', 'popcnt', 'poppar', 'present', 'product', 'radix', 'rand',
  'random_number', 'random_seed', 'range', 'rank', 'real', 'repeat', 'reshape', 'rrspacing',
  'same_type_as', 'scale', 'scan', 'selected_char_kind', 'selected_int_kind',
  'selected_real_kind', 'set_exponent', 'shape', 'shifta', 'shiftl', 'shiftr', 'sign', 'sin',
  'sind', 'sinh', 'size', 'spacing', 'spread', 'sqrt', 'storage_size', 'sum', 'system_clock',
  'tan', 'tand', 'tanh', 'this_image', 'tiny', 'trailz', 'transfer', 'transpose', 'trim',
  'ubound', 'ucobound', 'unpack', 'verify',
})

M.C_STDLIB = set_of({
  'abort', 'abs', 'acos', 'asctime', 'asin', 'assert', 'atan', 'atan2', 'atexit', 'atof',
  'atoi', 'atol', 'bsearch', 'calloc', 'ceil', 'clearerr', 'clock', 'cos', 'cosh', 'ctime',
  'difftime', 'div', 'exit', 'exp', 'fabs', 'fclose', 'feof', 'ferror', 'fflush', 'fgetc',
  'fgetpos', 'fgets', 'floor', 'fmod', 'fopen', 'fprintf', 'fputc', 'fputs', 'fread', 'free',
  'freopen', 'frexp', 'fscanf', 'fseek', 'fsetpos', 'ftell', 'fwrite', 'getc', 'getchar',
  'getenv', 'gets', 'gmtime', 'isalnum', 'isalpha', 'iscntrl', 'isdigit', 'isgraph',
  'islower', 'isprint', 'ispunct', 'isspace', 'isupper', 'isxdigit', 'labs', 'ldexp', 'ldiv',
  'localtime', 'log', 'log10', 'longjmp', 'malloc', 'memchr', 'memcmp', 'memcpy', 'memmove',
  'memset', 'mktime', 'modf', 'perror', 'pow', 'printf', 'putc', 'putchar', 'puts', 'qsort',
  'raise', 'rand', 'realloc', 'remove', 'rename', 'rewind', 'scanf', 'setbuf', 'setjmp',
  'setlocale', 'setvbuf', 'signal', 'sin', 'sinh', 'snprintf', 'sprintf', 'sqrt', 'srand',
  'sscanf', 'strcat', 'strchr', 'strcmp', 'strcoll', 'strcpy', 'strcspn', 'strerror',
  'strftime', 'strlen', 'strncat', 'strncmp', 'strncpy', 'strpbrk', 'strrchr', 'strspn',
  'strstr', 'strtod', 'strtok', 'strtol', 'strtoul', 'strxfrm', 'system', 'tan', 'tanh',
  'time', 'tmpfile', 'tmpnam', 'tolower', 'toupper', 'ungetc', 'va_arg', 'va_end',
  'va_start', 'vfprintf', 'vprintf', 'vsnprintf', 'vscanf', 'vsprintf',
  'fopen_s', 'fprintf_s', 'memcpy_s', 'sprintf_s', 'scanf_s', 'strcat_s', 'strcpy_s',
  'fmax', 'fmin', 'round', 'trunc', 'isnan', 'isinf', 'signbit', 'copysign', 'hypot',
  'nearbyint', 'rint', 'lround', 'llround', 'strtoll', 'strtoull', 'strtof', 'strtold',
})

M.PYTHON_BUILTINS = set_of({
  'abs', 'aiter', 'all', 'anext', 'any', 'ascii', 'bin', 'bool', 'breakpoint', 'bytearray',
  'bytes', 'callable', 'chr', 'classmethod', 'compile', 'complex', 'delattr', 'dict', 'dir',
  'divmod', 'enumerate', 'eval', 'exec', 'filter', 'float', 'format', 'frozenset', 'getattr',
  'globals', 'hasattr', 'hash', 'help', 'hex', 'id', 'input', 'int', 'isinstance',
  'issubclass', 'iter', 'len', 'list', 'locals', 'map', 'max', 'memoryview', 'min', 'next',
  'object', 'oct', 'open', 'ord', 'pow', 'print', 'property', 'range', 'repr', 'reversed',
  'round', 'set', 'setattr', 'slice', 'sorted', 'staticmethod', 'str', 'sum', 'super',
  'tuple', 'type', 'vars', 'zip', '__import__', 'Exception', 'ValueError', 'TypeError',
  'KeyError', 'IndexError', 'RuntimeError', 'StopIteration', 'ZeroDivisionError',
  'AttributeError', 'FileNotFoundError', 'NotImplementedError', 'OSError', 'IOError',
  'AssertionError', 'ImportError', 'OverflowError', 'ArithmeticError', 'LookupError',
  'NameError', 'UnicodeDecodeError', 'Warning',
})

---Is a call target an obvious intrinsic / standard library name?
function M.is_stdlib(name)
  if type(name) ~= 'string' or name == '' then return false end
  local lower = name:lower()
  if M.FORTRAN_INTRINSICS[lower] then return true end
  if M.C_STDLIB[lower] then return true end
  if M.PYTHON_BUILTINS[name] then return true end
  if M.PYTHON_BUILTINS[lower] then return true end
  return false
end

---Names that look like calls but never are (keywords, casts, macros noise).
M.CALL_NOISE = set_of({
  'if', 'for', 'while', 'switch', 'return', 'sizeof', 'defined', 'do', 'else', 'case',
  'catch', 'throw', 'new', 'delete', 'typedef', 'struct', 'union', 'enum', 'class',
  'static_cast', 'dynamic_cast', 'const_cast', 'reinterpret_cast', 'alignof', 'decltype',
  'noexcept', 'static_assert', 'and', 'or', 'not', 'xor', 'assert',
  'def', 'elif', 'with', 'lambda', 'yield', 'raise', 'except', 'del', 'import', 'from',
  'as', 'in', 'is', 'await', 'async', 'global', 'nonlocal', 'pass', 'finally', 'try',
})

--------------------------------------------------------------------------------
-- Fortran
--------------------------------------------------------------------------------

local function parse_fortran_use(stmt)
  -- `stmt` is lower-cased and trimmed, everything after the leading `use`.
  local attrs, modpart = stmt:match('^,%s*(.-)%s*::%s*(.*)$')
  if not attrs then
    attrs, modpart = stmt:match('^(.-)::%s*(.*)$')
  end
  if not modpart then
    attrs, modpart = '', stmt
  end
  local intrinsic = false
  if attrs:find('non_intrinsic', 1, true) then
    intrinsic = false
  elseif attrs:find('intrinsic', 1, true) then
    intrinsic = true
  end
  local name = modpart:match('^([%w_]+)')
  if not name or name == '' then return nil, intrinsic end
  return name, intrinsic
end

M.parse_fortran_use = parse_fortran_use

local function fortran_module_entry(acc, name)
  local m = acc.modules[name]
  if not m then
    m = { defined_in = nil, used_by = {}, _seen = {} }
    acc.modules[name] = m
  end
  return m
end

---Record one call site.
---
---`line` matters: file-level attribution credited a call to every callable symbol
---in the calling file, which produced backwards edges (a function "calling" the
---`main` that calls it, because both lived in one C file). With the line recorded,
---the call can be attributed to the symbol whose range encloses it.
---@param acc table
---@param name string  the callee
---@param rel string   the calling file
---@param line integer|nil  1-based line of the call
local function bump_call(acc, name, rel, line)
  local e = acc.calls[name]
  if not e then
    e = { count = 0, files = {}, lines = {}, _seen = {}, _seen_line = {} }
    acc.calls[name] = e
  end
  e.count = e.count + 1
  if not e._seen[rel] then
    e._seen[rel] = true
    e.files[#e.files + 1] = rel
  end
  if line then
    local key = rel .. ':' .. tostring(line)
    if not e._seen_line[key] then
      e._seen_line[key] = true
      e.lines[#e.lines + 1] = { file = rel, line = line }
    end
  end
end

M.bump_call = bump_call

---Decide whether `name(...)` on a line is a call or an array reference.
---
---Fortran array element access has the same syntax as a function call, so
---`state(1) = state(1) - k * dt` would otherwise report `state` as a callee. The
---argument list is examined instead: an integer literal, a bare bound variable, a
---slice (`a:b`), or an empty pair of parentheses is array syntax, while anything
---with an operator, a real literal or a comma-separated expression is a call.
---@param haystack string  lower-cased source line
---@param name string
---@param from integer  position to start searching from
---@return boolean is_call
local function looks_like_call(haystack, name, from)
  local s = haystack:find(name .. '%s*%(', from)
  if not s then return false end
  local open = haystack:find('(', s + #name, true)
  if not open then return false end
  -- Match the closing parenthesis of this argument list.
  local depth = 0
  local close = nil
  for i = open, #haystack do
    local ch = haystack:sub(i, i)
    if ch == '(' then
      depth = depth + 1
    elseif ch == ')' then
      depth = depth - 1
      if depth == 0 then
        close = i
        break
      end
    end
  end
  if not close then return false end
  local args = trim(haystack:sub(open + 1, close - 1))

  if args == '' then return false end                      -- a() -- index, not call
  if args:match('^%d+$') then return false end              -- a(1)
  if args:match('^%d+%s*:%s*%d*$') then return false end    -- a(1:2), a(1:)
  if args:match('^:%s*%d+$') then return false end          -- a(:2)
  if args == ':' then return false end                      -- a(:)
  if args:match('^[%a_][%w_]*$') then return false end      -- a(n) -- bound variable

  -- A real literal, an arithmetic operator or a comma means a call, because an
  -- array element list cannot contain those.
  return true
end

---Fortran declaration keywords that look like calls because of their parentheses.
---`real, intent(in) :: x` and `real, dimension(n) :: a` are the usual false
---positives once expression function references are scanned for callees.
---
---This table MUST be declared before the function that reads it. A `local`
---declared further down the file is not in scope above its own declaration, so
---the read resolves to a nil global and the whole scan throws inside the
---surrounding pcall - silently producing an empty call graph.
local FORTRAN_ATTRIBUTES = {
  intent = true, dimension = true, allocatable = true, optional = true,
  pointer = true, target = true, parameter = true, save = true, external = true,
  intrinsic = true, public = true, private = true, protected = true,
  contiguous = true, asynchronous = true, volatile = true, value = true,
  bind = true, result = true, len = true, recursive = true,
  pure = true, elemental = true, impure = true, module = true, procedure = true,
  -- Intrinsic inquiry and manipulation functions: real calls, but not project
  -- symbols, so they only add noise to a call tree.
  -- (`kind` is deliberately absent: `kind(x)` is a common intrinsic, and
  -- filtering it would also hide a project function of the same name.)
  trim = true, ['len_trim'] = true, present = true, allocated = true,
  associated = true, ['null'] = true, ['size'] = true, shape = true,
}

local function process_fortran_file(f, acc)  if type(f) ~= 'table' or type(f.path) ~= 'string' then return end
  local lines = read_lines(f.path)
  if not lines then return end
  local rel = f.rel or f.path
  local uses_here = acc.uses[rel]
  if not uses_here then
    uses_here = {}
    acc.uses[rel] = uses_here
  end
  local seen_here = {}

  for line_no, raw in ipairs(lines) do
    local code = strip_fortran_comment(raw)
    local text = trim(code)
    if text ~= '' then
      local lower = text:lower()

      local defname = lower:match('^module%s+([%w_]+)%s*$')
      if defname and defname ~= 'procedure' then
        local m = fortran_module_entry(acc, defname)
        if not m.defined_in then m.defined_in = rel end
      end
      local subname = lower:match('^submodule%s*%b()%s*([%w_]+)')
      if subname then
        local m = fortran_module_entry(acc, subname)
        if not m.defined_in then m.defined_in = rel end
      end

      local use_stmt = lower:match('^use%s+(.*)$')
      if use_stmt then
        local name, intrinsic = parse_fortran_use(use_stmt)
        if name and not intrinsic then
          local m = fortran_module_entry(acc, name)
          if not m._seen[rel] then
            m._seen[rel] = true
            m.used_by[#m.used_by + 1] = rel
          end
          if not seen_here[name] then
            seen_here[name] = true
            uses_here[#uses_here + 1] = name
          end
        end
      end

      for cname in lower:gmatch('%f[%w]call%f[%W]%s+([%w_]+)') do
        -- Skip type-bound calls: `call obj%method()`.
        if not lower:find('call%s+' .. cname .. '%%') then
          bump_call(acc, cname, rel, line_no)
        end
      end

      -- Fortran also calls through expression function references, most often
      -- `x = f(...)`, which the `call` scan above cannot see. Requiring an
      -- assignment or an operator before the name keeps declarations
      -- (`real :: f`) and type components (`obj%f(`) out of the results.
      --
      -- Type declarations are skipped: their parentheses are attribute syntax,
      -- not calls. Fortran marks the declaration part with `::`, which is the
      -- reliable signal - `real, intent(in) :: conc` has no assignment, while
      -- `k = rate_law(...)` does. The attribute name filter below then removes
      -- anything that still slips through.
      local declares = lower:match('::') ~= nil
        or lower:match('^%s*real%f[%W]') ~= nil
        or lower:match('^%s*integer%f[%W]') ~= nil
        or lower:match('^%s*logical%f[%W]') ~= nil
        or lower:match('^%s*character%f[%W]') ~= nil
        or lower:match('^%s*complex%f[%W]') ~= nil
        or lower:match('^%s*double%s+precision%f[%W]') ~= nil
        or lower:match('^%s*type%s*%(') ~= nil
        or lower:match('^%s*class%s*%(') ~= nil
      if not declares then
        -- Iterate call-like references on this line. `find` with a capture returns
        -- the capture's start, and the pattern consumes the character before the
        -- name (an operator or a comma), so the cursor must advance to just before
        -- that position. Advancing by `name_start + #name` re-finds the same
        -- prefix and the loop never terminates; `fuel` is a hard stop so a future
        -- pattern change cannot hang the scanner.
        local cursor = 1
        local fuel = 0
        while fuel < 64 do
          fuel = fuel + 1
          local search_from = cursor > 1 and (cursor - 1) or 1
          -- string.find returns the match START, then the match END, and only
          -- then the captures. Reading `local pos, name = find(pat)` therefore
          -- puts the END position in `name`, which is why the whole scan silently
          -- produced nothing. The middle value is discarded explicitly.
          local name_start, _match_end, cname = lower:find('[=+%*%/%-,%(]%s*([%a_][%w_]*)%s*%(', search_from)
          if type(cname) ~= 'string' or type(name_start) ~= 'number' then break end
          local next_cursor = name_start + 1
          if next_cursor <= cursor then next_cursor = cursor + 1 end
          cursor = next_cursor
          if not FORTRAN_ATTRIBUTES[cname]
            and not M.CALL_NOISE[cname]
            and not M.is_stdlib(cname) then
            local bound = lower:match('%%%s*' .. cname .. '%s*%(')
            -- Search from the line start: the name was already isolated by the
            -- pattern above and its '(' comes after the name, so a start position
            -- at or past the name would never find it.
            if not bound and looks_like_call(lower, cname, 1) then
              bump_call(acc, cname, rel, line_no)
            end
          end
        end
      end

      if lower:match('^include%s') then
        local inc = text:match('^%a+%s*[\'"]([^\'"]+)[\'"]')
        if inc then
          local list = acc.includes[rel]
          if not list then
            list = {}
            acc.includes[rel] = list
          end
          list[#list + 1] = inc
        end
      end
    end
  end

  table.sort(uses_here)
end

---Fortran `USE` / `CALL` / `INCLUDE` analysis.
---@param scan_result table
---@param on_done fun(result:table)|nil
---@return table|boolean result when synchronous, true when async
function M.fortran_uses(scan_result, on_done)
  local acc = { modules = {}, calls = {}, includes = {}, uses = {} }
  local ok, async = pcall(function()
    local files = files_for_langs(scan_result, { fortran = true })
    local function step(j) process_fortran_file(files[j], acc) end
    local function finish()
      for _, m in pairs(acc.modules) do
        m._seen = nil
        table.sort(m.used_by)
      end
      for _, e in pairs(acc.calls) do
        e._seen = nil
        table.sort(e.files)
      end
      for rel, list in pairs(acc.includes) do
        table.sort(list)
        acc.includes[rel] = list
      end
    end
    return chunked(files, step, finish, type(on_done) == 'function' and function()
      pcall(on_done, acc)
    end or nil)
  end)
  if not ok then
    if type(on_done) == 'function' then pcall(on_done, acc) end
    return acc
  end
  if async then return true end
  return acc
end

--------------------------------------------------------------------------------
-- C / C++
--------------------------------------------------------------------------------

local function build_include_resolver(scan_result)
  local by_rel = {}
  local by_base = {}
  pcall(function()
    for _, f in ipairs(scan_result and scan_result.files or {}) do
      if type(f) == 'table' and type(f.rel) == 'string' then
        by_rel[f.rel] = true
        local b = basename(f.rel)
        local list = by_base[b]
        if not list then
          list = {}
          by_base[b] = list
        end
        list[#list + 1] = f.rel
      end
    end
    for _, list in pairs(by_base) do table.sort(list) end
  end)

  return function(from_rel, inc)
    local cleaned = tostring(inc or ''):gsub('\\', '/')
    if cleaned == '' then return cleaned end
    local dir = dirname_rel(from_rel)
    if dir ~= '' then
      local candidate = normalize_rel(dir .. '/' .. cleaned)
      if by_rel[candidate] then return candidate end
    end
    local root_candidate = normalize_rel(cleaned)
    if by_rel[root_candidate] then return root_candidate end
    local list = by_base[basename(cleaned)]
    if list and #list > 0 then return list[1] end
    return cleaned
  end
end

local function process_c_file(f, acc, resolve_include)
  if type(f) ~= 'table' or type(f.path) ~= 'string' then return end
  local lines = read_lines(f.path)
  if not lines then return end
  local rel = f.rel or f.path
  local entry = { ['local'] = {}, system = {} }
  acc.includes[rel] = entry
  local seen = { ['local'] = {}, system = {} }
  local in_block = false
  for line_no, raw in ipairs(lines) do
    local cleaned
    cleaned, in_block = clean_c_line(raw, in_block)
    local quoted = cleaned:match('^%s*#%s*include%s*"([^"]+)"')
    local angled = cleaned:match('^%s*#%s*include%s*<([^>]+)>')
    if quoted then
      local resolved = resolve_include(rel, quoted)
      if not seen['local'][resolved] then
        seen['local'][resolved] = true
        entry['local'][#entry['local'] + 1] = resolved
      end
    elseif angled then
      local sys = trim(angled)
      if not seen.system[sys] then
        seen.system[sys] = true
        entry.system[#entry.system + 1] = sys
      end
    else
      local text = trim(cleaned)
      if text ~= '' and text:sub(1, 1) ~= '#' then
        for name in text:gmatch('([%a_][%w_]*)%s*%(') do
          if not M.CALL_NOISE[name] and not M.is_stdlib(name) then
            bump_call(acc, name, rel, line_no)
          end
        end
      end
    end
  end

  table.sort(entry['local'])
  table.sort(entry.system)
end

---C/C++ `#include` and rough call-site analysis.
---@return table|boolean
function M.c_deps(scan_result, on_done)
  local acc = { includes = {}, calls = {} }
  local ok, async = pcall(function()
    local files = files_for_langs(scan_result, { c = true, cpp = true })
    local resolve = build_include_resolver(scan_result)
    local function step(j) process_c_file(files[j], acc, resolve) end
    local function finish()
      for _, e in pairs(acc.calls) do
        e._seen = nil
        table.sort(e.files)
      end
    end
    return chunked(files, step, finish, type(on_done) == 'function' and function()
      pcall(on_done, acc)
    end or nil)
  end)
  if not ok then
    if type(on_done) == 'function' then pcall(on_done, acc) end
    return acc
  end
  if async then return true end
  return acc
end

--------------------------------------------------------------------------------
-- Python
--------------------------------------------------------------------------------

local function python_module_name(rel)
  local name = tostring(rel or ''):gsub('\\', '/')
  name = name:gsub('%.py$', '')
  name = name:gsub('%.pyi$', '')
  name = name:gsub('/__init__$', '')
  name = name:gsub('^__init__$', '')
  name = name:gsub('/', '.')
  return name
end

M.python_module_name = python_module_name

local function build_python_index(files)
  local mods = {}
  local prefixes = {}
  for _, f in ipairs(files) do
    local modname = python_module_name(f.rel or f.path or '')
    if modname ~= '' then
      mods[modname] = f.rel or f.path
      local acc = {}
      for part in modname:gmatch('[^%.]+') do
        acc[#acc + 1] = part
        prefixes[table.concat(acc, '.')] = true
      end
    end
  end
  return mods, prefixes
end

local function add_unique(list, seen, value)
  if type(value) ~= 'string' or value == '' then return end
  if seen[value] then return end
  seen[value] = true
  list[#list + 1] = value
end

local function split_commas(s)
  local out = {}
  for part in tostring(s or ''):gmatch('[^,]+') do
    local item = trim(part)
    item = item:gsub('%s+as%s+[%w_]+$', '')
    item = trim(item)
    item = item:gsub('^%(%s*', ''):gsub('%s*%)$', '')
    if item ~= '' then out[#out + 1] = item end
  end
  return out
end

local function process_python_file(f, acc, prefixes)
  if type(f) ~= 'table' or type(f.path) ~= 'string' then return end
  local lines = read_lines(f.path)
  if not lines then return end
  local rel = f.rel or f.path
  local entry = acc.imports[rel]
  if not entry then
    entry = { ['local'] = {}, external = {} }
    acc.imports[rel] = entry
  end
  if not entry._seen then
    entry._seen = { ['local'] = {}, external = {} }
  end
  local pkg = dirname_rel(rel):gsub('/', '.')
  if rel:match('^[^/]+$') then pkg = '' end

  for _, raw in ipairs(lines) do
    local line = tostring(raw or '')
    local text = trim(line)
    if text ~= '' and text:sub(1, 1) ~= '#' then
      local import_list = text:match('^import%s+(.+)$')
      if import_list then
        for _, item in ipairs(split_commas(import_list)) do
          local modname = item:match('^([%w_%.]+)')
          if modname then
            if prefixes[modname] or prefixes[modname:match('^([%w_]+)') or ''] then
              add_unique(entry['local'], entry._seen['local'], modname)
            else
              add_unique(entry.external, entry._seen.external, modname)
            end
          end
        end
      else
        local from_mod, from_names = text:match('^from%s+([%w_%.]+)%s+import%s+(.+)$')
        if from_mod then
          local dots = 0
          while from_mod:sub(dots + 1, dots + 1) == '.' do dots = dots + 1 end
          local rest = from_mod:sub(dots + 1)
          if dots > 0 then
            local base = pkg
            for _ = 2, dots do
              base = base:match('^(.*)%.[^%.]*$') or ''
            end
            local head = base
            if rest ~= '' then
              head = (base ~= '' and (base .. '.' .. rest)) or rest
            end
            if rest == '' then
              for _, name in ipairs(split_commas(from_names)) do
                local leaf = name:match('^([%w_]+)')
                if leaf then
                  local modname = (head ~= '' and (head .. '.' .. leaf)) or leaf
                  add_unique(entry['local'], entry._seen['local'], modname)
                end
              end
            else
              add_unique(entry['local'], entry._seen['local'], head)
              -- `from .mod import name` may also pull in submodules.
              for _, name in ipairs(split_commas(from_names)) do
                local leaf = name:match('^([%w_]+)')
                if leaf and prefixes[head .. '.' .. leaf] then
                  add_unique(entry['local'], entry._seen['local'], head .. '.' .. leaf)
                end
              end
            end
          elseif prefixes[rest] or prefixes[from_mod] then
            add_unique(entry['local'], entry._seen['local'], from_mod)
          else
            add_unique(entry.external, entry._seen.external, from_mod)
          end
        end
      end
    end
  end

  table.sort(entry['local'])
  table.sort(entry.external)
  entry._seen = nil
end

---Python import analysis with relative-import resolution.
---@return table|boolean
function M.python_deps(scan_result, on_done)
  local acc = { imports = {} }
  local ok, async = pcall(function()
    local files = files_for_langs(scan_result, { python = true })
    local _mods, prefixes = build_python_index(files)
    local function step(j) process_python_file(files[j], acc, prefixes) end
    return chunked(files, step, nil, type(on_done) == 'function' and function()
      pcall(on_done, acc)
    end or nil)
  end)
  if not ok then
    if type(on_done) == 'function' then pcall(on_done, acc) end
    return acc
  end
  if async then return true end
  return acc
end

---Convenience: run every dependency pass and hand back one merged table.
---This is the synchronous form; it exists for scripts and tests.
---@param scan_result table
---@return table { fortran = table, c = table, python = table }
function M.all_deps(scan_result)
  local out = {
    fortran = { modules = {}, calls = {}, includes = {}, uses = {} },
    c = { includes = {}, calls = {} },
    python = { imports = {} },
  }
  pcall(function()
    out.fortran = M.fortran_uses(scan_result)
    out.c = M.c_deps(scan_result)
    out.python = M.python_deps(scan_result)
  end)
  return out
end

--------------------------------------------------------------------------------
-- call graph
--------------------------------------------------------------------------------

local CALLABLE_KINDS = {
  ['function'] = true, subroutine = true, method = true, program = true,
}

local function collect_calls(deps)
  local merged = {}
  local function absorb(d)
    if type(d) ~= 'table' then return end
    for name, info in pairs(d.calls or {}) do
      if type(name) == 'string' and type(info) == 'table' then
        local e = merged[name]
        if not e then
          e = { count = 0, files = {}, lines = {}, _seen = {}, _seen_line = {} }
          merged[name] = e
        end
        e.count = e.count + (tonumber(info.count) or 0)
        for _, rel in ipairs(info.files or {}) do
          if type(rel) == 'string' and not e._seen[rel] then
            e._seen[rel] = true
            e.files[#e.files + 1] = rel
          end
        end
        -- Call sites, so the graph can be attributed per symbol rather than per file.
        for _, site in ipairs(info.lines or {}) do
          if type(site) == 'table' and type(site.file) == 'string' and type(site.line) == 'number' then
            local key = site.file .. ':' .. tostring(site.line)
            if not e._seen_line[key] then
              e._seen_line[key] = true
              e.lines[#e.lines + 1] = { file = site.file, line = site.line }
            end
          end
        end
      end
    end
  end
  if type(deps) == 'table' then
    if deps.calls then absorb(deps) end
    -- Accept a list (`{fortran, c, python}`), a map (`{fortran=.., c=..}`) or
    -- any mixture, including tables with holes.
    for _, d in pairs(deps) do
      if type(d) == 'table' and d ~= deps and d.calls then absorb(d) end
    end
  end
  for _, e in pairs(merged) do
    e._seen = nil
    e._seen_line = nil
  end
  return merged
end

M.collect_calls = collect_calls

---Choose the symbol that owns a call site.
---
---The tightest range wins, so a nested subroutine is preferred over the module
---that contains it. Falls back to the file's only callable symbol, which is the
---common case for a small file, and to nil when the file defines several and the
---line falls outside all of them.
---@param list table[]  symbols of the calling file
---@param line integer  1-based line of the call
---@return string|nil
local function owner_of_call(list, line)
  local best, best_span = nil, nil
  local callables = {}
  for _, s in ipairs(list or {}) do
    if type(s) == 'table' and type(s.name) == 'string' and CALLABLE_KINDS[s.kind] then
      callables[#callables + 1] = s
      local start = tonumber(s.line)
      local stop = tonumber(s.end_line) or start
      if start and line >= start and line <= stop then
        local span = stop - start
        if not best_span or span < best_span then
          best, best_span = s.name, span
        end
      end
    end
  end
  if best then return best end
  if #callables == 1 then return callables[1].name end
  return nil
end

---Adjacency list of the call graph, standard-library names removed.
---
---Calls are attributed to the symbol whose range encloses the call site, which
---needs the line recorded by the scanners. When a call site has no line (an older
---deps table, or a language whose scanner does not record one) the file's single
---callable symbol is used; a file that defines several and yields no enclosing
---range contributes no edge rather than a wrong one.
---@param deps table|table[] one deps table or a list of them
---@param symbols_by_file table
---@param on_done fun(adjacency:table)|nil
---@return table adjacency
function M.call_graph(deps, symbols_by_file, on_done)
  local adj = {}
  local ok = pcall(function()
    local call_sets = collect_calls(deps)
    local file_syms = {}
    local file_callables = {}
    for rel, list in pairs(symbols_by_file or {}) do
      if type(list) == 'table' then
        local names = {}
        local seen = {}
        for _, s in ipairs(list) do
          if type(s) == 'table' and type(s.name) == 'string' then
            local kind = s.kind
            if CALLABLE_KINDS[kind] and not seen[s.name] then
              seen[s.name] = true
              names[#names + 1] = s.name
            end
          end
        end
        table.sort(names)
        file_syms[rel] = names
        file_callables[rel] = list
      end
    end

    local function node(name)
      local n = adj[name]
      if not n then
        n = { calls = {}, called_by = {}, _out = {}, _in = {} }
        adj[name] = n
      end
      return n
    end

    for _, names in pairs(file_syms) do
      for _, nm in ipairs(names) do node(nm) end
    end

    local function link(caller, cname)
      if caller == cname then return end
      local from = node(caller)
      local to = node(cname)
      if not from._out[cname] then
        from._out[cname] = true
        from.calls[#from.calls + 1] = cname
      end
      if not to._in[caller] then
        to._in[caller] = true
        to.called_by[#to.called_by + 1] = caller
      end
    end

    for cname, info in pairs(call_sets) do
      if not M.is_stdlib(cname) and not M.CALL_NOISE[cname] then
        node(cname)
        local used_site = false
        for _, site in ipairs(info.lines or {}) do
          local owner = owner_of_call(file_callables[site.file] or {}, site.line)
          if owner then
            link(owner, cname)
            used_site = true
          end
        end
        if not used_site then
          -- No usable call-site line: fall back to file-level attribution, which
          -- is coarse but never empty.
          for _, rel in ipairs(info.files) do
            for _, caller in ipairs(file_syms[rel] or {}) do
              link(caller, cname)
            end
          end
        end
      end
    end

    for _, n in pairs(adj) do
      table.sort(n.calls)
      table.sort(n.called_by)
      n._out = nil
      n._in = nil
    end
  end)
  if type(on_done) == 'function' then
    pcall(vim.schedule, function() pcall(on_done, adj) end)
  end
  if not ok then return adj end
  return adj
end

---Highest in-degree callees, for the "call graph highlights" report section.
---@param graph table adjacency from `call_graph`
---@param limit integer|nil
---@return table[] { { name, count, callers = {..} }, ... }
function M.top_callees(graph, limit)
  local out = {}
  pcall(function()
    for name, node in pairs(graph or {}) do
      if type(node) == 'table' then
        local callers = node.called_by or {}
        out[#out + 1] = {
          name = name,
          count = #callers,
          calls = #(node.calls or {}),
          callers = callers,
        }
      end
    end
    table.sort(out, function(a, b)
      if a.count == b.count then
        if a.calls == b.calls then return a.name < b.name end
        return a.calls > b.calls
      end
      return a.count > b.count
    end)
    local max = tonumber(limit) or 30
    while #out > max do table.remove(out) end
  end)
  return out
end

--------------------------------------------------------------------------------
-- project structure
--------------------------------------------------------------------------------

local TYPE_KINDS = {
  type = true, class = true, struct = true, enum = true, union = true,
}

local function python_has_main(f)
  if type(f) ~= 'table' or type(f.path) ~= 'string' then return false end
  local lines = read_lines(f.path)
  if not lines then return false end
  for _, raw in ipairs(lines) do
    local text = trim(raw)
    if text:match('^if%s+__name__%s*==%s*[\'"]__main__[\'"]') then return true end
  end
  return false
end

---Project structure: modules, entry points, types and the largest files.
---@param scan_result table
---@param symbols_by_file table
---@param on_done fun(result:table)|nil
---@return table|boolean
function M.structure(scan_result, symbols_by_file, on_done)
  local acc = { modules = {}, entry_points = {}, types = {}, largest = {} }
  local ok, async = pcall(function()
    local lang_of = {}
    local all_files = {}
    for _, f in ipairs(scan_result and scan_result.files or {}) do
      if type(f) == 'table' and f.rel then
        lang_of[f.rel] = f.lang
        all_files[#all_files + 1] = f
      end
    end

    local rels = {}
    for rel in pairs(symbols_by_file or {}) do rels[#rels + 1] = rel end
    table.sort(rels)
    for _, rel in ipairs(rels) do
      local list = symbols_by_file[rel]
      if type(list) == 'table' then
        local lang = lang_of[rel]
        for _, s in ipairs(list) do
          if type(s) == 'table' and type(s.name) == 'string' then
            local kind = s.kind
            if kind == 'module' or kind == 'namespace' then
              acc.modules[#acc.modules + 1] = {
                name = s.name, rel = rel, line = s.line, kind = kind,
              }
            end
            if kind == 'program' then
              acc.entry_points[#acc.entry_points + 1] = {
                name = s.name, rel = rel, line = s.line, kind = 'program',
              }
            end
            if kind == 'function' and s.name == 'main' and (lang == 'c' or lang == 'cpp') then
              acc.entry_points[#acc.entry_points + 1] = {
                name = 'main', rel = rel, line = s.line, kind = 'main',
              }
            end
            if TYPE_KINDS[kind] then
              acc.types[#acc.types + 1] = {
                name = s.name, rel = rel, line = s.line, kind = kind,
                parent = s.parent or nil,
              }
            end
          end
        end
      end
    end

    local by_size = {}
    for _, f in ipairs(all_files) do
      if f.lang ~= 'binary' then
        by_size[#by_size + 1] = { rel = f.rel, lines = tonumber(f.lines) or 0 }
      end
    end
    table.sort(by_size, function(a, b)
      if a.lines == b.lines then return a.rel < b.rel end
      return a.lines > b.lines
    end)
    for i = 1, math.min(15, #by_size) do
      acc.largest[#acc.largest + 1] = by_size[i]
    end

    local pyfiles = files_for_langs(scan_result, { python = true })
    local function step(j)
      local f = pyfiles[j]
      if python_has_main(f) then
        acc.entry_points[#acc.entry_points + 1] = {
          name = "__main__", rel = f.rel or f.path, line = nil, kind = 'python_main',
        }
      end
    end
    local function finish()
      local function by_rel_line(a, b)
        if a.rel == b.rel then return (a.line or 0) < (b.line or 0) end
        return a.rel < b.rel
      end
      table.sort(acc.modules, by_rel_line)
      table.sort(acc.entry_points, by_rel_line)
      table.sort(acc.types, by_rel_line)
    end
    return chunked(pyfiles, step, finish, type(on_done) == 'function' and function()
      pcall(on_done, acc)
    end or nil)
  end)
  if not ok then
    if type(on_done) == 'function' then pcall(on_done, acc) end
    return acc
  end
  if async then return true end
  return acc
end

return M
