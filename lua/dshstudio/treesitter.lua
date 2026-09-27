-- dshstudio/treesitter.lua
--
-- Treesitter wiring for DSH Studio.
--
-- Two plugin generations have to be supported:
--   * classic branch  -> `require('nvim-treesitter.configs').setup{...}`
--   * main branch     -> `require('nvim-treesitter').setup{}/.install{...}` plus
--                        Neovim's built-in highlighter per buffer
--   * no plugin at all -> still start the built-in highlighter/folding whenever a
--                        compiled parser happens to be on the runtimepath
-- Every path is pcall-guarded: a broken or missing plugin must never abort
-- startup, and `M.setup()` reports which path it took instead of failing.

local M = {}

---Canonical languages the distribution ships support for.
---`ft` is the Neovim filetype, `lang` the tree-sitter parser name (they differ
---for sh/bash and for fixed-form Fortran aliases).
local LANGUAGES = {
  { ft = 'fortran', lang = 'fortran' },
  { ft = 'c', lang = 'c' },
  { ft = 'cpp', lang = 'cpp' },
  { ft = 'python', lang = 'python' },
  { ft = 'lua', lang = 'lua' },
  { ft = 'vim', lang = 'vim' },
  { ft = 'vimdoc', lang = 'vimdoc' },
  { ft = 'bash', lang = 'bash' },
  { ft = 'json', lang = 'json' },
  { ft = 'yaml', lang = 'yaml' },
  { ft = 'markdown', lang = 'markdown' },
  { ft = 'cmake', lang = 'cmake' },
  { ft = 'diff', lang = 'diff' },
}

---Filetype -> parser aliases beyond the 1:1 mapping above.
local FT_ALIASES = {
  f90 = 'fortran',
  f95 = 'fortran',
  f03 = 'fortran',
  f08 = 'fortran',
  sh = 'bash',
  zsh = 'bash',
  jsonc = 'json',
  cuda = 'cpp',
  ['c++'] = 'cpp',
  ['objective-c'] = 'objc',
  objcpp = 'objc',
}

---Parser availability cache. Only positive results are cached so a parser
---installed mid-session is picked up on the next check.
local parser_cache = {}
local did_setup = false

local function notify(msg, level)
  local ok, util = pcall(require, 'dshstudio.util')
  if ok and type(util) == 'table' and type(util.notify) == 'function' then
    pcall(util.notify, msg, level)
    return
  end
  pcall(vim.notify, msg, level == 'error' and vim.log.levels.ERROR or vim.log.levels.WARN, { title = 'DSH Studio' })
end

---The configured ensure list, falling back to the canonical parser list.
---@return string[]
local function configured_languages()
  local ok, config = pcall(require, 'dshstudio.config')
  if ok and type(config) == 'table' then
    local list = nil
    if type(config.get) == 'function' then
      local called, value = pcall(config.get, 'treesitter_ensure')
      if called then
        list = value
      end
    end
    if type(list) ~= 'table' then
      list = config.treesitter_ensure
    end
    if type(list) == 'table' and #list > 0 then
      local out = {}
      for _, lang in ipairs(list) do
        if type(lang) == 'string' and lang ~= '' then
          out[#out + 1] = lang
        end
      end
      if #out > 0 then
        return out
      end
    end
  end
  return M.parser_list()
end

---Canonical list of parser names the distribution ships support for.
---Returns plain strings because callers feed them straight to
---`nvim-treesitter.install()` and to `M.has_parser()` (see `:DshHealth`); the
---filetype <-> parser pairing is available through M.languages/M.language_map().
---@return string[]
function M.ensure_languages()
  return M.parser_list()
end

---Map of filetype -> parser name (includes aliases such as sh -> bash).
---@return table<string, string>
function M.language_map()
  local map = {}
  for _, entry in ipairs(LANGUAGES) do
    map[entry.ft] = entry.lang
  end
  for ft, lang in pairs(FT_ALIASES) do
    map[ft] = lang
  end
  return map
end

---{ ft = ..., lang = ... } records, one per supported language (aliases such as
---sh -> bash are not included; use M.language_for() for those).
---@return string[]
function M.ensure_filetypes()
  local out = {}
  for _, entry in ipairs(LANGUAGES) do
    out[#out + 1] = entry.ft
  end
  return out
end

---Parser names only -- this is what nvim-treesitter.install() wants.
---@return string[]
function M.parser_list()
  local seen = {}
  local out = {}
  for _, entry in ipairs(LANGUAGES) do
    if not seen[entry.lang] then
      seen[entry.lang] = true
      out[#out + 1] = entry.lang
    end
  end
  return out
end

---Supported filetypes (used for the FileType autocmd patterns).
---@return string[]
function M.filetype_list()
  local out = {}
  for _, entry in ipairs(LANGUAGES) do
    out[#out + 1] = entry.ft
  end
  return out
end

---Parser name for a filetype (nil when unsupported).
---@param ft string|nil
---@return string|nil
function M.language_for(ft)
  if type(ft) ~= 'string' or ft == '' then
    return nil
  end
  for _, entry in ipairs(LANGUAGES) do
    if entry.ft == ft then
      return entry.lang
    end
  end
  return FT_ALIASES[ft]
end

---Is a parser usable right now?
---@param lang string|nil
---@return boolean
function M.has_parser(lang)
  if type(lang) ~= 'string' or lang == '' then
    return false
  end
  if parser_cache[lang] == true then
    return true
  end
  local ok, result = pcall(function()
    if type(vim.treesitter) ~= 'table' then
      return false
    end
    local language = vim.treesitter.language
    if type(language) ~= 'table' then
      return false
    end
    -- Preferred check: actually load it. add() errors when the parser is absent.
    if type(language.add) == 'function' then
      local called = pcall(language.add, lang)
      if called then
        return true
      end
    end
    if type(language.inspect) == 'function' then
      local called, info = pcall(language.inspect, lang)
      if called and info ~= nil then
        return true
      end
    end
    -- Last resort: a compiled parser on the runtimepath that add() could not
    -- load (e.g. ABI mismatch) still counts as "present" for reporting.
    local suffixes = { '.so', '.dll', '.dylib' }
    for _, suffix in ipairs(suffixes) do
      local hits = vim.api.nvim_get_runtime_file('parser/' .. lang .. suffix, false)
      if type(hits) == 'table' and #hits > 0 then
        return true
      end
    end
    return false
  end)
  local available = ok and result == true
  if available then
    parser_cache[lang] = true
  end
  return available
end

---Forget cached parser availability (after an install or for tests).
function M.clear_cache()
  parser_cache = {}
end

---Start highlighting and treesitter folding for one buffer.
---@param buf integer|nil defaults to the current buffer
---@return boolean started
function M.attach(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local ok_buf, valid = pcall(vim.api.nvim_buf_is_valid, buf)
  if not ok_buf or not valid then
    return false
  end

  local started = false
  pcall(function()
    if type(vim.treesitter) == 'table' and type(vim.treesitter.start) == 'function' then
      vim.treesitter.start(buf)
      started = true
    end
  end)

  local apply_folds = function()
    local lang = M.language_for(vim.bo[buf].filetype)
    if not lang or not M.has_parser(lang) then
      return
    end
    if type(vim.treesitter.foldexpr) ~= 'function' then
      return
    end
    local wins = vim.fn.win_findbuf(buf)
    if type(wins) ~= 'table' or #wins == 0 then
      return
    end
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_set_option_value, 'foldmethod', 'expr', { win = win })
      pcall(vim.api.nvim_set_option_value, 'foldexpr', 'v:lua.vim.treesitter.foldexpr()', { win = win })
      pcall(vim.api.nvim_set_option_value, 'foldlevel', 99, { win = win })
    end
  end

  pcall(apply_folds)
  local has_window = false
  pcall(function()
    has_window = #vim.fn.win_findbuf(buf) > 0
  end)
  if not has_window then
    -- BufReadPre-style call site: no window yet, retry once the buffer is shown.
    pcall(vim.schedule, function()
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(apply_folds)
      end
    end)
  end

  return started
end

---Register the per-buffer highlighter autocmd (used by both plugin paths; it
---skips buffers the plugin already highlighted).
---@return nil
local function start_autocmd()
  local group = vim.api.nvim_create_augroup('DshStudioTreesitter', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = M.filetype_list(),
    callback = function(args)
      pcall(function()
        local buf = args.buf
        -- The plugin (classic branch) may already own this buffer's highlighter.
        local already = false
        pcall(function()
          local ts = vim.treesitter
          already = type(ts) == 'table'
            and type(ts.highlighter) == 'table'
            and type(ts.highlighter.active) == 'table'
            and ts.highlighter.active[buf] ~= nil
        end)
        if already then
          return
        end
        local lang = M.language_for(vim.bo[buf].filetype)
        if not lang or not M.has_parser(lang) then
          return
        end
        M.attach(buf)
      end)
    end,
    desc = 'DSH Studio: tree-sitter highlighting for supported filetypes',
  })
end

---Install the plugin (if any) and wire the highlighter.
---@return string mode 'configs' | 'main' | 'builtin'
function M.setup()
  if did_setup then
    return M._mode or 'builtin'
  end
  did_setup = true

  local ensure = configured_languages()

  -- Path 1: classic nvim-treesitter (configs module available).
  local ok_configs, configs = pcall(require, 'nvim-treesitter.configs')
  if ok_configs and type(configs) == 'table' and type(configs.setup) == 'function' then
    local called = pcall(configs.setup, {
      ensure_installed = ensure,
      auto_install = true,
      highlight = {
        enable = true,
        -- Fortran files very often have no parser installed; keeping the regex
        -- highlighter as well means no file is ever rendered plain.
        additional_vim_regex_highlighting = { 'fortran' },
      },
      indent = {
        enable = true,
        -- The treesitter Python indenter fights PEP 8 continuation lines.
        disable = { 'python' },
      },
      incremental_selection = { enable = true },
    })
    if called then
      M._mode = 'configs'
      start_autocmd()
      return M._mode
    end
    notify('DSH Studio: nvim-treesitter.configs.setup() failed; falling back to the built-in highlighter', 'warn')
  end

  -- Path 2: nvim-treesitter main branch (setup/install only).
  local ok_main, ts = pcall(require, 'nvim-treesitter')
  if ok_main and type(ts) == 'table' then
    pcall(function()
      if type(ts.setup) == 'function' then
        ts.setup({})
      end
    end)
    pcall(function()
      if type(ts.install) == 'function' then
        ts.install(ensure)
      end
    end)
    M._mode = 'main'
    start_autocmd()
    return M._mode
  end

  -- Path 3: no plugin -- Neovim's built-in highlighter still works if a parser
  -- is on the runtimepath (e.g. installed by a system package).
  M._mode = 'builtin'
  start_autocmd()
  return M._mode
end

M.languages = LANGUAGES

return M
