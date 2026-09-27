-- Module auto-registration for DSH Studio.
--
-- Loaded by lazyprepend'ing this directory's parent onto the runtimepath; doing
-- the registration here (rather than in a plugin manager spec) keeps the
-- distribution usable when the config is copied in by hand and lazy.nvim has
-- never been bootstrapped.

local function safe_require(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

local session = safe_require('dshstudio.core.session')
local headless = safe_require('dshstudio.core.headless')
local auth = safe_require('dshstudio.core.auth')
local analysis = safe_require('dshstudio.project.analysis')
local sidebar = safe_require('dshstudio.ui.sidebar')
local outline = safe_require('dshstudio.ui.outline')
local project_tree = safe_require('dshstudio.ui.project_tree')

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'DSH Studio' })
end

---Define a command only when the backing module actually loaded.
local function define(name, fn, opts)
  opts = opts or {}
  opts.desc = opts.desc or name
  local ok, err = pcall(vim.api.nvim_create_user_command, name, fn, opts)
  if not ok then
    vim.schedule(function()
      notify(('could not register :%s (%s)'):format(name, tostring(err)), vim.log.levels.WARN)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Panel and session
-- ---------------------------------------------------------------------------

if sidebar then
  define('DshToggle', function() sidebar.toggle() end, { desc = 'Toggle the DeepSeek panel' })  define('DshAsk', function(cmd)
    sidebar.ask(cmd.args ~= '' and cmd.args or nil)
  end, { nargs = '*', desc = 'Open the panel and prefill a question' })
  define('DshAskSelection', function() sidebar.ask_selection() end,
    { range = true, desc = 'Ask about the selected lines' })
  define('DshModel', function() sidebar.pick_model() end, { desc = 'Choose the model' })
  define('DshEffort', function() sidebar.pick_effort() end, { desc = 'Choose the reasoning effort' })
  define('DshInsert', function() sidebar.insert_last_reply() end,
    { desc = 'Insert the last reply at the cursor' })
  define('DshCopy', function() sidebar.copy_last_reply() end,
    { desc = 'Copy the last reply to the clipboard' })
end

if session then
  define('DshApprove', function(cmd)
    if cmd.args ~= '' then
      local mode = cmd.args:lower()
      if session.set_approval_mode(mode) then
        notify('file-change approval: ' .. mode, vim.log.levels.INFO)
      else
        notify('usage: :DshApprove [ask|always|never]', vim.log.levels.WARN)
      end
    else
      session.pick_approval()
    end
  end, { nargs = '?', desc = 'Control whether the agent may edit files without asking' })

  define('DshWorkspace', function(cmd)
    if cmd.args ~= '' then
      session.set_workspace(cmd.args)
    else
      session.pick_workspace()
    end
  end, { nargs = '?', complete = 'dir', desc = 'Choose the directory the agent works in' })

  define('DshWorkspaceHere', function()
    -- Use the current file's project root, which is what a user means by "this
    -- project" when a file is open.
    local name = vim.api.nvim_buf_get_name(0)
    local start = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
    session.set_workspace(session.detect_workspace_root(start))
  end, { desc = 'Use the current file\'s project as the workspace' })

  define('DshNewSession', function()
    if sidebar then sidebar.new_session() else session.close_session(function() end) end
  end, { desc = 'Start a new harness session' })
  define('DshClear', function()
    session.clear()
    if sidebar then sidebar.schedule_render() end
  end, { desc = 'Clear the conversation transcript' })
  define('DshCancel', function()
    session.cancel()
    notify('cancellation requested', vim.log.levels.INFO)
  end, { desc = 'Cancel the running turn' })
  define('DshStatus', function()
    local st = session.agent_status()
    local lines = {
      '# DSH Studio status',
      '',
      ('- agent found: %s'):format(tostring(st.found)),
      ('- command: %s'):format(tostring(st.command)),
      ('- discovered via: %s'):format(tostring(st.discovered_by)),
      ('- connected: %s'):format(tostring(st.connected)),
      ('- session: %s'):format(tostring(st.session_id)),
      ('- cwd: %s'):format(tostring(st.cwd)),
      ('- model: %s'):format(session.model_label()),
      ('- reasoning effort: %s'):format(tostring((session.config_option('reasoning_effort') or {}).currentValue)),
      ('- busy: %s'):format(tostring(st.busy)),
    }
    local effort = session.config_option('reasoning_effort')
    if effort then lines[#lines] = ('- reasoning effort: %s'):format(tostring(effort.currentValue)) end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_open_win(buf, true, {
      relative = 'editor', width = math.min(80, vim.o.columns - 4),
      height = #lines + 1, row = 2, col = 4, style = 'minimal', border = 'rounded', title = ' DSH Studio ',
    })
    vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
  end, { desc = 'Show harness/session status' })
  define('DshSessions', function()
    session.list_sessions(function(sessions, err)
      if not sessions then
        notify('could not list sessions: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      if #sessions == 0 then
        notify('no persisted sessions found', vim.log.levels.INFO)
        return
      end
      vim.ui.select(sessions, {
        prompt = 'Resume a session',
        format_item = function(item)
          return ('%s  (%s)'):format(item.sessionId, item.cwd or '?')
        end,
      }, function(choice)
        if not choice then return end
        session.start_session({ session_id = choice.sessionId, cwd = choice.cwd }, function(ok, _sid, err2)
          if ok then
            notify('resumed ' .. choice.sessionId, vim.log.levels.INFO)
          else
            notify('resume failed: ' .. tostring(err2), vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  end, { desc = 'List and resume persisted sessions' })
end

-- ---------------------------------------------------------------------------
-- Providers and API keys
-- ---------------------------------------------------------------------------

if auth then
  define('DshAuth', function(cmd)
    auth.manage(cmd.args ~= '' and cmd.args or nil)
  end, { nargs = '?', desc = 'Manage model providers and API keys' })
  define('DshProviders', function()
    local providers = auth.providers()
    if #providers == 0 then
      notify('no providers advertised yet — open the panel once (<leader>dd) so the '
        .. 'agent can report its models', vim.log.levels.WARN)
      return
    end
    vim.ui.select(providers, {
      prompt = 'Provider (pick one to configure its API key)',
      format_item = function(p)
        return ('%s  [%s]  key: %s  ·  %d model%s'):format(
          p.label or p.provider, p.provider,
          p.key_set and (p.key_source or 'set') or 'NOT SET',
          #p.models, #p.models == 1 and '' or 's')
      end,
    }, function(choice)
      if not choice then return end
      auth.manage(choice.provider)
    end)
  end, { desc = 'List model providers and their key status' })
end

if session then
  define('DshModel', function()
    if sidebar then sidebar.pick_model() else session.pick_model() end
  end, { desc = 'Choose the model' })
  define('DshEffort', function()
    if sidebar and sidebar.pick_effort then sidebar.pick_effort() end
  end, { desc = 'Choose the reasoning effort' })
end

-- ---------------------------------------------------------------------------
-- Project analysis
-- ---------------------------------------------------------------------------

if analysis then
  define('DshAnalyze', function(cmd)
    local use_ai = cmd.bang
    analysis.run({
      root = cmd.args ~= '' and cmd.args or nil,
      use_ai = use_ai,
    })
  end, {
    nargs = '?', bang = true,
    desc = 'Analyze the project (add ! for AI architecture notes)',
  })
  define('DshAnalyzeMenu', function() analysis.menu() end, { desc = 'Project analysis menu' })
  define('DshReport', function()
    local cached = analysis.cached and analysis.cached() or nil
    if not cached or not cached.report_path then
      notify('no report yet — run :DshAnalyze first', vim.log.levels.WARN)
      return
    end
    analysis.open_report(cached.report_path)
  end, { desc = 'Open the last analysis report' })
  define('DshAnalyzeFile', function()
    -- `run` takes root/use_ai/silent; the current-file scope lives in the menu
    -- (it needs an interactive choice about AI notes), so delegate there.
    analysis.menu()
  end, { desc = 'Analyze the current file (via the analysis menu)' })
end

-- ---------------------------------------------------------------------------
-- Outline / symbols
-- ---------------------------------------------------------------------------

if outline then
  define('DshOutline', function() outline.toggle() end, { desc = 'Toggle the symbol outline' })
  define('DshSymbols', function() outline.pick() end, { desc = 'Pick a symbol in this file' })
  define('DshProjectSymbols', function() outline.project_symbols() end,
    { desc = 'Pick a symbol across the project' })
end

if project_tree then
  define('DshProjectTree', function() project_tree.toggle() end,
    { desc = 'Toggle the project symbol tree' })
  define('DshProjectTreePick', function() project_tree.pick() end,
    { desc = 'Fuzzy-pick a symbol from the project index' })
  define('DshProjectTreeRefresh', function()
    if project_tree.is_open() then
      project_tree.refresh(true)
    else
      project_tree.open_panel()
    end
  end, { desc = 'Re-index the project symbol tree' })
end

-- ---------------------------------------------------------------------------
-- Diagnostics and self-check
-- ---------------------------------------------------------------------------

define('DshWelcome', function()
  local ok, welcome = pcall(require, 'dshstudio.ui.welcome')
  if not ok then
    notify('welcome module unavailable: ' .. tostring(welcome), vim.log.levels.ERROR)
    return
  end
  welcome.show()
end, { desc = 'Show the quick-reference panel (commands and keys)' })

define('DshCheck', function()
  local ok, doctor = pcall(require, 'dshstudio.core.doctor')
  if not ok then
    notify('doctor module unavailable: ' .. tostring(doctor), vim.log.levels.ERROR)
    return
  end
  doctor.run()
end, { desc = 'Check the DeepSeek integration layer by layer' })

define('DshHealth', function()
  local report = {}
  local function add(line) table.insert(report, line) end
  add('# DSH Studio health check')
  add('')
  add(('Neovim: %s'):format(vim.version and tostring(vim.version()) or 'unknown'))
  add(('Config dir: %s'):format(vim.fn.stdpath('config')))
  add(('Data dir: %s'):format(vim.fn.stdpath('data')))
  local argv, how = nil, nil
  if session and session.resolve_agent_command then
    argv, how = session.resolve_agent_command()
  elseif headless then
    argv, how = headless.resolve_argv('headless')
  end
  add(('Harness CLI: %s (via %s)'):format(argv and table.concat(argv, ' ') or 'NOT FOUND', tostring(how)))
  add('')
  add('## Model providers and API keys')
  if auth and auth.status_lines then
    local ok_auth, lines = pcall(auth.status_lines)
    if ok_auth and type(lines) == 'table' then
      for _, line in ipairs(lines) do add(line) end
    else
      add('- auth module reported an error')
    end
    add('- configure with :DshAuth (model selection: :DshModel)')
  else
    add('- auth module unavailable')
  end
  add('')
  add('## Language servers')
  local ok_lsp, lsp = pcall(require, 'dshstudio.lsp')
  if ok_lsp and lsp.server_status then
    local ok2, status = pcall(lsp.server_status)
    if ok2 then
      for name, info in pairs(status) do
        add(('- %s: found=%s enabled=%s'):format(name, tostring(info.found), tostring(info.enabled)))
      end
    end
  else
    add('- lsp module unavailable')
  end
  add('')
  add('## Treesitter parsers')
  local ok_ts, ts = pcall(require, 'dshstudio.treesitter')
  if ok_ts and ts.ensure_languages then
    local ok3, langs = pcall(ts.ensure_languages)
    if ok3 then
      for _, lang in ipairs(langs) do
        local has = ts.has_parser and ts.has_parser(lang) or false
        add(('- %s: %s'):format(lang, has and 'ok' or 'missing'))
      end
    end
  else
    add('- treesitter module unavailable')
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, report)
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = math.min(96, vim.o.columns - 4),
    height = math.min(#report + 1, vim.o.lines - 6), row = 1, col = 2,
    style = 'minimal', border = 'rounded', title = ' DSH Studio health ',
  })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
end, { desc = 'Report environment and feature status' })

define('DshSelfTest', function()
  local ok_probe, probe = pcall(require, 'dshstudio.tests.probe')
  if not ok_probe then
    notify('self-test module missing: ' .. tostring(probe), vim.log.levels.ERROR)
    return
  end
  probe.run_all()
end, { desc = 'Run offline protocol self-tests' })

define('DshPing', function()
  if not headless then
    notify('headless module unavailable', vim.log.levels.ERROR)
    return
  end
  headless.self_check(function(ok, text, err)
    if ok then
      notify('harness answered: ' .. vim.trim(text or ''), vim.log.levels.INFO)
    else
      notify('harness check failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end, { desc = 'Send a one-shot ping through the harness' })
