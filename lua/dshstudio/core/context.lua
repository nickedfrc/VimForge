-- dshstudio/core/context.lua
--
-- Builds the context block that is injected into every prompt: the active
-- buffer (or the visual selection), diagnostics, the enclosing symbol, project
-- markers, git state, and the open-buffer list.
--
-- Context is expressed as plain Markdown with explicit file/line attribution so
-- the model can cite and edit precisely, and it is size-capped so a large file
-- can never blow up a request.

local M = {}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { is_windows = function() return package.config:sub(1, 1) == '\\' end }
end

local function config()
  local ok, mod = pcall(require, 'dshstudio.config')
  if ok and mod.get then return mod end
  return { get = function(_, default) return default end }
end

local function max_bytes()
  local n = tonumber(config().get('context_max_bytes')) or 24000
  if n < 2000 then n = 2000 end
  return n
end

local function max_lines()
  return tonumber(config().get('context_max_lines')) or 400
end

-- ---------------------------------------------------------------------------
-- Pieces
-- ---------------------------------------------------------------------------

---Language id used in the injected fenced code block.
---@param filetype string
function M.fence_language(filetype)
  local map = {
    cpp = 'cpp', c = 'c', python = 'python', fortran = 'fortran',
    lua = 'lua', vim = 'vim', sh = 'bash', bash = 'bash', json = 'json',
    yaml = 'yaml', markdown = 'markdown', cmake = 'cmake',
  }
  return map[filetype] or (filetype ~= '' and filetype or 'text')
end

---Current visual selection as (start_line, end_line) 1-based, or nil.
function M.selection_range()
  local mode = vim.fn.mode()
  local srow, erow
  local ok = pcall(function()
    srow = vim.fn.getpos("'<")[2]
    erow = vim.fn.getpos("'>")[2]
  end)
  if not ok then return nil end
  if mode:match('^[vV\22]') then
    -- While still in visual mode the marks may be stale; use the live range.
    srow = vim.fn.line('v')
    erow = vim.fn.line('.')
  end
  if not srow or not erow or srow <= 0 or erow <= 0 then return nil end
  if srow > erow then srow, erow = erow, srow end
  return srow, erow
end

---Access Neovim's LSP client table safely.
---
---`vim.lsp` is a lazily loaded module. Touching it before the runtime path is
---fully assembled raises "loop or previous error loading module 'vim.lsp'",
---which was observed when the configuration is loaded as an app config directory
---straight from a release bundle. Symbol context is a nice-to-have, so a failure
---here must degrade to "no symbols" rather than break the whole context build.
---@return table|nil
local function lsp_module()
  local ok, mod = pcall(require, 'vim.lsp')
  if ok and type(mod) == 'table' then return mod end
  return nil
end

---Request document symbols without ever blocking indefinitely.
---
---`vim.lsp.buf_request_sync` can park the main loop on Neovim 0.12 (observed:
---a headless run hung forever on a buffer with no client attached), which would
---freeze the editor. This drives the asynchronous request API instead and waits
---against a deadline, returning nil when nothing answers in time.
---@param bufnr integer
---@param timeout_ms integer
---@return table|nil responses
local function request_symbols(bufnr, timeout_ms)
  local lsp = lsp_module()
  if not lsp or type(lsp.get_clients) ~= 'function' or type(lsp.buf_request_all) ~= 'function' then
    return nil
  end

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

  -- Yield to the event loop until the responses land or the deadline passes.
  pcall(vim.wait, timeout_ms, function() return done end, 10)
  if not done then return nil end
  return responses
end

---Flatten an LSP DocumentSymbol/SymbolInformation response into rows.
---@param responses table|nil
---@param map fun(node:table, depth:integer)
local function walk_responses(responses, map)
  if type(responses) ~= 'table' then return end
  local function recurse(nodes, depth)
    if depth > 8 then return end
    for _, node in ipairs(nodes or {}) do
      map(node, depth)
      if node.children then recurse(node.children, depth + 1) end
    end
  end
  for _, entry in pairs(responses) do
    -- buf_request_all yields { [client_id] = { err = ..., result = ... } }.
    local result = entry and (entry.result or entry)
    if type(result) == 'table' then recurse(result, 0) end
  end
end

---The enclosing LSP symbol for a line, if a client can answer cheaply.
---@param bufnr integer
---@param line integer
function M.enclosing_symbol(bufnr, line)
  local responses = request_symbols(bufnr, 600)
  if not responses then return nil end
  local best
  walk_responses(responses, function(node, _depth)
    local r = node.range or (node.location and node.location.range)
    if not r then return end
    local s = r.start.line + 1
    local e = (r['end'] and r['end'].line + 1) or s
    if line >= s and line <= e then
      best = { name = node.name, kind = node.kind, start_line = s, end_line = e }
    end
  end)
  return best
end

---Git branch and short status for the project root, or nil when unavailable.
function M.git_state(root)
  if vim.fn.executable('git') ~= 1 then return nil end
  local function run(args)
    local ok, res = pcall(vim.system, args, { cwd = root, text = true })
    if not ok or not res then return nil end
    local out = res:wait(3000)
    if out.code ~= 0 then return nil end
    return (out.stdout or ''):gsub('%s+$', '')
  end
  local branch = run({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' })
  if not branch or branch == '' then return nil end
  local status = run({ 'git', 'status', '--porcelain' })
  local changed = 0
  if status and status ~= '' then
    for _ in status:gmatch('[^\n]+') do changed = changed + 1 end
  end
  return { branch = branch, changed = changed }
end

---Project markers that hint at the build system.
function M.project_markers(root)
  local markers = {
    'CMakeLists.txt', 'Makefile', 'compile_commands.json', 'fpm.toml',
    'pyproject.toml', 'setup.py', 'requirements.txt', 'meson.build',
    '.clangd', '.fortls', 'Cargo.toml', 'package.json',
  }
  local found = {}
  for _, m in ipairs(markers) do
    if vim.fn.filereadable(root .. '/' .. m) == 1 then table.insert(found, m) end
  end
  return found
end

---Diagnostics for a buffer, condensed to "SEVERITY line: message" lines.
function M.diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, diags = pcall(vim.diagnostic.get, bufnr)
  if not ok or not diags then return {} end
  local sev = { [1] = 'ERROR', [2] = 'WARN', [3] = 'INFO', [4] = 'HINT' }
  local out = {}
  for _, d in ipairs(diags) do
    table.insert(out, ('%s L%d: %s'):format(sev[d.severity] or 'DIAG', d.lnum + 1, d.message))
    if #out >= 30 then break end
  end
  return out
end

---Summarize a file's declared symbols without pulling in the whole file.
function M.symbol_summary(bufnr)
  local responses = request_symbols(bufnr, 600)
  if not responses then return nil end
  local kinds = {
    [1] = 'File', [2] = 'Module', [3] = 'Namespace', [4] = 'Package', [5] = 'Class',
    [6] = 'Method', [7] = 'Property', [8] = 'Field', [9] = 'Constructor', [10] = 'Enum',
    [11] = 'Interface', [12] = 'Function', [13] = 'Variable', [14] = 'Constant',
    [15] = 'String', [16] = 'Number', [17] = 'Boolean', [18] = 'Array', [19] = 'Object',
    [20] = 'Key', [21] = 'Null', [22] = 'EnumMember', [23] = 'Struct', [24] = 'Event',
    [25] = 'Operator', [26] = 'TypeParameter',
  }
  local lines = {}
  local full = false
  walk_responses(responses, function(node, depth)
    if full then return end
    if #lines >= 120 then
      full = true
      return
    end
    local r = node.range or (node.location and node.location.range)
    local ln = r and (r.start.line + 1) or 0
    table.insert(lines, ('%s%s %s (L%d)'):format(string.rep('  ', depth or 0),
      kinds[node.kind] or 'Symbol', node.name or '?', ln))
  end)
  if #lines == 0 then return nil end
  if full then table.insert(lines, ('  … truncated (showing the first %d)'):format(#lines)) end
  return lines
end

-- ---------------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------------

---Build the context string.
---@param opts { mode:string|nil, include_buffers:boolean|nil, extra:string|nil, buffer:integer|nil }
---  mode: 'selection' | 'file' | 'none' | 'project'
---@return string context
---@return table meta  (what was actually included, for the UI to display)
function M.build(opts)
  opts = opts or {}
  local buf = opts.buffer or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then buf = vim.api.nvim_get_current_buf() end
  local path = vim.api.nvim_buf_get_name(buf)
  local ft = vim.bo[buf].filetype or ''
  local cwd = vim.fn.getcwd()
  local root = cwd
  do
    local ok, scan = pcall(require, 'dshstudio.project.scan')
    if ok and scan.detect_root then
      local r = scan.detect_root(vim.fn.fnamemodify(path ~= '' and path or cwd, ':h'))
      if r then root = r end
    end
  end

  local parts = {}
  local meta = { included = {}, root = root, path = path, filetype = ft }

  local header = {
    '# Editor context',
    '',
    ('- Working directory: `%s`'):format(cwd),
    ('- Project root: `%s`'):format(root),
    ('- Active file: `%s`'):format(path ~= '' and path or '(unnamed buffer)'),
    ('- Filetype: %s'):format(ft ~= '' and ft or 'unknown'),
  }
  local markers = M.project_markers(root)
  if #markers > 0 then
    table.insert(header, ('- Project markers: %s'):format(table.concat(markers, ', ')))
  end
  local git = M.git_state(root)
  if git then
    table.insert(header, ('- Git branch: `%s` (%d changed files)'):format(git.branch, git.changed))
  end
  table.insert(parts, table.concat(header, '\n'))
  table.insert(meta.included, 'editor state')

  local mode = opts.mode
  if mode == nil then
    mode = (config().get('auto_context') == false) and 'none' or 'file'
  end

  if mode ~= 'none' and path ~= '' then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local s, e = 1, #lines
    local is_selection = false
    if mode == 'selection' then
      local sr, er = M.selection_range()
      if sr and er then
        s, e, is_selection = sr, er, true
      else
        mode = 'file'
      end
    end

    -- Cap by line count around the selection, then by bytes.
    local cap = max_lines()
    if e - s + 1 > cap then
      if is_selection then
        e = s + cap - 1
      else
        -- Keep the head of the file plus the cursor neighbourhood.
        local cursor = vim.api.nvim_win_get_cursor(0)[1]
        local half = math.floor(cap / 2)
        s = math.max(1, cursor - half)
        e = math.min(#lines, s + cap - 1)
      end
      table.insert(header, ('- NOTE: file truncated to %d lines for this request'):format(cap))
      parts[1] = table.concat(header, '\n')
    end

    local numbered = {}
    for i = s, e do
      table.insert(numbered, ('%5d| %s'):format(i, lines[i] or ''))
    end
    local body = table.concat(numbered, '\n')
    local budget = max_bytes()
    if #body > budget then
      body = body:sub(1, budget) .. '\n... [truncated: context byte budget reached]'
    end
    local label = is_selection and ('selection L%d-%d'):format(s, e) or 'file'
    table.insert(parts, ('## %s: `%s` (%s)\n\n```%s\n%s\n```'):format(
      label, path, is_selection and 'visual selection' or 'whole buffer',
      M.fence_language(ft), body))
    table.insert(meta.included, label .. ' ' .. path)
  end

  -- Enclosing symbol + declaration outline are cheap and help a lot.
  if path ~= '' then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local sym = M.enclosing_symbol(buf, cursor_line)
    if sym then
      table.insert(parts, ('## Cursor location\n\nInside `%s` (lines %d-%d, cursor at L%d).')
        :format(sym.name, sym.start_line, sym.end_line, cursor_line))
      table.insert(meta.included, 'enclosing symbol')
    end
    local outline = M.symbol_summary(buf)
    if outline then
      table.insert(parts, '## Declaration outline for this file\n\n```\n' ..
        table.concat(outline, '\n') .. '\n```')
      table.insert(meta.included, 'symbol outline')
    end
  end

  local diags = M.diagnostics(buf)
  if #diags > 0 then
    table.insert(parts, '## Diagnostics in the active file\n\n```\n' .. table.concat(diags, '\n') .. '\n```')
    table.insert(meta.included, ('%d diagnostics'):format(#diags))
  end

  if opts.include_buffers ~= false then
    local bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= '' then
          local modified = vim.bo[b].modified and ' (modified)' or ''
          table.insert(bufs, ('- `%s`%s'):format(vim.fn.fnamemodify(name, ':~:.'), modified))
        end
      end
    end
    if #bufs > 0 and #bufs <= 40 then
      table.insert(parts, '## Open buffers\n\n' .. table.concat(bufs, '\n'))
      table.insert(meta.included, ('%d open buffers'):format(#bufs))
    end
  end

  if opts.extra and opts.extra ~= '' then
    table.insert(parts, '## Additional context from the user\n\n' .. opts.extra)
    table.insert(meta.included, 'user note')
  end

  return table.concat(parts, '\n\n'), meta
end

---One-line description of what the automatic context would attach right now.
function M.preview()
  local mode = (config().get('auto_context') == false) and 'none' or 'file'
  local sr, er = M.selection_range()
  if sr and er then
    return ('selection L%d-%d'):format(sr, er)
  end
  if mode == 'none' then return 'off' end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
  return name ~= '' and ('file ' .. name) or 'file'
end

---Wrap a user message together with the context block.
---@param text string
---@param opts table|nil
---@return string payload
---@return table meta
function M.compose_prompt(text, opts)
  local ctx, meta = M.build(opts)
  local payload = ctx .. '\n\n---\n\n## Request\n\n' .. text
  return payload, meta
end

return M
