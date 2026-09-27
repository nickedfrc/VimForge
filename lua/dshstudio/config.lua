-- dshstudio/config.lua
--
-- Central user-option table for DSH Studio.
--
-- Resolution order (lowest precedence first):
--   1. the module defaults below
--   2. `vim.g.dshstudio`                    -- set from the user's init.lua
--   3. `DSHSTUDIO_*` environment variables  -- useful for CI / launcher scripts
--   4. `require('dshstudio.config').setup({ ... })`  -- explicit, wins over all
--
-- The module table mirrors the resolved values, so both `config.theme` and
-- `config.get('theme')` work. `config.get()` also accepts dotted paths such as
-- `'lsp.clangd'`, which is what `dshstudio.lsp` uses.
--
-- NOTE: this file must never require another dshstudio module at load time; the
-- UI/session modules require *it* during startup and a cycle would break them.

local M = {}

-- Keys that belong to the module API and must never be overwritten by a user
-- supplied option table (e.g. `vim.g.dshstudio.setup = 'oops'`).
local PROTECTED = {
  setup = true,
  get = true,
  set = true,
  all = true,
  values = true,
  defaults = true,
  env_vars = true,
  resolve_analysis_dir = true,
  resolve = true,
  merge = true,
}

---Default options. Every key documented inline.
local defaults = {
  -- UI -----------------------------------------------------------------------
  theme = 'dsh-dark', -- colour scheme name loaded by the DSH Studio theme module
  sidebar_width = 46, -- columns for the DSH chat sidebar
  outline_width = 34, -- columns for the symbol outline panel
  keymaps = true, -- install the default keymaps (dshstudio.keymaps)

  -- Agent context ------------------------------------------------------------
  auto_context = true, -- attach editor context to every prompt automatically
  context_max_bytes = 24000, -- hard cap on serialised context size
  context_max_lines = 400, -- hard cap on context line count
  auto_approve = 'ask', -- 'ask' | 'always' | 'never' -- tool-call approval policy

  -- Agent process ------------------------------------------------------------
  agent_command = nil, -- string[] | nil -- nil means "auto-detect dsh on PATH"
  model = nil, -- string | nil -- nil keeps the agent's default model
  reasoning_effort = nil, -- string | nil -- 'low' | 'medium' | 'high' when set
  analysis_model = nil, -- string | nil -- model used by project deep analysis

  -- Project analysis ---------------------------------------------------------
  -- '<cwd>' is expanded at call time by config.resolve_analysis_dir().
  analysis_output_dir = '<cwd>/.dshstudio',

  -- Treesitter ---------------------------------------------------------------
  treesitter_ensure = {
    'c',
    'cpp',
    'fortran',
    'python',
    'lua',
    'vim',
    'vimdoc',
    'bash',
    'json',
    'yaml',
    'markdown',
    'cmake',
    'diff',
  },

  -- LSP ----------------------------------------------------------------------
  -- fortran_include_dirs / extra_include_dirs are also accepted nested inside
  -- `lsp` (both spellings); the resolved value is the deduplicated union.
  fortran_include_dirs = {}, -- string[] -- -I dirs handed to fortls
  extra_include_dirs = {}, -- string[] -- -I dirs handed to clangd fallbackFlags
  lsp = {
    clangd = true, -- C / C++ via clangd
    pyright = true, -- Python via pyright-langserver
    fortls = true, -- Fortran via fortls
    lua_ls = true, -- Lua via lua-language-server
    fortran_include_dirs = {}, -- string[] -- nested spelling (see above)
    extra_include_dirs = {}, -- string[] -- nested spelling (see above)
  },
}

-- Environment variable surface. `kind` selects the coercion applied.
local ENV = {
  { key = 'theme', env = 'DSHSTUDIO_THEME', kind = 'string' },
  { key = 'sidebar_width', env = 'DSHSTUDIO_SIDEBAR_WIDTH', kind = 'int' },
  { key = 'outline_width', env = 'DSHSTUDIO_OUTLINE_WIDTH', kind = 'int' },
  { key = 'keymaps', env = 'DSHSTUDIO_KEYMAPS', kind = 'bool' },
  { key = 'auto_context', env = 'DSHSTUDIO_AUTO_CONTEXT', kind = 'bool' },
  { key = 'context_max_bytes', env = 'DSHSTUDIO_CONTEXT_MAX_BYTES', kind = 'int' },
  { key = 'context_max_lines', env = 'DSHSTUDIO_CONTEXT_MAX_LINES', kind = 'int' },
  { key = 'auto_approve', env = 'DSHSTUDIO_AUTO_APPROVE', kind = 'enum', allowed = { 'ask', 'always', 'never' } },
  { key = 'agent_command', env = 'DSHSTUDIO_AGENT_COMMAND', kind = 'argv' },
  { key = 'model', env = 'DSHSTUDIO_MODEL', kind = 'string' },
  { key = 'reasoning_effort', env = 'DSHSTUDIO_REASONING_EFFORT', kind = 'string' },
  { key = 'analysis_model', env = 'DSHSTUDIO_ANALYSIS_MODEL', kind = 'string' },
  { key = 'analysis_output_dir', env = 'DSHSTUDIO_ANALYSIS_OUTPUT_DIR', kind = 'string' },
  { key = 'treesitter_ensure', env = 'DSHSTUDIO_TREESITTER_ENSURE', kind = 'list' },
  { key = 'fortran_include_dirs', env = 'DSHSTUDIO_FORTRAN_INCLUDE_DIRS', kind = 'list' },
  { key = 'extra_include_dirs', env = 'DSHSTUDIO_EXTRA_INCLUDE_DIRS', kind = 'list' },
  { key = 'lsp.clangd', env = 'DSHSTUDIO_LSP_CLANGD', kind = 'bool' },
  { key = 'lsp.pyright', env = 'DSHSTUDIO_LSP_PYRIGHT', kind = 'bool' },
  { key = 'lsp.fortls', env = 'DSHSTUDIO_LSP_FORTLS', kind = 'bool' },
  { key = 'lsp.lua_ls', env = 'DSHSTUDIO_LSP_LUA_LS', kind = 'bool' },
}

local SERVER_KEYS = { 'clangd', 'pyright', 'fortls', 'lua_ls' }

-- Coercion helpers -----------------------------------------------------------
-- Users set options through vim.g / env vars, so every value arrives untyped.
-- Coercing against the defaults keeps downstream modules free of type checks.

local function to_bool(value, fallback)
  if type(value) == 'boolean' then
    return value
  end
  if type(value) == 'number' then
    return value ~= 0
  end
  if type(value) == 'string' then
    local s = value:lower()
    if s == '1' or s == 'true' or s == 'yes' or s == 'on' then
      return true
    end
    if s == '0' or s == 'false' or s == 'no' or s == 'off' then
      return false
    end
  end
  return fallback
end

local function to_int(value, fallback)
  if type(value) == 'number' then
    return math.floor(value)
  end
  if type(value) == 'string' then
    local n = tonumber(value)
    if n then
      return math.floor(n)
    end
  end
  return fallback
end

local function to_str(value, fallback)
  if type(value) == 'string' and value ~= '' then
    return value
  end
  return fallback
end

---Split "a,b;c" (also accepts a real list) into a trimmed string list.
local function to_list(value)
  local out = {}
  if type(value) == 'table' then
    for _, item in ipairs(value) do
      if type(item) == 'string' then
        local trimmed = item:match('^%s*(.-)%s*$')
        if trimmed ~= '' then
          out[#out + 1] = trimmed
        end
      end
    end
    return out
  end
  if type(value) == 'string' then
    for part in value:gmatch('[^,;]+') do
      local trimmed = part:match('^%s*(.-)%s*$')
      if trimmed ~= '' then
        out[#out + 1] = trimmed
      end
    end
  end
  return out
end

---Split an env var into argv. Quoted arguments with embedded spaces are not
---supported here on purpose -- use setup({ agent_command = {...} }) for those.
local function to_argv(value)
  local out = {}
  if type(value) == 'table' then
    return to_list(value)
  end
  if type(value) == 'string' then
    for part in value:gmatch('%S+') do
      out[#out + 1] = part
    end
  end
  return out
end

local function to_enum(value, allowed, fallback)
  if type(value) == 'string' then
    local s = value:lower()
    for _, candidate in ipairs(allowed or {}) do
      if s == candidate then
        return s
      end
    end
  end
  return fallback
end

local function dedupe(list)
  local seen = {}
  local out = {}
  for _, item in ipairs(list or {}) do
    if type(item) == 'string' and item ~= '' and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

-- Dotted-path access ---------------------------------------------------------

local function get_path(tbl, path)
  if type(tbl) ~= 'table' or type(path) ~= 'string' then
    return nil
  end
  local node = tbl
  for part in path:gmatch('[^.]+') do
    if type(node) ~= 'table' then
      return nil
    end
    node = node[part]
  end
  return node
end

local function set_path(tbl, path, value)
  if type(tbl) ~= 'table' or type(path) ~= 'string' then
    return
  end
  local parts = {}
  for part in path:gmatch('[^.]+') do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return
  end
  local node = tbl
  for i = 1, #parts - 1 do
    if type(node[parts[i]]) ~= 'table' then
      node[parts[i]] = {}
    end
    node = node[parts[i]]
  end
  node[parts[#parts]] = value
end

-- Merge ----------------------------------------------------------------------

---Deep merge that never throws, even when the user's table has a scalar where
---the defaults have a table (vim.tbl_deep_extend is picky about that shape).
local function deep_merge(base, override)
  if type(override) ~= 'table' then
    return base
  end
  local ok, merged = pcall(vim.tbl_deep_extend, 'force', base, override)
  if ok and type(merged) == 'table' then
    return merged
  end
  local out = {}
  for k, v in pairs(base) do
    out[k] = v
  end
  for k, v in pairs(override) do
    if type(v) == 'table' and type(out[k]) == 'table' then
      out[k] = deep_merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

---Apply DSHSTUDIO_* environment variables on top of an already merged table.
local function apply_env(values)
  local applied = {}
  for _, spec in ipairs(ENV) do
    local raw = vim.env[spec.env]
    if raw ~= nil and raw ~= '' then
      local current = get_path(values, spec.key)
      local value
      if spec.kind == 'bool' then
        value = to_bool(raw, current)
      elseif spec.kind == 'int' then
        value = to_int(raw, current)
      elseif spec.kind == 'enum' then
        value = to_enum(raw, spec.allowed, current)
      elseif spec.kind == 'list' then
        value = to_list(raw)
      elseif spec.kind == 'argv' then
        value = to_argv(raw)
      else
        value = to_str(raw, current)
      end
      set_path(values, spec.key, value)
      applied[#applied + 1] = spec.env
    end
  end
  return applied
end

---Force every known option into its declared type after user/env merging.
local function coerce(values)
  values.theme = to_str(values.theme, defaults.theme)
  values.sidebar_width = to_int(values.sidebar_width, defaults.sidebar_width)
  values.outline_width = to_int(values.outline_width, defaults.outline_width)
  values.keymaps = to_bool(values.keymaps, defaults.keymaps)
  values.auto_context = to_bool(values.auto_context, defaults.auto_context)
  values.context_max_bytes = to_int(values.context_max_bytes, defaults.context_max_bytes)
  values.context_max_lines = to_int(values.context_max_lines, defaults.context_max_lines)
  values.auto_approve = to_enum(values.auto_approve, { 'ask', 'always', 'never' }, defaults.auto_approve)
  values.analysis_output_dir = to_str(values.analysis_output_dir, defaults.analysis_output_dir)
  values.model = to_str(values.model, nil)
  values.reasoning_effort = to_str(values.reasoning_effort, nil)
  values.analysis_model = to_str(values.analysis_model, nil)

  -- agent_command: nil means auto-detect; an empty list is normalised to nil.
  local argv = to_argv(values.agent_command)
  values.agent_command = (#argv > 0) and argv or nil

  local ensure = to_list(values.treesitter_ensure)
  values.treesitter_ensure = (#ensure > 0) and ensure or defaults.treesitter_ensure

  if type(values.lsp) ~= 'table' then
    values.lsp = vim.deepcopy(defaults.lsp)
  end
  for _, name in ipairs(SERVER_KEYS) do
    values.lsp[name] = to_bool(values.lsp[name], defaults.lsp[name])
  end

  -- Accept both the top-level and the nested spelling of the include dirs and
  -- keep them in sync so any consumer sees the same union.
  local fortran_dirs = dedupe(
    vim.list_extend(to_list(values.fortran_include_dirs), to_list(values.lsp.fortran_include_dirs))
  )
  local extra_dirs = dedupe(
    vim.list_extend(to_list(values.extra_include_dirs), to_list(values.lsp.extra_include_dirs))
  )
  values.fortran_include_dirs = fortran_dirs
  values.extra_include_dirs = extra_dirs
  values.lsp.fortran_include_dirs = fortran_dirs
  values.lsp.extra_include_dirs = extra_dirs

  return values
end

-- Module state ---------------------------------------------------------------

M.defaults = vim.deepcopy(defaults)
local values = {}

---Resolve defaults + vim.g + env + explicit opts into a fresh table.
---@param opts table|nil
---@return table
function M.resolve(opts)
  local merged = deep_merge(vim.deepcopy(defaults), type(vim.g.dshstudio) == 'table' and vim.g.dshstudio or {})
  apply_env(merged)
  merged = deep_merge(merged, type(opts) == 'table' and opts or {})
  return coerce(merged)
end

local function mirror(resolved)
  values = resolved
  M.values = values
  for key, value in pairs(values) do
    if not PROTECTED[key] then
      M[key] = value
    end
  end
  return M
end

---Merge user options and publish them on the module table.
---@param opts table|nil
---@return table self
function M.setup(opts)
  return mirror(M.resolve(opts))
end

---Read a resolved option. Supports dotted paths ('lsp.clangd').
---@param key string|nil  nil returns the whole table
---@param fallback any    returned when the key is unknown
function M.get(key, fallback)
  if key == nil then
    return values
  end
  local value = get_path(values, key)
  if value == nil then
    value = get_path(defaults, key)
  end
  if value == nil then
    return fallback
  end
  return value
end

---Override a single option at runtime (does not touch vim.g or the env).
---@param key string dotted path accepted
---@param value any
function M.set(key, value)
  set_path(values, key, value)
  if type(key) == 'string' and not key:find('.', 1, true) and not PROTECTED[key] then
    M[key] = value
  end
  return value
end

---Snapshot of the resolved options (copy, safe to mutate).
function M.all()
  return vim.deepcopy(values)
end

---Names of the environment variables this module understands.
---@return string[]
function M.env_vars()
  local names = {}
  for _, spec in ipairs(ENV) do
    names[#names + 1] = spec.env
  end
  table.sort(names)
  return names
end

---Expand the '<cwd>' placeholder in analysis_output_dir.
---@param dir string|nil defaults to the configured value
---@return string|nil absolute-ish path
function M.resolve_analysis_dir(dir)
  local value = dir or values.analysis_output_dir or defaults.analysis_output_dir
  if type(value) ~= 'string' or value == '' then
    return nil
  end
  local cwd = '.'
  local ok, cwd_or_err = pcall(vim.fn.getcwd)
  if ok and type(cwd_or_err) == 'string' and cwd_or_err ~= '' then
    cwd = cwd_or_err
  end
  -- Function replacement: a cwd containing '%' must not be treated as a
  -- gsub capture reference.
  value = value:gsub('<cwd>', function()
    return cwd
  end)
  value = value:gsub('^~', function()
    local home = vim.env.HOME or vim.env.USERPROFILE or '~'
    return home
  end)
  return value
end

-- Resolve once at load so `config.theme`-style access works even when the
-- integrator never calls setup().
mirror(M.resolve({}))

return M
