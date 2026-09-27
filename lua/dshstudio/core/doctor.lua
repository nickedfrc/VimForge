-- dshstudio/core/doctor.lua
--
-- Layered self-diagnosis for the DeepSeek integration.
--
-- `:DshHealth` answers "what is installed"; this answers "what actually works",
-- by exercising each layer in order and stopping at the first one that fails:
--
--   1. CLI discovery      can the harness launcher be found?
--   2. Spawn              does the process start and stay up?
--   3. ACP handshake      does `initialize` return a protocol version?
--   4. Session            does `session/new` return a session id?
--   5. Model catalogue    which providers/models are advertised?
--   6. Credentials        is a key present for the selected provider?
--   7. Round trip         does a real prompt come back with an answer?
--
-- The value is the last step that succeeded: a 401 at step 7 means everything up
-- to the network is fine, while a failure at step 2 means the CLI itself is the
-- problem. Each result carries the exact command to fix it.

local M = {}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

local S = {
  running = false,
  lines = {},
  results = {},
}

local function line(text) S.lines[#S.lines + 1] = text or '' end

local function result(step, ok, detail)
  S.results[#S.results + 1] = { step = step, ok = ok, detail = detail }
  local mark = ok and 'PASS' or (ok == nil and 'SKIP' or 'FAIL')
  line(('  [%s] %-22s %s'):format(mark, step, detail or ''))
end

---Report the buffer for a finished run.
---@param title string
function M.render(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, S.lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  local width = math.min(104, vim.o.columns - 4)
  local height = math.min(#S.lines + 1, vim.o.lines - 6)
  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = 1,
    col = 2,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. (title or 'DSH doctor') .. ' ',
  })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
  vim.keymap.set('n', 'r', function()
    pcall(vim.api.nvim_win_close, 0, true)
    M.run()
  end, { buffer = buf, silent = true, desc = 'Run again' })
end

-- ---------------------------------------------------------------------------
-- Steps
-- ---------------------------------------------------------------------------

local function step_discovery()
  local session = require('dshstudio.core.session')
  local argv, how = session.resolve_agent_command()
  if not argv then
    result('1. CLI discovery', false, 'not found (' .. tostring(how) .. ')')
    line('')
    line('  Fix: npm install -g @deepseek-ai/dsh')
    line('  Or point the editor at it:')
    line("      vim.g.dshstudio = { agent_command = { 'dsh' } }")
    line('      (or set DSHSTUDIO_DSH_BIN to the launcher path)')
    return nil
  end
  result('1. CLI discovery', true, table.concat(argv, ' ') .. '  (via ' .. tostring(how) .. ')')
  return argv
end

local function step_spawn(argv, done)
  local acp = require('dshstudio.core.acp')
  local client = acp.new({
    command = argv,
    cwd = vim.fn.getcwd(),
    timeout_ms = 20000,
  })

  local settled = false
  local function finish(ok, detail, keep)
    if settled then return end
    settled = true
    result('2. Spawn', ok, detail)
    if not ok then
      line('')
      line('  The harness process did not start. Things to check:')
      line('    * Node.js 18+ is on PATH:  node --version')
      line('    * the CLI runs by itself:  dsh --version')
      if client:stderr_summary() ~= '' then
        line('    * stderr said: ' .. client:stderr_summary())
      end
    end
    done(ok and client or nil)
  end

  local ok, err = client:start(function(code)
    vim.schedule(function()
      finish(false, ('process exited early (code %s)%s'):format(
        tostring(code),
        client:stderr_summary() ~= '' and (' — ' .. client:stderr_summary()) or ''))
    end)
  end)
  if not ok then
    finish(false, err or 'spawn failed')
    return
  end
  -- The process is up if it is still alive a moment later.
  vim.defer_fn(function()
    if client:is_alive() then
      finish(true, 'started and still running')
    else
      finish(false, 'exited immediately' ..
        (client:stderr_summary() ~= '' and (' — ' .. client:stderr_summary()) or ''))
    end
  end, 900)
end

local function step_handshake(client, done)
  client:initialize(nil, function(ok, res, err)
    if not ok then
      result('3. ACP handshake', false, err or 'initialize failed')
      line('')
      line('  The process runs but does not speak ACP. Is this the official CLI?')
      line('  Check: dsh --profile acp --help')
      done(nil)
      return
    end
    local info = (res and res.agentInfo) or {}
    result('3. ACP handshake', true, ('protocol v%s, agent %s %s'):format(
      tostring(res.protocolVersion), tostring(info.name or '?'), tostring(info.version or '')))
    S.caps = res.agentCapabilities or {}
    done(client)
  end)
end

local function step_session(client, done)
  client:request('session/new', { cwd = vim.fn.getcwd(), mcpServers = {} }, function(msg)
    if msg.error then
      result('4. Session', false, msg.error.message or 'session/new failed')
      done(nil)
      return
    end
    local id = msg.result and msg.result.sessionId
    S.options = (msg.result and msg.result.configOptions) or {}
    local models, providers = 0, {}
    for _, opt in ipairs(S.options) do
      if opt.id == 'model' then
        for _, entry in ipairs(opt.options or {}) do
          if entry.options then
            table.insert(providers, entry.group or entry.name or '?')
            models = models + #entry.options
          else
            models = models + 1
          end
        end
      end
    end
    result('4. Session', true, ('id %s, %d option(s)'):format(
      tostring(id):sub(1, 18), #S.options))

    if #providers > 0 then
      result('5. Model catalogue', true, ('%d provider(s), %d model(s): %s'):format(
        #providers, models, table.concat(providers, ', ')))
    else
      result('5. Model catalogue', nil, 'no providers advertised')
      line('')
      line('  The agent answered but lists no models. Usual cause: no provider is')
      line('  configured yet. Add one in $DSH_HOME/settings.yaml, or run `dsh` once')
      line('  in a terminal to configure a provider interactively.')
    end
    done(id)
  end, { timeout_ms = 30000 })
end

local function step_credentials()
  local ok, auth = pcall(require, 'dshstudio.core.auth')
  if not ok or not auth.providers then
    result('6. Credentials', nil, 'auth module unavailable')
    return
  end
  local providers = auth.providers()
  if #providers == 0 then
    result('6. Credentials', nil, 'no providers to check')
    return
  end
  local missing = {}
  for _, p in ipairs(providers) do
    if not p.key_set then table.insert(missing, p.provider) end
  end
  if #missing == 0 then
    local names = {}
    for _, p in ipairs(providers) do
      table.insert(names, ('%s=%s'):format(p.provider, p.key_source or 'set'))
    end
    result('6. Credentials', true, table.concat(names, ', '))
  else
    result('6. Credentials', nil, ('no key for: %s'):format(table.concat(missing, ', ')))
    line('')
    line('  A missing key is not fatal — another provider may be signed in. If the')
    line('  prompt below fails with 401, set the key with :DshAuth.')
  end
end

local function step_roundtrip(client, session_id, done)
  if not session_id then
    result('7. Round trip', nil, 'skipped (no session)')
    done()
    return
  end
  local started = vim.uv.hrtime() / 1e6
  local chunks = {}
  local unsubscribe = nil
  do
    local session = require('dshstudio.core.session')
    unsubscribe = session.on('chunk', function(payload)
      if payload and payload.role == 'agent' then table.insert(chunks, payload.text or '') end
    end)
  end

  client:request('session/prompt', {
    sessionId = session_id,
    prompt = { { type = 'text', text = 'Reply with exactly: DSH_OK' } },
  }, function(msg)
    if unsubscribe then pcall(unsubscribe) end
    local elapsed = math.floor((vim.uv.hrtime() / 1e6) - started)
    if msg.error then
      local m = msg.error.message or 'prompt failed'
      result('7. Round trip', false, ('%dms — %s'):format(elapsed, m:sub(1, 90)))
      line('')
      local lower = m:lower()
      if lower:find('401') or lower:find('api key') or lower:find('unauthor') then
        line('  Diagnosis: the model provider rejected the request.')
        line('    -> :DshAuth  to set the key for that provider, then <leader>dm')
        line('    -> or run `dsh` in a terminal to sign in, then retry')
      elseif lower:find('timeout') or lower:find('timed out') then
        line('  Diagnosis: the request timed out. Check network access to the provider.')
      elseif lower:find('econnrefused') or lower:find('fetch failed') or lower:find('network') then
        line('  Diagnosis: no network route to the provider from this machine.')
      else
        line('  Full error: ' .. m)
      end
    else
      local text = table.concat(chunks):gsub('%s+$', '')
      local stop = msg.result and msg.result.stopReason or '?'
      result('7. Round trip', true, ('%dms, stopReason=%s, answer=%q'):format(
        elapsed, tostring(stop), text:sub(1, 40)))
      line('')
      line('  The harness answered, so the integration works end to end.')
    end
    done()
  end, { timeout_ms = 120000 })
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

---Run every step in order and render the report.
---@param opts { silent:boolean|nil }|nil
---@param on_done fun(results:table[])|nil
function M.run(opts, on_done)
  opts = opts or {}
  if S.running then
    util().notify('a doctor run is already in progress', vim.log.levels.WARN)
    return
  end
  S.running = true
  S.lines = {}
  S.results = {}
  S.caps, S.options = nil, nil

  line('# DeepSeek Harness — layered check')
  line('')
  line(('Working directory: %s'):format(vim.fn.getcwd()))
  line('')

  local function finish()
    S.running = false
    local passed, failed, skipped = 0, 0, 0
    for _, r in ipairs(S.results) do
      if r.ok == true then passed = passed + 1
      elseif r.ok == false then failed = failed + 1
      else skipped = skipped + 1 end
    end
    line('')
    line(('Summary: %d passed, %d failed, %d skipped'):format(passed, failed, skipped))
    if failed == 0 and passed >= 4 then
      line('')
      line('Everything that could be checked here works.')
    end
    S.lines[#S.lines + 1] = ''
    line('Press q to close, r to run again.')
    if not opts.silent then
      M.render('DSH check')
    end
    if on_done then on_done(S.results) end
  end

  local argv = step_discovery()
  if not argv then finish() return end

  step_spawn(argv, function(client)
    if not client then finish() return end
    step_handshake(client, function(handshaken)
      if not handshaken then finish() return end
      step_session(client, function(session_id)
        step_credentials()
        step_roundtrip(client, session_id, function()
          pcall(function() client:stop() end)
          finish()
        end)
      end)
    end)
  end)
end

---Machine-readable summary, for tests and scripts.
---@return table[]
function M.results()
  return S.results
end

---Human-readable one-line summary.
---@return string
function M.summary()
  if #S.results == 0 then return 'not run' end
  local last_ok, first_fail = nil, nil
  for _, r in ipairs(S.results) do
    if r.ok == true then last_ok = r.step end
    if r.ok == false and not first_fail then first_fail = r.step end
  end
  if not first_fail then return 'all checks passed (' .. tostring(last_ok or '-') .. ')' end
  return ('failed at %s'):format(first_fail)
end

return M
