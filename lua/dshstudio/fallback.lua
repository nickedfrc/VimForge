-- dshstudio/fallback.lua
--
-- Last-resort plugin loading for when the plugin manager cannot run.
--
-- The situation this covers: plugins are present on disk but no git metadata, so
-- lazy.nvim's lockfile step asserts inside `Git.info()` and aborts setup. That
-- happens with a tarball install, a vendored plugin directory, or any offline
-- bundle - exactly the cases where a user cannot simply run `:Lazy sync`.
--
-- What it does, and deliberately does not:
--   * prepends every plugin directory on disk to the runtime path
--   * sources each plugin's `plugin/**.lua`, so commands and keymaps exist
--   * reads `after/` directories through the runtime path like any plugin
--   * does NOT evaluate `opts`/`config` functions, so plugins run with their
--     defaults rather than this distribution's settings
--
-- Shipping the real configuration still requires the plugin manager; this keeps
-- the editor useful instead of half-empty in the meantime.

local M = {}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

---Directories that hold plugins: lazy's install root, plus the usual pack paths.
---@return string[]
function M.plugin_dirs()
  local dirs = {}
  local data = vim.fn.stdpath('data')
  local candidates = {
    data .. '/lazy',
    data .. '/site/pack/core/opt',
    data .. '/site/pack/core/start',
  }
  for _, root in ipairs(candidates) do
    if vim.fn.isdirectory(root) == 1 then
      table.insert(dirs, root)
    end
  end
  return dirs
end

---Add every plugin on disk to the runtime path and source its plugin files.
---@return integer loaded  number of plugin directories added
function M.load_plugins()
  local added = 0
  for _, root in ipairs(M.plugin_dirs()) do
    local entries = vim.fn.readdir(root)
    if type(entries) == 'table' then
      table.sort(entries)
      for _, name in ipairs(entries) do
        local dir = root .. '/' .. name
        -- Parenthesised: `a and b or c and d` binds as `(a and b) or (c and d)`,
        -- which made a non-existent directory look like a plugin.
        local looks_like_plugin = vim.fn.isdirectory(dir) == 1
          and (vim.fn.isdirectory(dir .. '/lua') == 1
            or vim.fn.filereadable(dir .. '/init.lua') == 1
            or vim.fn.isdirectory(dir .. '/plugin') == 1
            or vim.fn.isdirectory(dir .. '/colors') == 1)
        if looks_like_plugin then
          vim.opt.rtp:append(dir)
          added = added + 1
        end
      end
    end
  end

  if added == 0 then return 0 end

  -- Now that the runtime path contains the plugins, load their plugin scripts.
  -- This mirrors what Neovim does for packages at startup.
  local loaded = 0
  for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
    local plugin_dir = dir .. '/plugin'
    if vim.fn.isdirectory(plugin_dir) == 1 then
      for _, file in ipairs(vim.fn.glob(plugin_dir .. '/**/*.lua', false, true)) do
        local ok = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(file))
        if ok then loaded = loaded + 1 end
      end
      -- Vimscript plugin files still exist in some plugins.
      for _, file in ipairs(vim.fn.glob(plugin_dir .. '/**/*.vim', false, true)) do
        local ok = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(file))
        if ok then loaded = loaded + 1 end
      end
    end
  end

  util().notify(('plugins loaded without the plugin manager: %d directories, %d plugin scripts'
    .. '\nPer-plugin settings from this distribution are not applied in this mode.'):format(
    added, loaded), vim.log.levels.WARN)
  return added
end

---Whether a plugin directory exists on disk but was not put on the runtime path.
---@param name string
---@return boolean
function M.present(name)
  for _, root in ipairs(M.plugin_dirs()) do
    if vim.fn.isdirectory(root .. '/' .. name) == 1 then return true end
  end
  return false
end

---Status summary for :DshHealth.
---@return string[]
function M.status_lines()
  local lines = {}
  local dirs = M.plugin_dirs()
  if #dirs == 0 then
    lines[#lines + 1] = '  no plugin directory found'
    return lines
  end
  for _, root in ipairs(dirs) do
    local entries = vim.fn.readdir(root)
    local count = type(entries) == 'table' and #entries or 0
    lines[#lines + 1] = ('  %s: %d entries'):format(root, count)
  end
  return lines
end

return M
