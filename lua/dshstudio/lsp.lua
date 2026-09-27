-- dshstudio/lsp.lua
--
-- Language server setup for the languages DSH Studio ships support for:
-- Fortran, C, C++, Python and Lua.
--
-- Uses the modern Neovim 0.11 API:
--     vim.lsp.config(name, cfg)   -- define/override a server config
--     vim.lsp.enable({ names })   -- start servers by filetype
-- The legacy `require('lspconfig')` framework is deliberately not used; the
-- nvim-lspconfig 2.x plugin only contributes its `lsp/<name>.lua` runtime files,
-- which `vim.lsp.config` picks up and merges with the overrides below.
--
-- Everything optional (blink.cmp, cmp_nvim_lsp, inlay hints, diagnostics) is
-- pcall-guarded so the module also survives a half-configured installation.

local M = {}

local uv = vim.uv or vim.loop

-- Server catalogue -----------------------------------------------------------
-- One entry per supported server: how to start it, where its project root is,
-- and how to install it on each OS (used for the one-shot missing-binary hint).

local SERVERS = {
  clangd = {
    label = 'C / C++',
    binary = 'clangd',
    cmd = {
      'clangd',
      '--background-index',
      '--clang-tidy',
      '--completion-style=detailed',
      '--header-insertion=never',
      '--log=error',
    },
    filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
    root_markers = { 'compile_commands.json', '.clangd', 'CMakeLists.txt', 'Makefile', '.git' },
    install = {
      windows = {
        'winget install -e --id LLVM.LLVM',
        'scoop install llvm',
      },
      macos = {
        'brew install llvm',
        'xcode-select --install',
      },
      linux = {
        'sudo apt install clangd',
        'sudo dnf install clang-tools-extra',
        'sudo pacman -S clang',
      },
    },
  },
  pyright = {
    label = 'Python',
    binary = 'pyright-langserver',
    cmd = { 'pyright-langserver', '--stdio' },
    filetypes = { 'python' },
    root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', '.git' },
    install = {
      windows = { 'npm install -g pyright', 'pip install pyright' },
      macos = { 'brew install pyright', 'npm install -g pyright', 'pip install pyright' },
      linux = { 'npm install -g pyright', 'pip install pyright', 'sudo apt install pyright' },
    },
  },
  fortls = {
    label = 'Fortran',
    binary = 'fortls',
    cmd = { 'fortls' },
    filetypes = { 'fortran' },
    root_markers = { '.fortls', 'fpm.toml', 'CMakeLists.txt', '.git' },
    install = {
      windows = { 'pip install fortls', 'scoop install fortls' },
      macos = { 'brew install fortls', 'pip install fortls' },
      linux = { 'pip install fortls', 'pipx install fortls', 'conda install -c conda-forge fortls' },
    },
  },
  lua_ls = {
    label = 'Lua',
    binary = 'lua-language-server',
    cmd = { 'lua-language-server' },
    filetypes = { 'lua' },
    root_markers = { '.luarc.json', '.luarc.jsonc', '.git' },
    install = {
      windows = {
        'winget install LuaLS.lua-language-server',
        'scoop install lua-language-server',
      },
      macos = { 'brew install lua-language-server' },
      linux = {
        'sudo apt install lua-language-server',
        'sudo snap install lua-language-server',
        'brew install lua-language-server',
      },
    },
  },
}

-- Deterministic iteration order for reports/notifications.
local SERVER_ORDER = { 'clangd', 'pyright', 'fortls', 'lua_ls' }

-- Module state ---------------------------------------------------------------

local exe_cache = {}
local notified = {}
local summary_shown = false
local attached = false

-- Small local helpers (no dshstudio module is required at load time) ---------

local function is_windows()
  local ok, res = pcall(function()
    return vim.fn.has('win32') == 1 or package.config:sub(1, 1) == '\\'
  end)
  return ok and res == true
end

local function notify(msg, level)
  local ok, util = pcall(require, 'dshstudio.util')
  if ok and type(util) == 'table' and type(util.notify) == 'function' then
    pcall(util.notify, msg, level)
    return
  end
  pcall(vim.notify, msg, level == 'error' and vim.log.levels.ERROR or vim.log.levels.WARN, { title = 'DSH Studio' })
end

---Config accessor that works whether or not config.setup() was called.
---@param key string dotted path
---@param fallback any
local function cfg_get(key, fallback)
  local ok, config = pcall(require, 'dshstudio.config')
  if ok and type(config) == 'table' then
    if type(config.get) == 'function' then
      local called, value = pcall(config.get, key)
      if called and value ~= nil then
        return value
      end
    end
    local direct = config[key]
    if direct ~= nil then
      return direct
    end
  end
  return fallback
end

---Expand and normalise an include directory.
---@param dir string
---@return string|nil
local function normalize_dir(dir)
  if type(dir) ~= 'string' then
    return nil
  end
  local trimmed = dir:match('^%s*(.-)%s*$')
  if trimmed == '' then
    return nil
  end
  local ok, expanded = pcall(vim.fn.fnamemodify, trimmed, ':p')
  if ok and type(expanded) == 'string' and expanded ~= '' then
    return (expanded:gsub('[/\\]+$', ''))
  end
  return trimmed
end

---@param key string
---@return string[]
local function include_dirs(key)
  local seen = {}
  local out = {}
  local candidates = { cfg_get(key, {}), cfg_get('lsp.' .. key, {}) }
  for _, list in ipairs(candidates) do
    if type(list) == 'table' then
      for _, dir in ipairs(list) do
        local normalized = normalize_dir(dir)
        if normalized and not seen[normalized] then
          seen[normalized] = true
          out[#out + 1] = normalized
        end
      end
    end
  end
  return out
end

---OS id used to pick install hints.
---@return string 'windows'|'macos'|'linux'
local function current_os()
  if is_windows() then
    return 'windows'
  end
  local ok, uname = pcall(function()
    return uv.os_uname()
  end)
  if ok and type(uname) == 'table' and uname.sysname == 'Darwin' then
    return 'macos'
  end
  return 'linux'
end

---Minimal upward marker search used when dshstudio.util is unavailable.
---@param start string
---@param markers string[]
---@return string|nil
local function find_root(start, markers)
  local ok, util = pcall(require, 'dshstudio.util')
  if ok and type(util) == 'table' and type(util.find_root) == 'function' then
    local called, root = pcall(util.find_root, start, markers)
    if called then
      return root
    end
  end
  local called, fallback = pcall(function()
    local dir = start
    if type(dir) ~= 'string' or dir == '' then
      dir = vim.fn.getcwd()
    end
    if vim.fn.isdirectory(dir) == 0 then
      dir = vim.fn.fnamemodify(dir, ':h')
    end
    dir = vim.fn.fnamemodify(dir, ':p'):gsub('[/\\]+$', '')
    for _ = 1, 64 do
      if dir == '' then
        return nil
      end
      for _, marker in ipairs(markers or {}) do
        local candidate = dir .. (is_windows() and '\\' or '/') .. marker
        if vim.fn.isdirectory(candidate) == 1 or vim.fn.filereadable(candidate) == 1 then
          return dir
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
  if called and type(fallback) == 'string' then
    return fallback
  end
  return nil
end

-- Public helpers -------------------------------------------------------------

---Is `cmd` runnable? Cached for the session (see M.clear_cache()).
---@param cmd string|nil
---@return string|nil the resolvable command name, or nil
function M.which(cmd)
  if type(cmd) ~= 'string' or cmd == '' then
    return nil
  end
  local cached = exe_cache[cmd]
  if cached ~= nil then
    return cached or nil
  end
  local found = nil
  pcall(function()
    if vim.fn.executable(cmd) == 1 then
      found = cmd
      return
    end
    -- npm/pip shims on Windows: executable() usually honours $PATHEXT, but a
    -- locked-down PATHEXT would hide e.g. pyright-langserver.cmd.
    if is_windows() then
      for _, ext in ipairs({ '.exe', '.cmd', '.bat', '.ps1' }) do
        if vim.fn.executable(cmd .. ext) == 1 then
          found = cmd .. ext
          return
        end
      end
    end
  end)
  exe_cache[cmd] = found or false
  return found
end

---Drop the M.which() cache (after installing a server, or for tests).
function M.clear_cache()
  exe_cache = {}
end

---Install commands for a server on this OS.
---@param name string
---@return string[]
function M.install_commands(name)
  local spec = SERVERS[name]
  if type(spec) ~= 'table' then
    return {}
  end
  local os_id = current_os()
  local list = spec.install and spec.install[os_id] or nil
  if type(list) ~= 'table' or #list == 0 then
    return {}
  end
  local out = {}
  for _, command in ipairs(list) do
    out[#out + 1] = command
  end
  return out
end

---Human readable install hint (names the missing binary + primary command).
---@param name string
---@return string
function M.install_hint(name)
  local spec = SERVERS[name]
  local label = type(spec) == 'table' and (spec.label or name) or name
  local binary = type(spec) == 'table' and (spec.binary or name) or name
  local commands = M.install_commands(name)
  local primary = commands[1] or ('install `' .. name .. '` for your platform')
  local alternatives = {}
  for i = 2, #commands do
    alternatives[#alternatives + 1] = commands[i]
  end
  -- Spell out the binary that is missing: users search for it, not for the
  -- language label.
  local hint = ('%s (%s): %s'):format(label, binary, primary)
  if #alternatives > 0 then
    hint = hint .. '  (or: ' .. table.concat(alternatives, ' | ') .. ')'
  end
  return hint
end

---Merge completion capabilities from whichever completion plugin is present.
---@return table
function M.capabilities()
  local caps = {}
  local ok_protocol, protocol_caps = pcall(function()
    return vim.lsp.protocol.make_client_capabilities()
  end)
  if ok_protocol and type(protocol_caps) == 'table' then
    caps = protocol_caps
  end

  -- blink.cmp first: it is the completion engine the distribution ships with.
  local ok_blink, blink = pcall(require, 'blink.cmp')
  if ok_blink and type(blink) == 'table' and type(blink.get_lsp_capabilities) == 'function' then
    local called, merged = pcall(blink.get_lsp_capabilities, caps)
    if called and type(merged) == 'table' then
      return merged
    end
  end

  local ok_cmp, cmp = pcall(require, 'cmp_nvim_lsp')
  if ok_cmp and type(cmp) == 'table' then
    -- `update_capabilities` is the pre-1.x spelling kept for older installs.
    local provider = cmp.default_capabilities or cmp.update_capabilities
    if type(provider) == 'function' then
      local called, merged = pcall(provider, caps)
      if called and type(merged) == 'table' then
        return merged
      end
    end
  end

  return caps
end

---Build the per-server config tables that are handed to vim.lsp.config().
---@param capabilities table
---@return table<string, table>
function M.server_configs(capabilities)
  local caps = capabilities or M.capabilities()

  local clangd_flags = {}
  for _, dir in ipairs(include_dirs('extra_include_dirs')) do
    -- A single argv element "-I<dir>" is exactly what clang's driver expects in
    -- fallbackFlags (used when there is no compile_commands.json yet).
    clangd_flags[#clangd_flags + 1] = '-I' .. dir
  end

  local fortran_dirs = include_dirs('fortran_include_dirs')

  return {
    clangd = {
      cmd = SERVERS.clangd.cmd,
      filetypes = SERVERS.clangd.filetypes,
      root_markers = SERVERS.clangd.root_markers,
      capabilities = caps,
      init_options = {
        fallbackFlags = clangd_flags,
        -- Keeps the client from waiting on a status extension it never asked
        -- for; harmless when clangd ignores it.
        clangdFileStatus = true,
      },
    },
    pyright = {
      cmd = SERVERS.pyright.cmd,
      filetypes = SERVERS.pyright.filetypes,
      root_markers = SERVERS.pyright.root_markers,
      capabilities = caps,
      settings = {
        python = {
          analysis = {
            typeCheckingMode = 'basic',
            autoSearchPaths = true,
            useLibraryCodeForTypes = true,
          },
        },
      },
    },
    fortls = {
      cmd = SERVERS.fortls.cmd,
      filetypes = SERVERS.fortls.filetypes,
      root_markers = SERVERS.fortls.root_markers,
      capabilities = caps,
      settings = {
        fortran = {
          include_dirs = fortran_dirs,
          intrinsic_completions = true,
        },
      },
    },
    lua_ls = {
      cmd = SERVERS.lua_ls.cmd,
      filetypes = SERVERS.lua_ls.filetypes,
      root_markers = SERVERS.lua_ls.root_markers,
      capabilities = caps,
      settings = {
        Lua = {
          runtime = { version = 'LuaJIT' },
          workspace = { checkThirdParty = false },
          telemetry = { enable = false },
        },
      },
    },
  }
end

---Register the configs with vim.lsp.config (merging with nvim-lspconfig's
---runtime files when they exist).
---@return string[] configured server names
function M.configure()
  if type(vim.lsp.config) ~= 'function' then
    notify('DSH Studio: Neovim 0.11+ is required for vim.lsp.config()', 'error')
    return {}
  end
  local caps = M.capabilities()
  local configs = M.server_configs(caps)
  local configured = {}

  -- Defaults for any server started by another module/user.
  pcall(vim.lsp.config, '*', { capabilities = caps })

  for _, name in ipairs(SERVER_ORDER) do
    local spec = configs[name]
    if spec ~= nil then
      local called, err = pcall(vim.lsp.config, name, spec)
      if called then
        configured[#configured + 1] = name
      else
        notify(('DSH Studio: could not configure %s: %s'):format(name, tostring(err)), 'warn')
      end
    end
  end
  return configured
end

---Status table for a :DshLspStatus style report.
---@return table<string, {enabled:boolean, found:boolean, root:string|nil, binary:string, label:string}>
function M.server_status()
  local status = {}
  local file = ''
  pcall(function()
    file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  end)
  for _, name in ipairs(SERVER_ORDER) do
    local spec = SERVERS[name]
    local enabled = cfg_get('lsp.' .. name, true) ~= false
    local found = M.which(spec.binary) ~= nil
    local root = nil
    if file ~= '' then
      local dir = vim.fn.fnamemodify(file, ':h')
      root = find_root(dir, spec.root_markers)
    end
    status[name] = {
      enabled = enabled,
      found = found,
      root = root,
      binary = spec.binary,
      label = spec.label,
      filetypes = spec.filetypes,
      install = M.install_commands(name),
    }
  end
  return status
end

---Preformatted lines for the :DshLspStatus command.
---@return string[]
function M.status_lines()
  local lines = { 'DSH Studio LSP status (cwd: ' .. vim.fn.getcwd() .. ')' }
  local status = M.server_status()
  for _, name in ipairs(SERVER_ORDER) do
    local info = status[name]
    lines[#lines + 1] = ('  %-8s %-8s enabled=%-5s found=%-5s root=%s'):format(
      name,
      info.label,
      tostring(info.enabled),
      tostring(info.found),
      info.root or '-'
    )
    if info.enabled and not info.found then
      lines[#lines + 1] = '           install: ' .. M.install_hint(name)
    end
  end
  lines[#lines + 1] = '  Tip: `:Mason` manages all four servers when mason.nvim is installed.'
  return lines
end

---Attach-time enhancements, kept free of any key binding that could shadow the
---GUI's own shortcuts (notably nothing on <C-S>).
---@return nil
function M.attach_enhancements()
  if attached then
    return
  end
  attached = true

  local group = vim.api.nvim_create_augroup('DshStudioLspAttach', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local buf = args.buf
      if type(buf) ~= 'number' then
        return
      end
      -- Neovim's own completion entry point, so <C-x><C-o> works in LSP buffers.
      pcall(function()
        vim.bo[buf].omnifunc = 'v:lua.vim.lsp.omnifunc'
      end)
      pcall(function()
        vim.bo[buf].tagfunc = 'v:lua.vim.lsp.tagfunc'
      end)
      -- gq / `:format` route through the server's range formatting. Use the
      -- function form recommended by `:h vim.lsp.formatexpr()`; a string like
      -- "v:lua.vim.lsp.formatexpr(#{timeout_ms:1500})" is a trap, because
      -- #{...} is Lua's length operator and evaluates to 0, not a table.
      pcall(function()
        vim.bo[buf].formatexpr = function()
          return vim.lsp.formatexpr({ timeout_ms = 1500 })
        end
      end)
      -- Inlay hints: 0.11 signature is enable(enable, { bufnr = ... }).
      pcall(function()
        if type(vim.lsp.inlay_hint) == 'table' and type(vim.lsp.inlay_hint.enable) == 'function' then
          vim.lsp.inlay_hint.enable(true, { bufnr = buf })
        end
      end)
      -- Diagnostics must be visible in the sign column for scientific code.
      pcall(function()
        if vim.diagnostic and type(vim.diagnostic.config) == 'function' then
          vim.diagnostic.config({ virtual_text = true, signs = true, underline = true, update_in_insert = false })
        end
      end)
      pcall(function()
        vim.b[buf].dshstudio_lsp_enhanced = true
      end)
    end,
    desc = 'DSH Studio: LSP buffer defaults (omnifunc, inlay hints, diagnostics)',
  })
end

---Configure and start the enabled servers.
---@return table result { enabled = string[], missing = string[], disabled = string[] }
function M.setup()
  M.attach_enhancements()

  local result = { enabled = {}, missing = {}, disabled = {} }

  if type(vim.lsp.config) ~= 'function' or type(vim.lsp.enable) ~= 'function' then
    notify('DSH Studio: this build needs Neovim 0.11+ (vim.lsp.config / vim.lsp.enable)', 'error')
    return result
  end

  M.configure()

  local missing = {}
  for _, name in ipairs(SERVER_ORDER) do
    local spec = SERVERS[name]
    local enabled = cfg_get('lsp.' .. name, true) ~= false
    if not enabled then
      result.disabled[#result.disabled + 1] = name
    elseif M.which(spec.binary) then
      result.enabled[#result.enabled + 1] = name
    else
      result.missing[#result.missing + 1] = name
      missing[#missing + 1] = name
    end
  end

  if #result.enabled > 0 then
    local called, err = pcall(vim.lsp.enable, result.enabled)
    if not called then
      notify(('DSH Studio: vim.lsp.enable failed: %s'):format(tostring(err)), 'error')
      result.enabled = {}
    end
  end

  -- One consolidated, once-per-session hint instead of one popup per server.
  if #missing > 0 and not summary_shown then
    summary_shown = true
    local lines = { 'DSH Studio: language servers not found on PATH:' }
    for _, name in ipairs(missing) do
      notified[name] = true
      lines[#lines + 1] = ('  [%s] %s'):format(name, M.install_hint(name))
    end
    lines[#lines + 1] = '  Or use `:Mason` (mason.nvim) to install and manage them.'
    notify(table.concat(lines, '\n'), 'warn')
  end

  return result
end

---Expose the catalogue for docs/UI (read-only by convention).
M.servers = SERVERS

return M
