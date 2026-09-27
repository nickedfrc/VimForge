-- dshstudio/project/symbols.lua
--
-- Symbol extraction for DSH Studio's deepwiki-style analysis.
--
-- Strategy:
--   1. Try a tree-sitter parser when one is installed, using a probe so that
--      unknown/incompatible node types never poison the query (parser grammars
--      differ in node naming, e.g. Fortran `subroutine` vs `subroutine_statement`).
--   2. Fall back to a hand-written, parser-free regex extractor whenever the
--      tree-sitter path is unavailable, its query fails, or it yields nothing.
--
-- The regex path is the contract: it must work on a bare Neovim 0.11 install
-- with no parsers at all.
--
-- Lua 5.1 / LuaJIT compatible. Nothing in this module throws.

local M = {}

local uv = vim.uv or vim.loop

local MAX_SIG = 160
local MAX_LINES_BYTES = 8 * 1024 * 1024

local EXTRACT_LANGS = { fortran = true, c = true, cpp = true, python = true }

M.KINDS = {
  'module', 'program', 'subroutine', 'function', 'interface', 'type', 'procedure',
  'class', 'struct', 'method', 'enum', 'union', 'macro', 'namespace', 'global',
}

-- Kinds that introduce a lexical scope we can nest symbols inside of.
local CONTAINER_KINDS = {
  module = true, program = true, type = true, interface = true,
  class = true, struct = true, union = true, namespace = true,
  subroutine = true, ['function'] = true, method = true,
}

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function sig_of(line)
  local s = tostring(line or ''):gsub('\t', ' ')
  s = trim(s)
  if s == '' then return nil end
  if #s > MAX_SIG then s = s:sub(1, MAX_SIG - 3) .. '...' end
  return s
end

---Strip a UTF-8 or UTF-16 byte-order mark.
---
---Windows editors (Visual Studio, Notepad, and PowerShell's `Set-Content
----Encoding UTF8`) write a BOM by default. A leading BOM stops `^module` and
---`^program` from matching on the first line, so the primary declaration of a
---file would silently disappear from the outline.
---@param data string
---@return string
local function strip_bom(data)
  if data:sub(1, 3) == '\239\187\191' then return data:sub(4) end   -- EF BB BF (UTF-8)
  if data:sub(1, 2) == '\255\254' then return data:sub(3) end       -- FF FE (UTF-16 LE)
  if data:sub(1, 2) == '\254\255' then return data:sub(3) end       -- FE FF (UTF-16 BE)
  return data
end

local function read_lines(path)
  local ok, lines = pcall(function()
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read(MAX_LINES_BYTES)
    f:close()
    if not data then return nil end
    data = strip_bom(data)
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

local function count_parens(s)
  local open, close = 0, 0
  for j = 1, #s do
    local c = s:sub(j, j)
    if c == '(' then
      open = open + 1
    elseif c == ')' then
      close = close + 1
    end
  end
  return open, close
end

---Join `lines` from `i` until parentheses balance (bounded, blank-line aware).
local function join_until_balanced(lines, i, max_extra)
  local text = lines[i] or ''
  local open, close = count_parens(text)
  local j = i
  local extra = 0
  while open > close and extra < max_extra do
    local nxt = lines[j + 1]
    if nxt == nil then break end
    if trim(nxt) == '' then break end
    j = j + 1
    extra = extra + 1
    text = text .. ' ' .. trim(nxt)
    local o2, c2 = count_parens(nxt)
    open = open + o2
    close = close + c2
  end
  return text, j
end

---First non-blank line at or after `from` (bounded), on a pre-cleaned table.
local function next_code_line(lines, from, limit)
  local j = from
  local seen = 0
  while lines[j] and seen < (limit or 4) do
    local t = trim(lines[j])
    if t ~= '' then return t, j end
    j = j + 1
    seen = seen + 1
  end
  return nil, nil
end

--------------------------------------------------------------------------------
-- Fortran regex extractor
--------------------------------------------------------------------------------

local FORTRAN_BAD_PREFIX = {
  ['end'] = true, call = true, use = true, ['if'] = true, ['then'] = true, ['else'] = true,
  ['do'] = true, ['while'] = true, select = true, case = true, interface = true, contains = true,
  allocate = true, deallocate = true, write = true, read = true, print = true, open = true,
  close = true, rewind = true, backspace = true, ['return'] = true, ['goto'] = true, ['to'] = true,
  nullify = true, associate = true, ['where'] = true, forall = true, ['stop'] = true,
  error = true, public = true, private = true, protected = true, save = true, pointer = true,
  target = true, allocatable = true, dimension = true, intent = true, optional = true,
  parameter = true, external = true, intrinsic = true, namelist = true, import = true,
  only = true, result = true, bind = true, value = true, volatile = true, operator = true,
  assignment = true, generic = true, final = true, deferred = true, abstract = true,
  extends = true, enumerate = true, sequence = true, contiguous = true, asynchronous = true,
}

local FORTRAN_LAST_OK = {
  recursive = true, pure = true, elemental = true, impure = true, module = true,
  non_recursive = true, integer = true, real = true, complex = true, ['logical'] = true,
  character = true, double = true, precision = true, type = true, class = true,
  procedure = true,
}

local function fortran_prefix_ok(prefix)
  local p = trim(tostring(prefix or ''):lower())
  if p == '' then return true end
  p = p:gsub('%b()', ' ')
  p = p:gsub('%.%.%.', ' ')
  if p:find('=', 1, true) or p:find('%%', 1, true) then return false end
  local tokens = {}
  for t in p:gmatch('%S+') do tokens[#tokens + 1] = t end
  if #tokens == 0 then return true end
  for _, t in ipairs(tokens) do
    if FORTRAN_BAD_PREFIX[t] then return false end
  end
  local last = tokens[#tokens]
  if FORTRAN_LAST_OK[last] then return true end
  if last:match('^%a[%w_]*%*%d+$') then return true end
  if last:match('^%a[%w_]*_%w+$') then return true end
  return false
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

local FORTRAN_TYPE_BAD_NAME = { is = true, default = true }

local function fortran_match_callable(s)
  for _, kind in ipairs({ 'subroutine', 'function' }) do
    local prefix, name, tail = s:match('^(.-)' .. kind .. '%s+([%w_]+)%s*(.*)$')
    if name and fortran_prefix_ok(prefix) then
      if tail == '' or tail:sub(1, 1) == '(' then
        return name, kind
      end
    end
  end
  return nil
end

local function fortran_match_module(s)
  local name = s:match('^submodule%s*%b()%s*([%w_]+)')
  if name then return name end
  name = s:match('^module%s+([%w_]+)%s*$')
  if name and name ~= 'procedure' then return name end
  return nil
end

local function fortran_match_type(s)
  local name = s:match('^type%s*,.-::%s*([%w_]+)')
  if name and not FORTRAN_TYPE_BAD_NAME[name] then return name end
  name = s:match('^type%s*::%s*([%w_]+)')
  if name and not FORTRAN_TYPE_BAD_NAME[name] then return name end
  name = s:match('^type%s+([%w_]+)%s*$')
  if name and not FORTRAN_TYPE_BAD_NAME[name] then return name end
  return nil
end

local function fortran_match_interface(s)
  local rest = s:match('^interface%f[%W](.*)$') or s:match('^abstract%s+interface%f[%W](.*)$')
  if rest == nil then return nil end
  local name = trim(rest)
  if name == '' then return nil end
  return (name:gsub('%s+', ''))
end

local function fortran_match_procedure(s)
  local name = s:match('^module%s+procedure%s+([%w_]+)')
  if name then return name end
  name = s:match('^procedure%s*%b()%s*.-::%s*([%w_]+)')
  if name then return name end
  name = s:match('^procedure%s*,.-::%s*([%w_]+)')
  if name then return name end
  name = s:match('^procedure%s*::%s*([%w_]+)')
  if name then return name end
  name = s:match('^procedure%s*%b()%s*([%w_]+)%s*$')
  if name then return name end
  return nil
end

---Signature for a Fortran definition, honouring free-form `&` continuations.
local function fortran_signature(lines, i, code)
  local text = trim(code)
  local j = i
  local guard = 0
  while text:sub(-1) == '&' and guard < 3 do
    local nxt = lines[j + 1]
    if nxt == nil then break end
    j = j + 1
    guard = guard + 1
    local continuation = trim(strip_fortran_comment(nxt))
    if continuation:sub(1, 1) == '&' then continuation = trim(continuation:sub(2)) end
    text = trim(text:sub(1, -2)) .. ' ' .. continuation
  end
  return sig_of(text)
end

local FORTRAN_CONTAINER_KIND = {
  module = true, program = true, type = true, interface = true,
  subroutine = true, ['function'] = true,
}

local function extract_fortran(lines)
  local out = {}
  local stack = {}

  local function top_container()
    for i = #stack, 1, -1 do
      if stack[i].container then return stack[i].name end
    end
    return nil
  end

  local function close_top(end_line)
    local fr = table.remove(stack)
    if fr and fr.sym and not fr.sym.end_line then
      local el = end_line
      if type(el) ~= 'number' or el < fr.sym.line then el = fr.sym.line end
      fr.sym.end_line = el
    end
    return fr
  end

  local function close_until(kind, line_no)
    local idx = nil
    for i = #stack, 1, -1 do
      if stack[i].kind == kind then
        idx = i
        break
      end
    end
    if not idx then return false end
    while #stack > idx do close_top(line_no - 1) end
    close_top(line_no)
    return true
  end

  local END_MAP = {
    subroutine = 'subroutine', ['function'] = 'function', module = 'module',
    program = 'program', type = 'type', interface = 'interface',
    procedure = 'procedure', submodule = 'module', blockdata = 'program',
  }

  for i, raw in ipairs(lines) do
    local code = strip_fortran_comment(raw)
    local s = trim(code:lower())
    if s ~= '' then s = trim(s:gsub('^%d+%s+', '')) end
    if s ~= '' then
      local handled = false

      -- end statements -----------------------------------------------------
      if s == 'end' then
        close_top(i)
        handled = true
      else
        local rest = s:match('^end%s+(.*)$')
        local ekind = nil
        if rest then
          if rest:match('^block%s+data') then
            ekind = 'blockdata'
          else
            ekind = rest:match('^([%a][%w_]*)')
          end
        else
          ekind = s:match('^end([%a][%w_]*)%s*$')
          if ekind == 'blockdata' then ekind = 'blockdata' end
        end
        local mapped = ekind and END_MAP[ekind] or nil
        if mapped then
          close_until(mapped, i)
          handled = true
        end
      end

      -- definitions --------------------------------------------------------
      if not handled then
        local name, kind = fortran_match_callable(s)
        if not name then
          name = fortran_match_module(s)
          if name then kind = 'module' end
        end
        if not name then
          name = s:match('^program%s+([%w_]+)')
          if name then kind = 'program' end
        end
        if not name then
          local bd = s:match('^block%s*data%s*([%w_]*)')
          if bd ~= nil then
            name = (bd ~= '' and bd) or ('block_data_%d'):format(i)
            kind = 'program'
          end
        end
        if not name then
          name = fortran_match_type(s)
          if name then kind = 'type' end
        end
        if not name then
          name = fortran_match_interface(s)
          if name then kind = 'interface' end
        end
        if not name then
          name = fortran_match_procedure(s)
          if name then kind = 'procedure' end
        end

        if name and kind then
          local parent = top_container()
          local sym = {
            name = name,
            kind = kind,
            line = i,
            end_line = nil,
            signature = fortran_signature(lines, i, code),
            parent = parent,
            scope = parent and 'contained' or 'global',
          }
          out[#out + 1] = sym
          if FORTRAN_CONTAINER_KIND[kind] then
            stack[#stack + 1] = { name = name, kind = kind, container = true, sym = sym }
          end
        end
      end
    end
  end

  local last = #lines
  while #stack > 0 do
    local fr = close_top(last)
    if not fr then break end
  end

  return out
end

--------------------------------------------------------------------------------
-- C / C++ regex extractor
--------------------------------------------------------------------------------

local C_KEYWORDS = {
  ['if'] = true, ['else'] = true, ['while'] = true, ['for'] = true, switch = true, case = true,
  ['default'] = true, ['return'] = true, sizeof = true, ['do'] = true, catch = true,
  throw = true, ['new'] = true, delete = true, typedef = true, struct = true, union = true,
  enum = true, class = true, namespace = true, template = true, typename = true,
  ['const'] = true, static = true, inline = true, extern = true, virtual = true,
  constexpr = true, friend = true, explicit = true, operator = true, ['and'] = true, ['or'] = true,
  ['not'] = true, ['true'] = true, ['false'] = true, nullptr = true, this = true, auto = true,
  ['void'] = true, char = true, short = true, ['long'] = true, unsigned = true, signed = true,
  ['float'] = true, ['double'] = true, bool = true, ['int'] = true, wchar_t = true,
  char8_t = true, char16_t = true, char32_t = true, ['goto'] = true, ['break'] = true, continue = true,
  alignas = true, alignof = true, decltype = true, noexcept = true, static_assert = true,
  using = true, public = true, private = true, protected = true, override = true, final = true,
}

---Remove comments and string/char literal bodies, tracking block comments.
local function c_clean_lines(lines)
  local out = {}
  local in_block = false
  for i, line in ipairs(lines) do
    local buf = {}
    local j = 1
    local n = #line
    local in_str = nil
    while j <= n do
      local c = line:sub(j, j)
      local c2 = line:sub(j + 1, j + 1)
      if in_block then
        if c == '*' and c2 == '/' then
          in_block = false
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
        in_block = true
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
    out[i] = table.concat(buf)
  end
  return out
end

---Parse a C/C++ definition-shaped statement.
---@return string|nil name, string|nil kind, string|nil class, string|nil brace_state
---   brace_state: 'open' (a body starts on this line), 'inline' (the body opens
---   and closes on this line) or nil (no body brace on this line).
local function c_parse_function(text)
  local t = trim(text)
  if t == '' then return nil end
  if t:sub(-1) == ';' then return nil end
  local p = t:find('(', 1, true)
  if not p then return nil end
  local prefix = t:sub(1, p - 1)
  if prefix == '' then return nil end
  if prefix:find('=', 1, true) or prefix:find(';', 1, true) or prefix:find('#', 1, true) then
    return nil
  end
  if prefix:sub(-1) == '.' or prefix:match('%-%>%s*$') then return nil end

  local name = prefix:match('([%w_:~]+)%s*$')
  if not name then return nil end
  if C_KEYWORDS[name] then return nil end

  local depth = 0
  local close = nil
  for j = p, #t do
    local c = t:sub(j, j)
    if c == '(' then
      depth = depth + 1
    elseif c == ')' then
      depth = depth - 1
      if depth == 0 then
        close = j
        break
      end
    end
  end
  if not close then return nil end

  -- Everything after the parameter list: qualifiers, initialiser lists and
  -- possibly the body's opening brace.
  local after = t:sub(close + 1)
  local brace_state = nil
  local brace_at = after:find('{', 1, true)
  if brace_at then
    local rest = after:sub(brace_at + 1)
    brace_state = rest:find('}', 1, true) and 'inline' or 'open'
    after = after:sub(1, brace_at - 1)
  end
  if after:find(';', 1, true) or after:find('=', 1, true) then
    return nil
  end

  local cls = nil
  if name:find('::', 1, true) then
    local head, tail = name:match('^(.-)::([%w_~]+)$')
    if head and tail then
      cls = head
      name = tail
      local outer = cls:match('([%w_]+)$')
      if outer then cls = outer end
    end
  end
  if name == '' or C_KEYWORDS[name] then return nil end
  local kind = cls and 'method' or 'function'
  if name:sub(1, 1) == '~' then kind = 'method' end
  return name, kind, cls, brace_state
end

local function c_match_type(code)
  local name = code:match('^enum%s+class%s+([%w_]+)')
  if name then return 'enum', name end
  name = code:match('^enum%s+struct%s+([%w_]+)')
  if name then return 'enum', name end
  name = code:match('^namespace%s+([%w_]+)')
  if name then return 'namespace', name end
  local kind, nm = code:match('^(class)%s+([%w_]+)')
  if not kind then kind, nm = code:match('^(struct)%s+([%w_]+)') end
  if not kind then kind, nm = code:match('^(union)%s+([%w_]+)') end
  if not kind then kind, nm = code:match('^(enum)%s+([%w_]+)') end
  if kind then return kind, nm end
  local tname = code:match('^typedef%s+.-([%w_]+)%s*;%s*$')
  if tname then return 'type', tname end
  return nil
end

local function extract_c(lines)
  local out = {}
  local clines = c_clean_lines(lines)
  local depth = 0
  local stack = {}
  local pending = nil

  local function top_type_container()
    for i = #stack, 1, -1 do
      local k = stack[i].kind
      if k == 'class' or k == 'struct' or k == 'union' or k == 'namespace' or k == 'enum' then
        return stack[i].name, k
      end
    end
    return nil, nil
  end

  local function push_frame(sym, kind, open_depth)
    if not sym.end_line then
      stack[#stack + 1] = { name = sym.name, kind = kind, open_depth = open_depth, sym = sym }
    end
  end

  local function close_frame(end_line)
    local fr = table.remove(stack)
    if fr and fr.sym and not fr.sym.end_line then
      local el = end_line
      if type(el) ~= 'number' or el < fr.sym.line then el = fr.sym.line end
      fr.sym.end_line = el
    end
  end

  for i, _ in ipairs(lines) do
    local cl = clines[i] or ''
    local code = trim(cl)
    local trailing = code:sub(-1)
    local opens, closes = 0, 0
    for j = 1, #cl do
      local c = cl:sub(j, j)
      if c == '{' then
        opens = opens + 1
      elseif c == '}' then
        closes = closes + 1
      end
    end

    -- 1. A pending K&R definition resolves on the line that opens its brace.
    local pending_resolved = false
    if pending then
      if code == '' then
        -- keep waiting for the brace
      elseif code:sub(1, 1) == '{' then
        pending_resolved = true
      else
        pending = nil
      end
    end

    -- 2. Advance the brace depth exactly once for this line.
    depth = depth + opens - closes

    -- 3. Materialise (or drop) the pending frame now that the depth is known.
    if pending_resolved and pending then
      if trailing == '{' then
        push_frame(pending.sym, pending.sym.kind, depth)
      else
        pending.sym.end_line = i
      end
      pending = nil
    end

    -- 4. Close every frame whose block already ended.
    while #stack > 0 and stack[#stack].open_depth > depth do
      close_frame(i)
    end

    -- Definition detection --------------------------------------------------
    if code ~= '' and code:sub(1, 1) ~= '#' then
      local stripped = code
      if stripped:match('^template%s*<') then
        stripped = stripped:gsub('^template%s*<[^>]*>%s*', '')
        stripped = stripped:gsub('^>+%s*', '')
      end
      stripped = stripped:gsub('^inline%s+', ''):gsub('^export%s+', '')

      local kind, name = c_match_type(stripped)
      if name then
        local parent, pkind = top_type_container()
        local sym = {
          name = name,
          kind = kind,
          line = i,
          signature = sig_of(cl),
          parent = parent,
          scope = parent and (pkind == 'namespace' and 'namespace' or 'member') or 'file',
        }
        out[#out + 1] = sym
        local opens = stripped:find('{', 1, true)
        if opens then
          if closes > 0 and closes == opens then
            -- the whole type fits on one line: `enum E { A, B };`
            sym.end_line = i
          else
            -- depth already accounts for every brace on this line
            push_frame(sym, kind, depth)
          end
        else
          local look = next_code_line(clines, i + 1, 2)
          if look and look:sub(1, 1) == '{' then
            pending = { sym = sym }
          else
            sym.end_line = i
          end
        end
      else
        local joined, last_index = join_until_balanced(clines, i, 6)
        local fname, fkind, fcls, brace_state = c_parse_function(joined)
        if fname then
          local brace_index = nil
          if brace_state == 'open' then
            brace_index = i
          elseif brace_state == nil then
            local look, look_index = next_code_line(clines, last_index + 1, 3)
            if look and look:sub(1, 1) == '{' then brace_index = look_index end
          end

          if brace_state == 'inline' then
            local parent, pkind = top_type_container()
            if not parent and fcls then parent, pkind = fcls, 'class' end
            out[#out + 1] = {
              name = fname,
              kind = fkind,
              line = i,
              end_line = i,
              signature = sig_of(joined:gsub('%s*{%s*$', '')),
              parent = parent,
              scope = parent and (pkind == 'namespace' and 'namespace' or 'member') or 'file',
            }
          elseif brace_index then
            local parent, pkind = top_type_container()
            if not parent and fcls then parent, pkind = fcls, 'class' end
            local sym = {
              name = fname,
              kind = fkind,
              line = i,
              signature = sig_of(joined:gsub('%s*{%s*$', '')),
              parent = parent,
              scope = parent and (pkind == 'namespace' and 'namespace' or 'member') or 'file',
            }
            out[#out + 1] = sym
            if brace_index == i then
              push_frame(sym, fkind, depth)
            else
              pending = { sym = sym }
            end
          end
        end
      end
    end

    -- Preprocessor macros ---------------------------------------------------
    if code:sub(1, 1) == '#' then
      local mname = code:match('^#%s*define%s+([%w_]+)')
      if mname then
        out[#out + 1] = {
          name = mname,
          kind = 'macro',
          line = i,
          end_line = i,
          signature = sig_of(cl),
          parent = nil,
          scope = 'file',
        }
      end
    end
  end

  local last = #lines
  while #stack > 0 do
    close_frame(last)
  end

  return out
end

--------------------------------------------------------------------------------
-- Python regex extractor
--------------------------------------------------------------------------------

local function expand_indent(ws)
  local n = 0
  for i = 1, #ws do
    local c = ws:sub(i, i)
    if c == '\t' then n = n + 4 else n = n + 1 end
  end
  return n
end

local function extract_python(lines)
  local out = {}
  local stack = {}

  local function close_above(indent, line_no)
    while #stack > 0 and stack[#stack].indent >= indent do
      local fr = table.remove(stack)
      if fr.sym and not fr.sym.end_line then
        local el = line_no - 1
        if el < fr.sym.line then el = fr.sym.line end
        fr.sym.end_line = el
      end
    end
  end

  for i, raw in ipairs(lines) do
    local line = tostring(raw or '')
    if trim(line) ~= '' and not trim(line):match('^#') then
      local ws = line:match('^(%s*)') or ''
      local indent = expand_indent(ws)
      local fname = line:match('^%s*async%s+def%s+([%w_]+)')
      if not fname then fname = line:match('^%s*def%s+([%w_]+)') end
      local cname = line:match('^%s*class%s+([%w_]+)')

      if fname or cname then
        close_above(indent, i)
        local parent, pframe = nil, stack[#stack]
        if pframe then parent = pframe.name end
        local kind = 'function'
        if cname then
          kind = 'class'
        elseif pframe and pframe.container then
          kind = 'method'
        end
        local joined = join_until_balanced(lines, i, 5)
        local sym = {
          name = cname or fname,
          kind = kind,
          line = i,
          end_line = nil,
          signature = sig_of(joined),
          parent = parent,
          scope = parent and 'nested' or 'global',
        }
        out[#out + 1] = sym
        stack[#stack + 1] = {
          indent = indent,
          name = sym.name,
          container = (kind == 'class'),
          sym = sym,
        }
      else
        close_above(indent, i)
      end
    end
  end

  local last = #lines
  while #stack > 0 do
    local fr = table.remove(stack)
    if fr and fr.sym and not fr.sym.end_line then
      local el = last
      if el < fr.sym.line then el = fr.sym.line end
      fr.sym.end_line = el
    end
  end

  return out
end

--------------------------------------------------------------------------------
-- tree-sitter attempt (best effort, never required)
--------------------------------------------------------------------------------

local TS_CANDIDATES = {
  c = {
    { 'function_definition', 'function' },
    { 'struct_specifier', 'struct' },
    { 'union_specifier', 'union' },
    { 'enum_specifier', 'enum' },
    { 'type_definition', 'type' },
    { 'preproc_def', 'macro' },
    { 'preproc_function_def', 'macro' },
  },
  cpp = {
    { 'function_definition', 'function' },
    { 'class_specifier', 'class' },
    { 'struct_specifier', 'struct' },
    { 'union_specifier', 'union' },
    { 'enum_specifier', 'enum' },
    { 'namespace_definition', 'namespace' },
    { 'type_definition', 'type' },
    { 'preproc_def', 'macro' },
    { 'preproc_function_def', 'macro' },
  },
  python = {
    { 'function_definition', 'function' },
    { 'class_definition', 'class' },
  },
  fortran = {
    { 'subroutine', 'subroutine' },
    { 'function', 'function' },
    { 'module', 'module' },
    { 'program', 'program' },
    { 'submodule', 'module' },
    { 'module_procedure', 'procedure' },
    { 'interface', 'interface' },
    { 'derived_type_definition', 'type' },
    { 'type_definition', 'type' },
    { 'subroutine_statement', 'subroutine' },
    { 'function_statement', 'function' },
  },
}

local function ts_guess_name(lang, line)
  local s = trim(line)
  if s == '' then return nil end
  if lang == 'python' then
    return s:match('^async%s+def%s+([%w_]+)')
      or s:match('^def%s+([%w_]+)')
      or s:match('^class%s+([%w_]+)')
  elseif lang == 'c' or lang == 'cpp' then
    local low = s
    local name = low:match('^enum%s+class%s+([%w_]+)')
      or low:match('^enum%s+struct%s+([%w_]+)')
      or low:match('^class%s+([%w_]+)')
      or low:match('^struct%s+([%w_]+)')
      or low:match('^union%s+([%w_]+)')
      or low:match('^enum%s+([%w_]+)')
      or low:match('^namespace%s+([%w_]+)')
      or low:match('^#%s*define%s+([%w_]+)')
    if name then return name end
    return c_parse_function(s)
  else
    local lower = s:lower()
    local name, kind = fortran_match_callable(lower)
    if name then return name, kind end
    name = fortran_match_module(lower)
    if name then return name, 'module' end
    name = lower:match('^program%s+([%w_]+)')
    if name then return name, 'program' end
    name = fortran_match_type(lower)
    if name then return name, 'type' end
    name = fortran_match_interface(lower)
    if name then return name, 'interface' end
    name = fortran_match_procedure(lower)
    if name then return name, 'procedure' end
    return nil
  end
end

local function ts_supported(lang, node_type)
  local ok = pcall(vim.treesitter.query.parse, lang, '(' .. node_type .. ') @x')
  return ok
end

---@return table|nil symbols, table|nil parsed_lines
---Languages whose tree-sitter pass has been ruled out for this session.
---Loading a parser and probing capture names is only worth doing once per
---language: the answer cannot change while Neovim runs, and repeating it per file
---dominated the extraction cost in measurements.
local TS_DISABLED = {}

local function try_treesitter(lang, lines)
  -- Tree-sitter is a Neovim API surface: it must not be touched from a libuv
  -- fast-event callback. The regex extractor covers that case.
  local ok_fast, fast = pcall(function()
    return type(vim.in_fast_event) == 'function' and vim.in_fast_event()
  end)
  if ok_fast and fast then return nil end

  -- Decided once per language per session. Loading the parser and probing every
  -- candidate capture for each file costs far more than the extraction itself:
  -- measured at ~8 ms per file against 0.11 ms for the regex pass, and for a
  -- language whose query cannot be built the whole cost is wasted before falling
  -- back. The decision cannot change mid-session, so it is cached, including the
  -- negative result.
  if TS_DISABLED[lang] then return nil end

  local ok, syms = pcall(function()
    local candidates = TS_CANDIDATES[lang]
    if not candidates then
      TS_DISABLED[lang] = true
      return nil
    end

    local parser_ok = pcall(vim.treesitter.language.add, lang)
    if not parser_ok then
      TS_DISABLED[lang] = true
      return nil
    end

    local supported = {}
    for _, c in ipairs(candidates) do
      if ts_supported(lang, c[1]) then supported[#supported + 1] = c end
    end
    if #supported == 0 then
      -- No capture in the candidate list exists in this grammar, so every future
      -- file of this language would pay the same failed probe.
      TS_DISABLED[lang] = true
      return nil
    end

    local patterns = {}
    for _, c in ipairs(supported) do
      patterns[#patterns + 1] = '(' .. c[1] .. ') @' .. c[2]
    end
    -- A grammar can exist while the query cannot be built; that is also a
    -- permanent condition for this session.
    local query_ok, query = pcall(vim.treesitter.query.parse, lang, table.concat(patterns, '\n'))
    if not query_ok or not query then
      TS_DISABLED[lang] = true
      return nil
    end

    local text = table.concat(lines, '\n')
    local root = nil
    local get_parser = vim.treesitter.get_string_parser
    if type(get_parser) ~= 'function' then return nil end
    local parser = get_parser(text, lang)
    if not parser then return nil end
    local trees = parser:parse()
    if type(trees) ~= 'table' or not trees[1] then return nil end
    root = trees[1]:root()
    if not root then return nil end

    local out = {}
    local function node_source(node)
      local ok2, txt = pcall(vim.treesitter.get_node_text, node, text)
      if ok2 and type(txt) == 'string' then return txt end
      return nil
    end

    for capture, node in query:iter_captures(root, text, 0, -1) do
      local kind = query.captures[capture]
      if kind and node then
        local srow, _, erow = node:range()
        local first = lines[srow + 1] or ''
        local name = select(1, ts_guess_name(lang, first))
        if (not name or name == '') then
          local src = node_source(node)
          if src then
            local first_src = src:match('^[^\n]*') or src
            name = select(1, ts_guess_name(lang, first_src))
          end
        end
        if name and name ~= '' then
          out[#out + 1] = {
            name = name,
            kind = kind,
            line = srow + 1,
            end_line = erow + 1,
            signature = sig_of(first),
            parent = nil,
            scope = nil,
          }
        end
      end
    end
    if #out == 0 then return nil end
    return out
  end)
  if ok and type(syms) == 'table' and #syms > 0 then return syms end
  return nil
end

--------------------------------------------------------------------------------
-- post-processing
--------------------------------------------------------------------------------

local function assign_parents(syms)
  local containers = {}
  for _, s in ipairs(syms) do
    if CONTAINER_KINDS[s.kind] then containers[#containers + 1] = s end
  end
  if #containers == 0 then return syms end
  for _, s in ipairs(syms) do
    if not s.parent then
      local best_name, best_span = nil, nil
      for _, c in ipairs(containers) do
        if c ~= s then
          local cend = c.end_line or c.line
          local send = s.end_line or s.line
          if c.line <= s.line and cend >= send then
            local span = cend - c.line
            if span > 0 and (best_span == nil or span < best_span) then
              best_span = span
              best_name = c.name
            end
          end
        end
      end
      if best_name then s.parent = best_name end
    end
  end
  return syms
end

local function finalize(syms, lines)
  local out = {}
  local seen = {}
  local max_line = #lines
  for _, s in ipairs(syms) do
    if type(s) == 'table' and type(s.name) == 'string' and s.name ~= '' then
      local line = tonumber(s.line) or 1
      if line < 1 then line = 1 end
      if max_line > 0 and line > max_line then line = max_line end
      local end_line = tonumber(s.end_line)
      if end_line then
        if end_line < line then end_line = line end
        if max_line > 0 and end_line > max_line then end_line = max_line end
      end
      local kind = type(s.kind) == 'string' and s.kind or 'global'
      local key = ('%s\0%d\0%s'):format(s.name, line, kind)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = {
          name = s.name,
          kind = kind,
          line = line,
          end_line = end_line,
          signature = sig_of(s.signature),
          parent = (type(s.parent) == 'string' and s.parent ~= '') and s.parent or nil,
          scope = (type(s.scope) == 'string' and s.scope ~= '') and s.scope or nil,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.line == b.line then
      if a.kind == b.kind then return a.name < b.name end
      return a.kind < b.kind
    end
    return a.line < b.line
  end)
  assign_parents(out)
  return out
end

--------------------------------------------------------------------------------
-- public API
--------------------------------------------------------------------------------

---Extract symbols from a single file. Never throws.
---@param path string
---@param lang string fortran|c|cpp|python
---@return table[] symbols
---Merge two extraction passes, preferring the first (more precise) result on
---collisions.
---
---Running only one extractor silently loses declarations: tree-sitter can be
---configured for a grammar but still miss whole constructs (observed on Fortran,
---where a `module` was dropped while a nested `type` was found), and the regex
---pass exists precisely to cover the cases the grammar does not.
---@param primary table[]
---@param secondary table[]
---@return table[]
local function merge_symbols(primary, secondary)
  local out = {}
  local seen = {}
  local function add(sym)
    if type(sym) ~= 'table' or type(sym.name) ~= 'string' or sym.name == '' then return end
    local key = ('%s@%d@%s'):format(sym.name, tonumber(sym.line) or 0, tostring(sym.kind))
    if seen[key] then return end
    -- Same declaration found by both passes at a slightly different line: keep
    -- whichever came first (the primary pass is more accurate when it fires).
    local loose = ('%s@%s'):format(sym.name, tostring(sym.kind))
    if seen[loose] then return end
    seen[key] = true
    seen[loose] = true
    out[#out + 1] = sym
  end
  for _, sym in ipairs(primary or {}) do add(sym) end
  for _, sym in ipairs(secondary or {}) do add(sym) end
  return out
end

---Regex-based extraction for a language (the baseline that never depends on a
---parser being installed).
---@param lang string
---@param lines string[]
---@return table[]
local function extract_with_regex(lang, lines)
  if lang == 'fortran' then return extract_fortran(lines) end
  if lang == 'python' then return extract_python(lines) end
  return extract_c(lines)
end

function M.extract_file(path, lang)
  local result = {}
  local ok = pcall(function()
    if type(path) ~= 'string' or path == '' then return end
    if type(lang) ~= 'string' or not EXTRACT_LANGS[lang] then return end
    local lines = read_lines(path)
    if not lines or #lines == 0 then return end

    local regex_syms = extract_with_regex(lang, lines)
    local ts_syms = try_treesitter(lang, lines)
    -- Merge rather than picking one: whichever pass is more complete varies by
    -- grammar and by language.
    local syms = (ts_syms and #ts_syms > 0)
      and merge_symbols(ts_syms, regex_syms)
      or regex_syms
    result = finalize(syms or {}, lines)
  end)
  if ok and type(result) == 'table' then return result end
  return {}
end

---Extract symbols for a language without touching the filesystem (tests, tools).
---@param source string
---@param lang string
---@return table[]
function M.extract_source(source, lang)
  local result = {}
  pcall(function()
    if type(source) ~= 'string' or type(lang) ~= 'string' then return end
    if not EXTRACT_LANGS[lang] then return end
    source = strip_bom(source)
    local lines = {}
    for line in (source:gsub('\r\n', '\n'):gsub('\r', '\n') .. '\n'):gmatch('([^\n]*)\n') do
      lines[#lines + 1] = line
    end
    if lines[#lines] == '' then lines[#lines] = nil end
    local syms
    if lang == 'fortran' then
      syms = extract_fortran(lines)
    elseif lang == 'python' then
      syms = extract_python(lines)
    else
      syms = extract_c(lines)
    end
    result = finalize(syms or {}, lines)
  end)
  return result
end

local function select_files(scan_result, opts)
  local files = {}
  local ok = pcall(function()
    if type(scan_result) ~= 'table' then return end
    local max_files = tonumber(opts and opts.max_files) or 2000
    if max_files < 1 then max_files = 1 end
    local want = nil
    if opts and type(opts.langs) == 'table' then
      want = {}
      for k, v in pairs(opts.langs) do
        if type(v) == 'string' then want[v] = true end
        if type(k) == 'string' and v == true then want[k] = true end
      end
    end
    for _, f in ipairs(scan_result.files or {}) do
      if type(f) == 'table' and type(f.path) == 'string' then
        local lang = f.lang
        local keep
        if EXTRACT_LANGS[lang] then
          if want then keep = want[lang] == true else keep = true end
        else
          keep = false
        end
        if keep and #files < max_files then files[#files + 1] = f end
      end
    end
  end)
  if not ok then return {} end
  return files
end

local BATCH = 40

---Synchronous project extraction.
---
---Runs straight through, in batches of 40 files, with no yield between batches.
---It previously gave the event loop a "1ms window" via `vim.wait` after each
---batch; measured, that cost roughly a second per batch because vim.wait services
---the loop and overshoots its timeout by orders of magnitude - several seconds of
---idle for a few milliseconds of work. Callers that need a responsive UI want
---`extract_project_async`, which schedules real chunks.
---@param scan_result table
---@param opts table|nil { max_files = 2000, langs = table|nil, on_progress = fun(done,total) }
---@return table { [rel] = symbols[] }
function M.extract_project(scan_result, opts)
  local result = {}
  local ok = pcall(function()
    opts = opts or {}
    local files = select_files(scan_result, opts)
    local total = #files
    local i = 1
    while i <= total do
      local stop = math.min(i + BATCH - 1, total)
      for j = i, stop do
        local f = files[j]
        result[f.rel or f.path] = M.extract_file(f.path, f.lang)
      end
      if type(opts.on_progress) == 'function' then pcall(opts.on_progress, stop, total) end
      i = stop + 1
    end
  end)
  if not ok then return result end
  return result
end

---Asynchronous project extraction driven by a libuv timer.
---At most 40 files are processed per timer tick, and every user callback runs
---through `vim.schedule` so it is safe to call any Neovim API from it.
---@param scan_result table
---@param opts table|nil
---@param on_done fun(result:table, done:integer, total:integer)|nil
---@return boolean started
function M.extract_project_async(scan_result, opts, on_done)
  local started = false
  local ok = pcall(function()
    opts = opts or {}
    local files = select_files(scan_result, opts)
    local total = #files
    local result = {}
    local i = 1
    local finished = false
    local timer = nil

    local function schedule(fn)
      local sched_ok = pcall(vim.schedule, fn)
      if not sched_ok then pcall(fn) end
    end

    local function finish()
      if finished then return end
      finished = true
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
      if type(on_done) == 'function' then pcall(on_done, result, total, total) end
    end

    local function tick()
      if finished then return end
      local stop = math.min(i + BATCH - 1, total)
      for j = i, stop do
        local f = files[j]
        if f then result[f.rel or f.path] = M.extract_file(f.path, f.lang) end
      end
      i = stop + 1
      if type(opts.on_progress) == 'function' then
        local done_now = math.min(stop, total)
        schedule(function() pcall(opts.on_progress, done_now, total) end)
      end
      if i > total then
        schedule(finish)
      end
    end

    if total == 0 then
      schedule(finish)
      started = true
      return
    end

    if uv and type(uv.new_timer) == 'function' then
      local timer_ok = pcall(function()
        timer = uv.new_timer()
        if not timer then return end
        started = true
      end)
      if timer_ok and started and timer then
        -- Arm a one-shot timer per batch. The batch itself runs through
        -- vim.schedule so it executes on the main loop: tree-sitter queries
        -- and any user callback may then use the full Neovim API.
        local function arm()
          if finished or not timer then return end
          timer:start(0, 0, function()
            if finished then return end
            schedule(function()
              if finished then return end
              local tick_ok = pcall(tick)
              if not tick_ok then
                schedule(finish)
                return
              end
              if not finished and i <= total then arm() end
            end)
          end)
        end
        arm()
        return
      end
      started = false
      pcall(function()
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
      end)
    end

    -- Fallback: chain batches through vim.schedule.
    started = true
    local function chain()
      if finished then return end
      local tick_ok = pcall(tick)
      if tick_ok and not finished and i <= total then schedule(chain) end
    end
    schedule(chain)
  end)
  if ok and started then return true end
  if not ok then
    if type(on_done) == 'function' then pcall(on_done, {}, 0, 0) end
  end
  return started
end

---Flatten `{ [rel] = symbols }` into a list of symbols with `rel` attached.
---@param symbols_by_file table
---@return table[]
function M.flatten(symbols_by_file)
  local out = {}
  pcall(function()
    if type(symbols_by_file) ~= 'table' then return end
    local rels = {}
    for rel in pairs(symbols_by_file) do rels[#rels + 1] = rel end
    table.sort(rels)
    for _, rel in ipairs(rels) do
      local list = symbols_by_file[rel]
      if type(list) == 'table' then
        for _, s in ipairs(list) do
          if type(s) == 'table' then
            out[#out + 1] = {
              rel = rel,
              name = s.name,
              kind = s.kind,
              line = s.line,
              end_line = s.end_line,
              signature = s.signature,
              parent = s.parent,
              scope = s.scope,
            }
          end
        end
      end
    end
  end)
  return out
end

---Count of extracted symbols.
function M.count(symbols_by_file)
  local n = 0
  pcall(function()
    for _, list in pairs(symbols_by_file or {}) do
      if type(list) == 'table' then n = n + #list end
    end
  end)
  return n
end

return M
