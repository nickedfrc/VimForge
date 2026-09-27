-- dshstudio/ui/welcome.lua
--
-- A startup panel that makes the editor discoverable.
--
-- Why this exists: every DeepSeek feature is reachable through `<leader>` maps
-- and `:Dsh*` commands, and nothing on screen says so. A new user opening the
-- editor sees an empty buffer and has no way to learn that a panel, a model
-- picker or a project report exist. This panel states them once, on first launch,
-- and then stays out of the way.
--
-- It is deliberately dependency-free: it works before any plugin has been
-- installed, which is exactly when the editor looks emptiest.

local M = {}

local S = { buf = nil, win = nil }

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

---Whether the welcome panel has already been shown in this profile.
---@return boolean
function M.seen()
  local flag = vim.fn.stdpath('state') .. '/dshstudio-welcome'
  return vim.fn.filereadable(flag) == 1
end

---Record that the panel has been shown, so it appears only once.
function M.mark_seen()
  pcall(vim.fn.writefile, { 'shown ' .. os.date('%Y-%m-%d %H:%M:%S') },
    vim.fn.stdpath('state') .. '/dshstudio-welcome')
end

---Ask the harness CLI whether it can be found at all, so the panel can say
---something accurate instead of assuming it is installed.
---@return boolean found
---@return string|nil command
function M.harness_status()
  local ok, session = pcall(require, 'dshstudio.core.session')
  if ok and session.resolve_agent_command then
    local argv, how = session.resolve_agent_command()
    if argv then return true, table.concat(argv, ' ') end
    return false, how
  end
  return vim.fn.executable('dsh') == 1, nil
end

---Render the welcome panel into a scratch buffer.
function M.show()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_set_current_win(S.win)
    return
  end

  local found, how = M.harness_status()
  local lines = {
    '  VimForge — Vim editor with DeepSeek Harness built in',
    '',
    '  Two ways to reach everything: the keys below, or the :Dsh… commands',
    '  (type :Dsh and press <Tab> to see them all).',
    '',
    '  ── DeepSeek panel ─────────────────────────────────────────────────',
    '    <leader>dd      open / close the panel       :DshToggle',
    '    <leader>da      ask about the selection      :DshAskSelection',
    '    <leader>dm      choose the model             :DshModel',
    '    <leader>dk      set an API key               :DshAuth',
    '    <leader>dH      what is installed / missing  :DshHealth',
    '',
    '  ── Code navigation ────────────────────────────────────────────────',
    '    <leader>o       symbol outline (subroutines, functions, types)',
    '    <leader>ot      project symbol tree          :DshProjectTree',
    '    gd  gD  gi  gr  go to definition / declaration / impl / refs',
    '    K               hover documentation',
    '    <leader>fs      symbols in this file    <leader>ff  find files',
    '',
    '  ── Project analysis (deepwiki style) ──────────────────────────────',
    '    <leader>dp      analysis menu',
    '    :DshAnalyze     offline report: languages, directory tree, modules,',
    '                    a subroutine/function table, dependency edges, call',
    '                    graph, entry points, largest files',
    '    :DshAnalyze!    the same report plus AI architecture notes',
    '    :DshReport      reopen the last report',
    '    :DshProjectTree project-wide symbol tree',
    '',
    '  ── Workspace (what the agent is allowed to touch) ─────────────────',
    '    :DshWorkspace        pick the project directory',
    '    :DshWorkspaceHere    use the current file\'s project',
    '    Starting the editor on a directory does this automatically.',
    '',
    '  ── Housekeeping ───────────────────────────────────────────────────',
    '    :DshCheck       test the harness layer by layer (start here!)',
    '    :DshSelfTest    18 offline tests (no network needed)',
    '    :DshHealth      what is installed / what is missing',
    '    :Lazy sync      install / update the plugin set',
    '    q or <Esc>      close this panel',
    '',
  }

  if found then
    table.insert(lines, ('  Harness CLI: found  (%s)'):format(how or 'dsh'))
    table.insert(lines, '  Set a key with <leader>dk, then pick a model with <leader>dm.')
  else
    table.insert(lines, '  Harness CLI: NOT FOUND — the AI features need it:')
    table.insert(lines, '      npm install -g @deepseek-ai/dsh')
    table.insert(lines, '  Everything else above (outline, navigation, analysis report)')
    table.insert(lines, '  works without it.')
  end
  table.insert(lines, '')

  local buf = vim.api.nvim_create_buf(false, true)
  S.buf = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'dshstudio_welcome'

  local width = math.min(92, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  S.win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' DSH Studio ',
  })

  local ns = vim.api.nvim_create_namespace('dshstudio.welcome')
  vim.api.nvim_buf_add_highlight(buf, ns, 'Title', 0, 0, -1)
  for i, line in ipairs(lines) do
    if line:match('^%s+──') then
      vim.api.nvim_buf_add_highlight(buf, ns, 'Comment', i - 1, 0, -1)
    elseif line:match('^%s+<leader>') or line:match('^%s+:Dsh') then
      vim.api.nvim_buf_add_highlight(buf, ns, 'Special', i - 1, 0, -1)
    end
  end

  local function close()
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      pcall(vim.api.nvim_win_close, S.win, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>', '<CR>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, silent = true, nowait = true })
  end
  vim.keymap.set('n', '?', function()
    close()
    vim.cmd('DshToggle')
  end, { buffer = buf, silent = true, desc = 'Open the DeepSeek panel' })

  M.mark_seen()
end

---Show the panel when the editor was opened with no file, and only once.
---Set `vim.g.dshstudio_welcome = false` to suppress it entirely.
function M.maybe_show()
  if vim.g.dshstudio_welcome == false then return end
  -- Respect an explicit file argument: do not cover the user's work.
  local argc = vim.fn.argc()
  local has_file = argc > 0 and vim.fn.argv(0) ~= ''
  if has_file then return end
  if M.seen() then return end
  -- Wait until the UI exists, so the floating window is positioned correctly.
  vim.defer_fn(function()
    local ok, err = pcall(M.show)
    if not ok then
      util().notify('welcome panel failed: ' .. tostring(err), vim.log.levels.DEBUG)
    end
  end, 120)
end

return M
