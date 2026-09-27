-- dshstudio/project/sniff.lua
--
-- Content sniffing for the two things a file name cannot always tell us: which
-- language a file is written in, and which Fortran source form it uses.
--
-- Legacy scientific code is the reason this module exists. A Fortran deck named
-- `foo.src`, or an include named `bar.inc`, carries no language in its name, so
-- the extension cannot be trusted and the first lines have to decide. Those
-- files are usually fixed-form FORTRAN 77, where column 1 holds `C`/`*`/`!`
-- comments, column 6 holds the continuation marker and the statement starts at
-- column 7 - rules that a free-form-oriented reader silently gets wrong. In the
-- 7785-line GAMESS-style deck this was written for, column-1 comment lines
-- mentioning `CALL` produced twenty calls that do not exist.
--
-- Detection has to stay conservative. Rules that look Fortran-ish in isolation
-- are everywhere: `end` closes a block in Lua as well, `function` is a Lua and
-- Pascal keyword, a Markdown bullet starts with `*`, and `class` belongs to both
-- C++ and Python. Only keywords that mean Fortran and little else carry weight
-- here; the rest are worth a single point or are left out entirely.
--
-- Every function here is pure and total: no Neovim API, no filesystem, no
-- throwing. `scan.lua` depends on that, because it promises never to raise.

local M = {}

---Extensions shared by several languages, so the extension alone cannot decide.
---`.src` and `.inc` appear in Fortran, C and C++ projects alike; `.ins` is the
---same idea. Anything listed here is resolved by reading the file's first lines.
M.AMBIGUOUS_EXT = {
  src = true,
  inc = true,
  ins = true,
}

---Statements in fixed form begin at column 7. These keywords in that position
---are the strongest single-file evidence that a file is Fortran, because no
---free-form language indents to exactly six columns as a matter of grammar.
---
---The list is deliberately short. `if`, `do`, `end`, `return`, `function`,
---`call`, `write` and friends also open lines in Lua, shell, PowerShell and
---batch files, and six-space indentation is unremarkable there, so testing
---those at column 7 flagged every Lua module in this repository as Fortran.
---What is left is either Fortran-only or spelled in a way no other language
---uses (`integer`, `character`, `dimension`, `equivalence`).
local FORTRAN_FIXED_MARKERS = {
  'subroutine', 'implicit', 'common', 'dimension', 'equivalence', 'parameter',
  'character', 'integer', 'logical', 'complex', 'double', 'blockdata',
  'submodule', 'allocate', 'deallocate', 'namelist', 'intrinsic', 'entry',
  'external', 'format', 'go', 'assign', 'rewind', 'backspace',
}

---Every keyword that can open a Fortran statement, including the free-form-only
---ones. Used to test *where* a statement starts, which is what separates the two
---source forms; the narrower list above is for the fixed-form column-7 test.
local FORTRAN_KEYWORDS = {
  'subroutine', 'function', 'program', 'module', 'submodule', 'blockdata',
  'implicit', 'integer', 'real', 'logical', 'character', 'complex', 'double',
  'common', 'dimension', 'call', 'return', 'data', 'save', 'external',
  'equivalence', 'parameter', 'entry', 'allocate', 'deallocate', 'format',
  'write', 'read', 'open', 'close', 'rewind', 'backspace', 'continue', 'stop',
  'if', 'do', 'end', 'goto', 'go', 'assign', 'include', 'use',
  'contains', 'type', 'class', 'select', 'where', 'forall', 'procedure',
  'enum', 'associate', 'critical', 'team', 'block', 'interface', 'abstract',
  'extends', 'generic', 'final', 'deferred', 'import', 'intrinsic', 'namelist',
  'optional', 'pointer', 'target', 'public', 'private', 'protected', 'pure',
  'elemental', 'recursive', 'result', 'value', 'volatile', 'bind', 'sequence',
  'print', 'elseif', 'case', 'pause', 'automatic', 'static',
}

---What a Fortran `end` may close. A bare `end` is not evidence of anything: Lua,
---Ruby and Elixir end every block with one.
local FORTRAN_END_TARGETS = {
  ['if'] = true, ['do'] = true, subroutine = true, ['function'] = true,
  program = true, module = true, submodule = true, type = true,
  interface = true, block = true, select = true, where = true, forall = true,
  associate = true, critical = true, enum = true, team = true,
  procedure = true, blockdata = true,
}

---How many lines of a file are ever examined. Language and source form are both
---obvious within a handful of lines; the cap just bounds the cost on a file that
---opens with a long legal header.
M.HEAD_LINES = 500

---Split a string (or pass a list through) into at most `limit` lines.
---@param head string|table|nil
---@param limit integer|nil
---@return string[]
function M.as_lines(head, limit)
  local out = {}
  local max = tonumber(limit) or M.HEAD_LINES
  if max < 1 then max = 1 end
  if type(head) == 'table' then
    for i = 1, math.min(#head, max) do
      if type(head[i]) == 'string' then out[#out + 1] = head[i] end
    end
    return out
  end
  if type(head) ~= 'string' or head == '' then return out end
  local n = 0
  for line in (head:gsub('\r\n', '\n'):gsub('\r', '\n') .. '\n'):gmatch('([^\n]*)\n') do
    out[#out + 1] = line
    n = n + 1
    if n >= max then break end
  end
  return out
end

---True when column 1 starts a comment in a file already known to be fixed-form.
---Once the form is settled, `C`, `c`, `*` and `!` in column 1 all mean the same
---thing and there is no ambiguity left to resolve.
---@param line string
---@return boolean
function M.is_fixed_comment(line)
  local c = tostring(line or ''):sub(1, 1)
  return c == '!' or c == '*' or c == 'C' or c == 'c'
end

---True when column 1 plausibly starts a fixed-form comment, used while the
---language is still unknown.
---
---`!` is unambiguous. `*` is deliberately rejected here: it is a Markdown
---bullet, a C pointer dereference and a banner line in equal measure, and it
---only becomes a Fortran comment once the file is known to be fixed-form.
---`C`/`c` is guarded against an assignment to a variable named `c`.
---@param line string
---@return boolean
function M.is_comment_line(line)
  local s = tostring(line or '')
  local c = s:sub(1, 1)
  if c == '!' then return true end
  if c ~= 'C' and c ~= 'c' then return false end
  local rest = s:sub(2)
  if rest == '' then return true end
  -- `char *p;`, `count++;`, `call foo` - an identifier continues, so this is code.
  if rest:sub(1, 1):match('[%w_]') then return false end
  -- `c = 1`, `c += 1`, `c /= n` - an assignment, not a comment.
  if rest:match('^%s*[%+%-%*/%%]?=') then return false end
  return true
end

---True when the line's statement begins exactly at column 7 with a Fortran
---keyword - the fixed-form layout no free-form writer produces by accident.
local function statement_at_column_7(line)
  if not line:sub(1, 6):match('^%s*$') then return false end
  local code = line:sub(7)
  if code == '' or code:match('^%s') then return false end
  local lower = code:lower()
  for _, kw in ipairs(FORTRAN_FIXED_MARKERS) do
    if lower:match('^' .. kw .. '%f[%W]') then return true end
  end
  return false
end

---True when a Fortran statement keyword starts anywhere other than column 7.
---
---This is the exact discriminator between the two forms rather than a guess: in
---fixed form every statement must begin at column 7, so the same keyword at any
---other indentation proves free form. It is also what keeps `contains` and
---`character` from being read as `C`-in-column-1 comments, which are legal only
---in fixed form and would otherwise make a free-form file look fixed.
local function statement_off_column_7(line)
  local indent = line:match('^(%s*)') or ''
  local code = line:sub(#indent + 1)
  if code == '' then return false end
  -- Columns 1-5 are the label field, so a leading number is not a keyword.
  if code:match('^%d') then return false end
  if #indent == 6 then return false end
  local lower = code:lower()
  for _, kw in ipairs(FORTRAN_KEYWORDS) do
    if lower:match('^' .. kw .. '%f[%W]') then return true end
  end
  return false
end

---Strip a trailing `!` comment that is not inside a character literal.
---@param s string
---@return string
function M.strip_inline_comment(s)
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

---The code part of one Fortran line, honouring the source form.
---
---In fixed form a column-1 comment hides the whole line, columns 1-6 are the
---label and continuation field, and column 73 onwards is the sequence field;
---none of that is statement text. In free form only a trailing `!` is removed.
---@param line string
---@param form string|nil 'fixed'|'free' (anything else is treated as free)
---@return string
function M.fortran_code(line, form)
  local s = tostring(line or '')
  if form == 'fixed' then
    if M.is_fixed_comment(s) then return '' end
    s = s:sub(7, 72)
  end
  return M.strip_inline_comment(s)
end

---Detect the Fortran source form from a file's opening lines.
---@param head string|table|nil
---@return string 'fixed'|'free'
function M.fortran_form(head)
  local lines = M.as_lines(head, 500)
  if #lines == 0 then return 'fixed' end
  local fixed, free = 0, 0
  for _, line in ipairs(lines) do
    if statement_at_column_7(line) then fixed = fixed + 2 end
    if statement_off_column_7(line) then free = free + 2 end
    -- A column-1 comment that does not open a statement: `C`/`c`/`*`/`!`
    -- followed by punctuation or spaces. Ordering matters here, because
    -- `contains` and `character` start with `c` and are statements in free form.
    if M.is_fixed_comment(line) and not statement_off_column_7(line) then
      fixed = fixed + 1
    end
    -- An `&` continuation exists in free form only.
    if line:find('&%s*$') then free = free + 2 end
    if line:match('^%s*&') then free = free + 2 end
    -- A `!` comment outside column 1 is free form; in fixed form `!` in column 1
    -- is just another comment style, already counted above.
    if line:find('!', 2, true) then free = free + 1 end
    -- The `::` separator arrived with free-form-friendly modern Fortran.
    if line:match('^%s*[%a_][%w_]*%s*::') then free = free + 1 end
  end
  if free > fixed then return 'free' end
  return 'fixed'
end

---Guess the language of a file from its opening lines.
---@param head string|table|nil
---@return string|nil 'fortran'|'c'|'cpp'|'python', or nil when nothing stands out
function M.detect(head)
  local lines = M.as_lines(head, 200)
  if #lines == 0 then return nil end

  local fortran, weak_fortran = 0, 0
  local c, cpp, python = 0, 0, 0
  for _, line in ipairs(lines) do
    local lower = line:lower()

    -- Fortran, split by how little else each keyword could mean. The weak hints
    -- are capped at the end: a Lua file holds a `function` on almost every line,
    -- so an uncapped hint would let volume alone outscore a real Fortran file.
    if statement_at_column_7(line) then fortran = fortran + 3 end
    if lower:match('^%s*implicit%s+[%a]') then fortran = fortran + 4 end
    -- Each of these has to be followed by a name. A bare keyword match would
    -- fire on a Lua table entry such as `module = true,` or a config key.
    if lower:match('^%s*subroutine%s+[%a_]') then fortran = fortran + 4 end
    if lower:match('^%s*program%s+[%a_]') or lower:match('^%s*module%s+[%a_]') then
      fortran = fortran + 3
    end
    if lower:match('^%s*submodule%s*%b()%s*[%a_]') then fortran = fortran + 3 end
    if lower:match('^%s*common%s*/') then fortran = fortran + 3 end
    if lower:match('^%s*character%s*%*%s*%d') or lower:match('^%s*real%s*%*%s*%d')
      or lower:match('^%s*integer%s*%*%s*%d') then
      fortran = fortran + 3
    end
    local end_target = lower:match('^%s*end%s+([%a_]+)')
    if end_target and FORTRAN_END_TARGETS[end_target] then fortran = fortran + 3 end
    if lower:match('^%s*use%s+[%a_][%w_]*%s*$')
      or lower:match('^%s*use%s+[%a_][%w_]*%s*,') then
      weak_fortran = weak_fortran + 2
    end
    -- A column-1 `C` comment, `function` (also Lua, Pascal and shell) and `call`
    -- (also a shell builtin) are hints rather than proof.
    if M.is_comment_line(line) then weak_fortran = weak_fortran + 2 end
    if lower:match('^%s*function%s+[%a_]') then weak_fortran = weak_fortran + 1 end
    if lower:match('^%s*call%s+[%a_]') then weak_fortran = weak_fortran + 1 end

    -- C / C++. `#include` and `#define` mean C or C++ and nothing else, so one
    -- of them is enough on its own; the conditional directives are not, because
    -- a batch file or a template uses those too.
    if lower:match('^%s*#%s*include') or lower:match('^%s*#%s*define') then
      c = c + 4
    end
    if lower:match('^%s*#%s*if') or lower:match('^%s*#%s*pragma') then c = c + 3 end
    if lower:match('^%s*#%s*endif') or lower:match('^%s*#%s*else') then c = c + 1 end
    if lower:match('^%s*//') or lower:match('^%s*/%*') then c = c + 2 end
    if lower:match('^%s*typedef%f[%W]') or lower:match('^%s*struct%s+[%a_]') then
      c = c + 2
    end
    if lower:match('^%s*namespace%s+[%a_]') or lower:match('^%s*template%s*<')
      or lower:match('^%s*using%s+namespace') then
      cpp = cpp + 3
    end
    if lower:match('^%s*class%s+[%a_][%w_]*%s*[:;{]') then cpp = cpp + 3 end

    -- Python.
    if lower:match('^%s*def%s+[%a_][%w_]*%s*%(') then python = python + 3 end
    if lower:match('^%s*class%s+[%a_][%w_]*%s*[%(:]') then python = python + 2 end
    if lower:match('^%s*import%s+[%a_]')
      or lower:match('^%s*from%s+[%a_][%w_%.]*%s+import%s') then
      python = python + 2
    end
  end

  -- Weak Fortran hints are capped, and Fortran needs at least one hint that
  -- means Fortran and little else. Without both rules a Lua file wins on the
  -- sheer number of `function` lines and a shell script wins on `call`.
  local strong_fortran = fortran
  fortran = strong_fortran + math.min(weak_fortran, 3)

  -- C++ sources are C sources to every reader further down the pipeline, so the
  -- C-family scores are compared together and the stronger one names the file.
  local best, best_score = nil, 0
  local family = math.max(c, cpp)
  if family > 0 then
    best, best_score = (cpp > c) and 'cpp' or 'c', family
  end
  if strong_fortran > 0 and fortran > best_score then
    best, best_score = 'fortran', fortran
  end
  if python > best_score then best, best_score = 'python', python end

  -- A couple of weak hints are not evidence; `# note` opens a shell script and a
  -- one-line `! comment` opens a config file just as readily.
  if best_score < 4 then return nil end
  return best
end

return M
