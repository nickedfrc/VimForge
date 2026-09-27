-- dshstudio/project/analysis.lua
--
-- Orchestration for DSH Studio's deepwiki-style project analysis.
--
-- Pipeline:
--   detect root -> scan -> symbols -> static dependencies -> structure
--   -> (optional) AI architecture notes -> build Markdown -> write -> open
--
-- Every step is failure-tolerant: a step that fails records an error and the
-- pipeline continues with an empty result, so a report is always produced.
-- Sibling project modules are required lazily inside the steps, never at load
-- time, and every call is pcall-protected.
--
-- Lua 5.1 / LuaJIT compatible. Neovim 0.11+ APIs only.

local M = {}

local uv = vim.uv or vim.loop

local MAX_CONTEXT_BYTES = 60000

local state = {
  last = nil,
  last_report = nil,
  last_error = nil,
  running = false,
  started_at = nil,
  finished_at = nil,
}

--------------------------------------------------------------------------------
-- notifications / config
--------------------------------------------------------------------------------

local function notify(msg, level)
  local ok = pcall(function()
    local util_ok, util = pcall(require, 'dshstudio.util')
    if util_ok and type(util) == 'table' and type(util.notify) == 'function' then
      util.notify(tostring(msg), level)
    else
      vim.notify(tostring(msg), level)
    end
  end)
  if not ok then pcall(vim.notify, tostring(msg), level) end
end

M.notify = notify

local function progress(msg)
  pcall(notify, msg, vim.log.levels.INFO)
end

local function warn(msg)
  pcall(notify, msg, vim.log.levels.WARN)
end

M.warn = warn

local function config_table()
  local cfg = nil
  pcall(function()
    local ok, mod = pcall(require, 'dshstudio.config')
    if ok and type(mod) == 'table' then cfg = mod end
  end)
  return cfg
end

local function config_string(key)
  local value = nil
  pcall(function()
    local g = vim.g['dshstudio_' .. key]
    if type(g) == 'string' and g ~= '' then value = g end
    if not value then
      local cfg = config_table()
      if cfg then
        -- `dshstudio.config` keeps its resolved values private; M.get is the
        -- supported accessor. Direct fields are accepted as well so this
        -- module also works with a simpler config table.
        if type(cfg.get) == 'function' then
          local ok, got = pcall(cfg.get, key)
          if ok and type(got) == 'string' and got ~= '' then value = got end
        end
        if not value and type(cfg[key]) == 'string' and cfg[key] ~= '' then
          value = cfg[key]
        end
        if not value and type(cfg.options) == 'table'
          and type(cfg.options[key]) == 'string' and cfg.options[key] ~= '' then
          value = cfg.options[key]
        end
      end
    end
  end)
  return value
end

M.config_string = config_string

local function plugin_version()
  local version = config_string('version')
  if version then return version end
  return 'dshstudio.project'
end

local function expand_dir(dir, root)
  local out = tostring(dir or '')
  -- `<cwd>` is dshstudio.config's placeholder; for a project report the
  -- analysis root is the meaningful expansion.
  out = out:gsub('<cwd>', function() return root end)
  out = out:gsub('^~', function()
    return vim.env.HOME or vim.env.USERPROFILE or '~'
  end)
  out = out:gsub('[/\\]+$', '')
  return out
end

local function output_path(root)
  root = tostring(root or '.'):gsub('[/\\]+$', '')
  local stamp = os.date('%Y%m%d-%H%M%S')
  local name = 'analysis-' .. stamp .. '.md'
  local dir = config_string('analysis_output_dir')
  if type(dir) == 'string' and dir ~= '' then
    dir = expand_dir(dir, root)
    if dir ~= '' then
      if dir:match('^[/\\]') or dir:match('^%a:[/\\]') then
        return dir .. '/' .. name
      end
      return root .. '/' .. dir .. '/' .. name
    end
  end
  return root .. '/.dshstudio/' .. name
end

M.output_path = output_path

--------------------------------------------------------------------------------
-- cache accessors
--------------------------------------------------------------------------------

---@return table|nil the last completed analysis result
function M.cached()
  return state.last
end

---Store an analysis result as the current cache entry.
---@param result table|nil
---@return table|nil
function M.set_cached(result)
  state.last = result
  if type(result) == 'table' then
    state.last_report = result.report_path or state.last_report
    state.finished_at = result.finished_at or os.time()
  end
  return state.last
end

---Short statusline-friendly summary of the cached run.
---@return string
function M.status()
  local ok, text = pcall(function()
    if state.running then return 'DSH: analyzing...' end
    local r = state.last
    if type(r) ~= 'table' then return 'DSH: no analysis' end
    local files = 0
    if type(r.scan) == 'table' and type(r.scan.files) == 'table' then files = #r.scan.files end
    local symbols = 0
    for _, list in pairs(r.symbols or {}) do
      if type(list) == 'table' then symbols = symbols + #list end
    end
    local errors = type(r.errors) == 'table' and #r.errors or 0
    local stamp = state.finished_at and os.date('%H:%M', state.finished_at) or '--:--'
    return ('DSH: %d files, %d symbols, %d warnings @%s'):format(files, symbols, errors, stamp)
  end)
  if ok and type(text) == 'string' then return text end
  return 'DSH: idle'
end

--------------------------------------------------------------------------------
-- root detection
--------------------------------------------------------------------------------

---Detect the project root from the current buffer's directory (or cwd).
---@return string|nil
function M.detect()
  local root = nil
  pcall(function()
    local scan_ok, scan_mod = pcall(require, 'dshstudio.project.scan')
    if not scan_ok or type(scan_mod) ~= 'table'
      or type(scan_mod.detect_root) ~= 'function' then
      return
    end
    local start = nil
    local buf_ok, name = pcall(vim.api.nvim_buf_get_name, 0)
    if buf_ok and type(name) == 'string' and name ~= '' then
      local dir_ok, dir = pcall(vim.fs.dirname, name)
      if dir_ok and type(dir) == 'string' and dir ~= '' then start = dir end
      if not start then start = name:match('^(.*)[/\\][^/\\]*$') end
    end
    if not start then
      local uv = vim.uv or vim.loop
      local cwd_ok, cwd = pcall(uv.cwd)
      if cwd_ok then start = cwd end
    end
    root = scan_mod.detect_root(start)
  end)
  return root
end

local function current_file()
  local path = nil
  pcall(function()
    local name = vim.api.nvim_buf_get_name(0)
    if type(name) == 'string' and name ~= '' then
      local ok, stat = pcall(uv.fs_stat, name)
      if ok and stat and stat.type == 'file' then path = name end
    end
  end)
  return path
end

--------------------------------------------------------------------------------
-- AI context
--------------------------------------------------------------------------------

local function build_ai_context(result)
  local buf = 0
  local chunks = {}

  -- Track size manually to stay under MAX_CONTEXT_BYTES.
  local function add(text)
    if type(text) ~= 'string' or text == '' then return end
    if buf >= MAX_CONTEXT_BYTES then return end
    local remaining = MAX_CONTEXT_BYTES - buf
    if #text > remaining then
      chunks[#chunks + 1] = text:sub(1, math.max(0, remaining - 24)) .. '\n... [truncated]'
      buf = MAX_CONTEXT_BYTES
      return
    end
    chunks[#chunks + 1] = text
    buf = buf + #text + 1
  end

  local scan = type(result.scan) == 'table' and result.scan or {}
  local structure = type(result.structure) == 'table' and result.structure or {}
  local deps = type(result.deps) == 'table' and result.deps or {}

  add('## Project context')
  add('Root: ' .. tostring(result.root or scan.root or '?'))
  local file_count, line_count = 0, 0
  for _, f in ipairs(scan.files or {}) do
    file_count = file_count + 1
    line_count = line_count + (tonumber(f.lines) or 0)
  end
  add(('Files: %d, total lines: %d'):format(file_count, line_count))

  -- language table
  local lang_lines = {}
  local by_lang = scan.by_lang or {}
  local langs = {}
  for lang in pairs(by_lang) do langs[#langs + 1] = lang end
  table.sort(langs, function(a, b)
    return (by_lang[a].count or 0) > (by_lang[b].count or 0)
  end)
  for _, lang in ipairs(langs) do
    local agg = by_lang[lang] or {}
    lang_lines[#lang_lines + 1] = ('- %s: %d files, %d lines')
      :format(lang, agg.count or 0, agg.lines or 0)
  end
  add('\n## Languages\n' .. table.concat(lang_lines, '\n'))

  -- top-level directories
  local dir_counts, dir_seen = {}, {}
  for _, f in ipairs(scan.files or {}) do
    local top = tostring(f.rel or ''):match('^([^/]+)/')
    if top then
      if not dir_seen[top] then
        dir_seen[top] = 0
        dir_counts[#dir_counts + 1] = top
      end
      dir_seen[top] = dir_seen[top] + 1
    end
  end
  table.sort(dir_counts, function(a, b)
    if dir_seen[a] == dir_seen[b] then return a < b end
    return dir_seen[a] > dir_seen[b]
  end)
  local dir_lines = {}
  for i = 1, math.min(40, #dir_counts) do
    local d = dir_counts[i]
    dir_lines[#dir_lines + 1] = ('- %s/ (%d files)'):format(d, dir_seen[d])
  end
  if #dir_lines > 0 then
    add('\n## Top-level directories\n' .. table.concat(dir_lines, '\n'))
  end

  -- module names
  local modules, mod_seen = {}, {}
  local function add_module(name)
    if type(name) ~= 'string' or name == '' or mod_seen[name] then return end
    mod_seen[name] = true
    modules[#modules + 1] = name
  end
  for _, m in ipairs(type(structure.modules) == 'table' and structure.modules or {}) do
    add_module(m.name)
  end
  for name in pairs(type(deps.fortran) == 'table' and deps.fortran.modules or {}) do
    add_module(name)
  end
  table.sort(modules)
  if #modules > 0 then
    local shown = {}
    for i = 1, math.min(300, #modules) do shown[i] = modules[i] end
    add(('\n## Modules (%d)\n'):format(#modules) .. table.concat(shown, ', '))
  end

  -- type names
  local types = {}
  for _, t in ipairs(type(structure.types) == 'table' and structure.types or {}) do
    types[#types + 1] = ('%s (%s) in %s'):format(t.name or '?', t.kind or 'type', t.rel or '?')
  end
  if #types > 0 then
    local shown = {}
    for i = 1, math.min(300, #types) do shown[i] = '- ' .. types[i] end
    add(('\n## Key types (%d)\n'):format(#types) .. table.concat(shown, '\n'))
  end

  -- signatures
  local sigs = {}
  local rels = {}
  for rel in pairs(result.symbols or {}) do rels[#rels + 1] = rel end
  table.sort(rels)
  local function collect_from(rel)
    if #sigs >= 80 then return end
    local list = result.symbols[rel]
    if type(list) ~= 'table' then return end
    for _, s in ipairs(list) do
      if #sigs >= 80 then return end
      local kind = s.kind
      if kind == 'subroutine' or kind == 'function' or kind == 'method' or kind == 'program' then
        local sig = tostring(s.signature or s.name or '')
        if #sig > 120 then sig = sig:sub(1, 120) .. '...' end
        sigs[#sigs + 1] = ('- %s:%s %s'):format(rel, tostring(s.line or '?'), sig)
      end
    end
  end
  for _, rel in ipairs(rels) do collect_from(rel) end
  if #sigs > 0 then
    add('\n## Signatures (first 80)\n' .. table.concat(sigs, '\n'))
  end

  -- local dependency edges
  local edges = {}
  local dep_rels = {}
  do
    local seen_rel = {}
    for _, src in ipairs({ type(deps.python) == 'table' and deps.python.imports or nil,
      type(deps.c) == 'table' and deps.c.includes or nil }) do
      for rel in pairs(src or {}) do
        if not seen_rel[rel] then
          seen_rel[rel] = true
          dep_rels[#dep_rels + 1] = rel
        end
      end
    end
    table.sort(dep_rels)
  end
  local fortran = deps.fortran
  if type(fortran) == 'table' then
    local names = {}
    for name in pairs(fortran.modules or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      if #edges >= 120 then break end
      local m = fortran.modules[name]
      local users = type(m.used_by) == 'table' and m.used_by or {}
      edges[#edges + 1] = ('- module %s (defined in %s) used by %s')
        :format(name, tostring(m.defined_in or 'external'),
          #users > 0 and table.concat(users, ', ') or 'nobody')
    end
  end
  local py = deps.python
  if type(py) == 'table' then
    for _, rel in ipairs(dep_rels) do
      if #edges >= 200 then break end
      local entry = (py.imports or {})[rel]
      if type(entry) == 'table' and type(entry['local']) == 'table' and #entry['local'] > 0 then
        edges[#edges + 1] = ('- %s imports %s'):format(rel, table.concat(entry['local'], ', '))
      end
    end
  end
  local c = deps.c
  if type(c) == 'table' then
    for _, rel in ipairs(dep_rels) do
      if #edges >= 260 then break end
      local entry = (c.includes or {})[rel]
      if type(entry) == 'table' and type(entry['local']) == 'table' and #entry['local'] > 0 then
        edges[#edges + 1] = ('- %s includes %s'):format(rel, table.concat(entry['local'], ', '))
      end
    end
  end
  if #edges > 0 then
    add('\n## Local dependency edges\n' .. table.concat(edges, '\n'))
  end

  -- external dependencies (names only)
  local external = {}
  if type(c) == 'table' then
    for _, entry in pairs(c.includes or {}) do
      for _, name in ipairs(type(entry) == 'table' and entry.system or {}) do
        external[name] = true
      end
    end
  end
  if type(py) == 'table' then
    for _, entry in pairs(py.imports or {}) do
      for _, name in ipairs(type(entry) == 'table' and entry.external or {}) do
        external[name] = true
      end
    end
  end
  local ext_names = {}
  for name in pairs(external) do ext_names[#ext_names + 1] = name end
  table.sort(ext_names)
  if #ext_names > 0 then
    local shown = {}
    for i = 1, math.min(60, #ext_names) do shown[i] = ext_names[i] end
    add(('\n## External dependencies (%d)\n'):format(#ext_names) .. table.concat(shown, ', '))
  end

  local text = table.concat(chunks, '\n')
  if #text > MAX_CONTEXT_BYTES then text = text:sub(1, MAX_CONTEXT_BYTES) end
  return text
end

M.build_ai_context = build_ai_context

M.AI_PROMPT = table.concat({
  'You are a senior software architect reviewing a scientific-computing project',
  '(Fortran, C, C++, Python) for a new contributor.',
  'You are given a machine-generated static analysis context: languages, top-level',
  'directories, module names, key types, function signatures and local dependency',
  'edges. Write a concise architecture note in Markdown (at most 700 words) with',
  "these '###' subsections:",
  '1. Overview - what the project appears to do and how it is organised.',
  '2. Core modules and data flow - the main computational units, entry points and',
  'how control flows between them.',
  '3. Dependencies and layering - module coupling, layering violations or cycles',
  'you can infer from the edges.',
  '4. Risks - oversized files, high fan-in routines, unclear ownership, portability',
  'or build-system concerns.',
  '5. Recommendations - concrete refactoring steps ordered by impact.',
  'Use only the facts in the context. Never invent file names, routine names or',
  'dependencies. When something cannot be inferred from the context, say so',
  'explicitly instead of guessing.',
}, '\n')

--------------------------------------------------------------------------------
-- sequential runner
--------------------------------------------------------------------------------

local function chain(steps, done)
  local index = 0
  local function advance(err)
    if err then
      done(err)
      return
    end
    index = index + 1
    local step = steps[index]
    if not step then
      done(nil)
      return
    end
    local called = false
    local function next_step(step_err)
      if called then return end
      called = true
      advance(step_err)
    end
    local ok, perr = pcall(step, next_step)
    if not ok then next_step(tostring(perr)) end
  end
  advance(nil)
end

M.chain = chain

local function empty_scan(root)
  return { root = root, files = {}, by_lang = {}, skipped = 0, truncated = false }
end

--------------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------------

---Run the full analysis pipeline.
---@param opts table|nil {
---   root = string|nil, use_ai = boolean|nil, model = string|nil,
---   on_done = fun(report_path:string|nil, err:string|nil)|nil,
---   silent = boolean|nil, extra_ignore = string[]|nil, max_files = integer|nil }
---@return boolean started
function M.run(opts)
  opts = type(opts) == 'table' and opts or {}
  local on_done = type(opts.on_done) == 'function' and opts.on_done or nil
  local silent = opts.silent == true

  if state.running then
    warn('DSH Studio: an analysis is already running')
    if on_done then pcall(on_done, nil, 'analysis already running') end
    return false
  end

  state.running = true
  state.started_at = os.time()
  state.last_error = nil

  local result = {
    root = nil,
    scan = nil,
    symbols = {},
    deps = { fortran = nil, c = nil, python = nil },
    graph = {},
    structure = { modules = {}, entry_points = {}, types = {}, largest = {} },
    ai_section = nil,
    report = nil,
    report_path = nil,
    errors = {},
    started_at = state.started_at,
    finished_at = nil,
  }

  local function record_error(msg)
    result.errors[#result.errors + 1] = tostring(msg)
  end

  local function finish(err)
    state.running = false
    result.finished_at = os.time()
    state.finished_at = result.finished_at
    state.last = result
    state.last_report = result.report_path
    state.last_error = err
    local summary
    if result.report_path then
      summary = ('DSH Studio: analysis written to %s (%d warnings)')
        :format(result.report_path, #result.errors)
    else
      summary = ('DSH Studio: analysis finished without a report (%s)')
        :format(tostring(err or 'no report path'))
    end
    if not silent then progress(summary) end
    if on_done then pcall(on_done, result.report_path, err) end
  end

  local steps = {}

  -- 1. detect root -----------------------------------------------------------
  steps[#steps + 1] = function(next)
    result.root = opts.root or M.detect()
    if type(result.root) ~= 'string' or result.root == '' then
      record_error('no project root detected')
      return next('no project root detected')
    end
    if not silent then progress('DSH Studio: scanning ' .. result.root) end
    next(nil)
  end

  -- 2. scan ------------------------------------------------------------------
  steps[#steps + 1] = function(next)
    local scan_ok, scan_mod = pcall(require, 'dshstudio.project.scan')
    if not scan_ok or type(scan_mod) ~= 'table' then
      record_error('scan module unavailable')
      result.scan = empty_scan(result.root)
      return next(nil)
    end
    local collect_ok, scan = pcall(scan_mod.collect, result.root, {
      max_files = tonumber(opts.max_files) or 4000,
      max_bytes_per_file = 2 * 1024 * 1024,
      extra_ignore = opts.extra_ignore,
    })
    if collect_ok and type(scan) == 'table' then
      result.scan = scan
    else
      record_error('scan failed')
      result.scan = empty_scan(result.root)
    end
    local count = #(result.scan.files or {})
    if not silent then progress(('DSH Studio: %d files collected'):format(count)) end
    next(nil)
  end

  -- 3. symbols ---------------------------------------------------------------
  steps[#steps + 1] = function(next)
    local sym_ok, sym_mod = pcall(require, 'dshstudio.project.symbols')
    if not sym_ok or type(sym_mod) ~= 'table' then
      record_error('symbols module unavailable')
      result.symbols = {}
      return next(nil)
    end

    local finished = false
    local function receive(by_file)
      if finished then return end
      finished = true
      result.symbols = type(by_file) == 'table' and by_file or {}
      if not silent then
        progress(('DSH Studio: symbols extracted (%d)'):format(sym_mod.count(result.symbols)))
      end
      next(nil)
    end

    local started = false
    local run_ok = pcall(function()
      started = sym_mod.extract_project_async(result.scan, {
        max_files = 2000,
        on_progress = function(done, total)
          if silent then return end
          if total > 0 and (done % 200 == 0 or done >= total) then
            progress(('DSH Studio: symbols %d/%d'):format(done, total))
          end
        end,
      }, receive)
    end)

    if not run_ok or started ~= true then
      local sync_ok, by_file = pcall(sym_mod.extract_project, result.scan, { max_files = 2000 })
      receive(sync_ok and by_file or {})
    end
  end

  -- 4. static dependencies ---------------------------------------------------
  steps[#steps + 1] = function(next)
    local static_ok, static_mod = pcall(require, 'dshstudio.project.static')
    if not static_ok or type(static_mod) ~= 'table' then
      record_error('static module unavailable')
      return next(nil)
    end

    local function run_dep(fn, slot, cb)
      local got = false
      local function receive(res)
        if got then return end
        got = true
        result.deps[slot] = type(res) == 'table' and res or nil
        cb()
      end
      local ok, started = pcall(fn, receive)
      if not ok then
        record_error(slot .. ' dependency pass failed')
        receive(nil)
        return
      end
      if started ~= true then receive(started) end
    end

    run_dep(function(cb) return static_mod.fortran_uses(result.scan, cb) end, 'fortran', function()
      run_dep(function(cb) return static_mod.c_deps(result.scan, cb) end, 'c', function()
        run_dep(function(cb) return static_mod.python_deps(result.scan, cb) end, 'python', function()
          if not silent then progress('DSH Studio: dependencies resolved') end
          next(nil)
        end)
      end)
    end)
  end

  -- 5. structure -------------------------------------------------------------
  steps[#steps + 1] = function(next)
    local static_ok, static_mod = pcall(require, 'dshstudio.project.static')
    if not static_ok or type(static_mod) ~= 'table'
      or type(static_mod.structure) ~= 'function' then
      record_error('structure pass unavailable')
      return next(nil)
    end
    local finished = false
    local function receive(res)
      if finished then return end
      finished = true
      if type(res) == 'table' then result.structure = res end
      next(nil)
    end
    local ok, started = pcall(static_mod.structure, result.scan, result.symbols, receive)
    if not ok then
      record_error('structure pass failed')
      return receive(nil)
    end
    if started ~= true then receive(started) end
  end

  -- 6. call graph ------------------------------------------------------------
  steps[#steps + 1] = function(next)
    local static_ok, static_mod = pcall(require, 'dshstudio.project.static')
    if not static_ok or type(static_mod) ~= 'table'
      or type(static_mod.call_graph) ~= 'function' then
      record_error('call graph unavailable')
      result.graph = {}
      return next(nil)
    end
    local dep_list = {}
    for _, slot in ipairs({ 'fortran', 'c', 'python' }) do
      local d = result.deps[slot]
      if type(d) == 'table' then dep_list[#dep_list + 1] = d end
    end
    local ok, graph = pcall(static_mod.call_graph, dep_list, result.symbols)
    result.graph = (ok and type(graph) == 'table') and graph or {}
    next(nil)
  end

  -- 7. AI architecture notes (optional) ------------------------------------
  if opts.use_ai then
    steps[#steps + 1] = function(next)
      if not silent then progress('DSH Studio: requesting AI architecture notes...') end

      local finished = false
      local function receive(ok, text, err)
        if finished then return end
        finished = true
        if ok and type(text) == 'string' and text ~= '' then
          result.ai_section = text
        else
          local reason = tostring(err or 'unknown error')
          record_error('AI analysis failed: ' .. reason)
          result.ai_section = ('_AI architecture notes unavailable: %s_'):format(reason)
        end
        next(nil)
      end

      local headless_ok, headless = pcall(require, 'dshstudio.core.headless')
      if not headless_ok or type(headless) ~= 'table'
        or type(headless.analyze) ~= 'function' then
        record_error('AI module unavailable')
        result.ai_section = '_AI module unavailable; architecture notes were skipped._'
        return next(nil)
      end

      local request = {
        root = result.root,
        model = opts.model,
        max_files = 120,
        prompt = M.AI_PROMPT,
        context = build_ai_context(result),
      }

      local call_ok = pcall(headless.analyze, request, receive)
      if not call_ok then
        receive(false, nil, 'headless.analyze() raised an error')
      else
        -- Never let a silent headless module stall the pipeline.
        pcall(vim.defer_fn, function()
          receive(false, nil, 'timed out waiting for the AI module')
        end, 180000)
      end
    end
  end

  -- 8. build + write ---------------------------------------------------------
  steps[#steps + 1] = function(next)
    local report_ok, report_mod = pcall(require, 'dshstudio.project.report')
    if not report_ok or type(report_mod) ~= 'table' then
      record_error('report module unavailable')
      return next('report module unavailable')
    end

    result.report_path = output_path(result.root)
    local ctx = {
      root = result.root,
      scan = result.scan,
      symbols = result.symbols,
      usage = result.deps.fortran,
      deps = result.deps,
      graph = result.graph,
      structure = result.structure,
      ai_section = result.ai_section,
      generated_at = os.date('%Y-%m-%d %H:%M:%S'),
      version = plugin_version(),
    }

    local built_ok, doc = pcall(report_mod.build, ctx)
    result.report = built_ok and doc or nil

    local written = false
    local write_ok, write_res = pcall(report_mod.write, ctx, result.report_path)
    if write_ok then written = write_res == true end
    if not written then
      record_error('failed to write report to ' .. tostring(result.report_path))
      result.report_path = nil
      return next(nil)
    end

    if not silent then
      local open_ok, open_mod = pcall(require, 'dshstudio.project.report')
      if open_ok and type(open_mod) == 'table' and type(open_mod.open) == 'function' then
        pcall(open_mod.open, {}, result.report_path)
      end
    end
    next(nil)
  end

  chain(steps, function(err)
    finish(err)
  end)
  return true
end

--------------------------------------------------------------------------------
-- menu / report opening
--------------------------------------------------------------------------------

---Open a report in a new tab, without throwing.
---@param path string|nil defaults to the last report
---@return boolean opened
function M.open_report(path)
  local opened = false
  pcall(function()
    local target = path
    if type(target) ~= 'string' or target == '' then target = state.last_report end
    if type(target) ~= 'string' or target == '' then
      warn('DSH Studio: no report to open yet')
      return
    end
    vim.cmd('tabnew')
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, buf, target)
    pcall(vim.api.nvim_win_set_buf, 0, buf)
    local read_ok, lines = pcall(vim.fn.readfile, target)
    if read_ok and type(lines) == 'table' and #lines > 0 then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    else
      warn('DSH Studio: report file is empty or unreadable: ' .. tostring(target))
    end
    pcall(function() vim.bo[buf].filetype = 'markdown' end)
    pcall(function() vim.bo[buf].swapfile = false end)
    pcall(function() vim.bo[buf].buflisted = true end)
    opened = true
  end)
  return opened
end

---Alias kept for callers that look for `analysis.open`.
---@param path string|nil
---@return boolean
function M.open(path)
  return M.open_report(path)
end

---Small `vim.ui.select` menu for the analysis entry points.
---@return nil
function M.menu()
  local labels = {
    'Static analysis only (fast, offline)',
    'Static analysis + AI architecture notes (DeepSeek)',
    'Open last report',
    'Analyze current file',
  }

  local function choose(index)
    if index == 1 then
      M.run({ use_ai = false })
    elseif index == 2 then
      M.run({ use_ai = true, model = config_string('model') })
    elseif index == 3 then
      M.open_report(state.last_report)
    elseif index == 4 then
      local file = current_file()
      if not file then
        warn('DSH Studio: current buffer has no file on disk')
        return
      end
      local dir_ok, dir = pcall(vim.fs.dirname, file)
      local root = (dir_ok and type(dir) == 'string' and dir ~= '') and dir or M.detect()
      if not root then
        warn('DSH Studio: cannot determine a root for the current file')
        return
      end
      progress(('DSH Studio: analyzing current file %s'):format(file))
      M.run({ root = root, use_ai = false })
    end
  end

  local ok = pcall(vim.ui.select, labels, {
    prompt = 'DSH Studio: project analysis',
    kind = 'dshstudio_analysis',
  }, function(_, index)
    pcall(choose, tonumber(index) or 0)
  end)

  if not ok then
    -- vim.ui.select should always exist in 0.11; degrade to the default action.
    M.run({ use_ai = false })
  end
end

---Human readable dump of the last cached run (used by :commands and tests).
---@return string
function M.describe()
  local lines = {}
  pcall(function()
    local r = state.last
    if type(r) ~= 'table' then
      lines[#lines + 1] = 'no analysis cached'
      return
    end
    lines[#lines + 1] = 'root: ' .. tostring(r.root)
    lines[#lines + 1] = 'report: ' .. tostring(r.report_path)
    local files = type(r.scan) == 'table' and #(r.scan.files or {}) or 0
    lines[#lines + 1] = 'files: ' .. files
    local symbols = 0
    for _, list in pairs(r.symbols or {}) do
      if type(list) == 'table' then symbols = symbols + #list end
    end
    lines[#lines + 1] = 'symbols: ' .. symbols
    lines[#lines + 1] = 'errors: ' .. tostring(#(r.errors or {}))
    for _, e in ipairs(r.errors or {}) do lines[#lines + 1] = '  - ' .. tostring(e) end
  end)
  return table.concat(lines, '\n')
end

return M
