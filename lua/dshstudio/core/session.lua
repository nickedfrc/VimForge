-- dshstudio/core/session.lua
--
-- High-level conversation session on top of the ACP client.
--
-- Responsibilities:
--   * own the agent lifecycle (detect `dsh`, spawn, handshake, restart)
--   * create/resume sessions and keep the negotiated config options
--   * stream `session/update` notifications into a transcript the UI renders
--   * answer agent->client requests (permissions, fs read/write)
--   * expose prompt/cancel/close plus token accounting
--
-- Verified against DeepSeek Harness' `acp` profile:
--   initialize        -> protocolVersion 1, agentCapabilities.sessionCapabilities
--   session/new       -> sessionId + configOptions (model, reasoning_effort)
--   session/prompt    -> stopReason
--   session/update    -> agent_message_chunk | agent_thought_chunk | tool_call
--                        | tool_call_update | usage_update | available_commands_update
--   session/set_config_option { sessionId, configId, value }  (value is a
--                        JSON-encoded string for `model`, a plain string for
--                        `reasoning_effort`; arrays are rejected by the agent)

local M = {}

local uv = vim.uv or vim.loop

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return {
    notify = function(msg, level) vim.notify(msg, level, { title = 'DSH Studio' }) end,
    is_windows = function() return package.config:sub(1, 1) == '\\' end,
    join = function(...) return table.concat({ ... }, '/') end,
    read_file = function(path)
      local fd = io.open(path, 'r')
      if not fd then return nil end
      local data = fd:read('*a')
      fd:close()
      return data
    end,
  }
end

local function config()
  local ok, mod = pcall(require, 'dshstudio.config')
  if ok and mod.get then return mod end
  return { get = function() return nil end }
end

local state = {
  client = nil,
  session_id = nil,
  connected = false,
  connecting = false,
  cwd = nil,
  config_options = {},
  messages = {},        -- transcript: { role = 'user'|'agent'|'thought'|'tool'|'system', text, id, meta }
  active_message = nil, -- index of the streaming agent message
  active_thought = nil,
  last_message_id = nil, -- messageId of the message being streamed
  last_thought_id = nil,
  usage = { used = 0, size = 0 },
  busy = false,
  last_error = nil,
  listeners = {},       -- event name -> list of callbacks
  stop_reason = nil,
  pending_tools = {},   -- toolCallId -> message index
  tool_order = {},
  session_list = {},
}

M.state = state

-- ---------------------------------------------------------------------------
-- Event plumbing
-- ---------------------------------------------------------------------------

function M.on(event, fn)
  state.listeners[event] = state.listeners[event] or {}
  table.insert(state.listeners[event], fn)
  return function()
    local list = state.listeners[event]
    if not list then return end
    for i, f in ipairs(list) do
      if f == fn then
        table.remove(list, i)
        break
      end
    end
  end
end

function M.emit(event, payload)
  for _, fn in ipairs(state.listeners[event] or {}) do
    local ok, err = pcall(fn, payload)
    if not ok then
      vim.schedule(function()
        util().notify('listener error on ' .. event .. ': ' .. tostring(err), vim.log.levels.DEBUG)
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Transcript helpers
-- ---------------------------------------------------------------------------

function M.add_message(role, text, meta)
  table.insert(state.messages, { role = role, text = text or '', meta = meta or {} })
  M.emit('messages_changed', state.messages)
  return #state.messages
end

function M.clear()
  state.messages = {}
  state.active_message = nil
  state.active_thought = nil
  state.last_message_id = nil
  state.last_thought_id = nil
  state.pending_tools = {}
  state.tool_order = {}
  state.stop_reason = nil
  M.emit('messages_changed', state.messages)
end

function M.get_messages()
  return state.messages
end

function M.is_busy()
  return state.busy
end

function M.is_connected()
  return state.connected
end

function M.get_session_id()
  return state.session_id
end

function M.get_usage()
  return state.usage
end

function M.get_config_options()
  return state.config_options
end

---Find the negotiated option entry by id.
---@param id string
function M.config_option(id)
  for _, opt in ipairs(state.config_options or {}) do
    if opt.id == id then return opt end
  end
  return nil
end

---Flatten config options into a display list of { config_id, value, name, group }.
function M.model_choices()
  local choices = {}
  local opt = M.config_option('model')
  if not opt then return choices end
  for _, entry in ipairs(opt.options or {}) do
    -- Grouped shape: { group = 'deepseek-official', name = 'DeepSeek', options = {...} }
    if entry.options then
      for _, sub in ipairs(entry.options) do
        table.insert(choices, {
          config_id = 'model',
          group = entry.group or entry.name,
          name = sub.name or sub.value,
          value = sub.value,
          description = sub.description,
          current = (sub.value == opt.currentValue),
        })
      end
    else
      table.insert(choices, {
        config_id = 'model',
        group = entry.group,
        name = entry.name or entry.value,
        value = entry.value,
        description = entry.description,
        current = (entry.value == opt.currentValue),
      })
    end
  end
  return choices
end

function M.effort_choices()
  local choices = {}
  local opt = M.config_option('reasoning_effort')
  if not opt then return choices end
  for _, entry in ipairs(opt.options or {}) do
    table.insert(choices, {
      config_id = 'reasoning_effort',
      group = 'reasoning_effort',
      name = entry.name or entry.value,
      value = entry.value,
      description = entry.description,
      current = (entry.value == opt.currentValue),
    })
  end
  return choices
end

---Human readable label for the current model selection.
function M.model_label()
  local opt = M.config_option('model')
  if not opt or not opt.currentValue then return 'default' end
  for _, c in ipairs(M.model_choices()) do
    if c.value == opt.currentValue then return c.name end
  end
  return tostring(opt.currentValue)
end

-- ---------------------------------------------------------------------------
-- Agent discovery
-- ---------------------------------------------------------------------------

---Make an argv prefix directly spawnable.
---
---Two Windows-specific problems are handled here, both of which made the agent
---fail to start:
---   * `jobstart` cannot execute a `.cmd`/`.bat` shim; it exits with
---     "E903: Process failed to start". Such a command has to go through
---     `cmd.exe /c`.
---   * a bare `dsh` on PATH resolves to `dsh.CMD`, so the shim is replaced with
---     the real entry point run through `node` whenever one can be found.
---@param argv string[]
---@return string[] argv
---@return string|nil how  set when the command was adapted
function M.normalize_agent_command(argv)
  if type(argv) ~= 'table' or #argv == 0 then return argv, nil end

  if not util().is_windows() then return argv, nil end

  local head = argv[1]
  local note = nil

  -- A `dsh` found on PATH is the npm shim; prefer the script it wraps.
  if head:lower() == 'dsh' or head:lower() == 'dsh.cmd' or head:lower() == 'dsh.bat' then
    if vim.fn.executable('dsh') == 1 then
      local resolved = vim.fn.exepath('dsh')
      if resolved and resolved ~= '' then
        head = resolved
        note = 'resolved the dsh shim to ' .. resolved
      end
    end
  end

  -- Route a .cmd/.bat shim through cmd.exe.
  if head:lower():match('%.cmd$') or head:lower():match('%.bat$') then
    local rest = {}
    for i = 2, #argv do rest[#rest + 1] = argv[i] end
    local out = { 'cmd.exe', '/c', head }
    vim.list_extend(out, rest)
    return out, (note and (note .. '; ') or '') .. 'routed the .cmd shim through cmd.exe'
  end

  if head ~= argv[1] then
    local out = { head }
    for i = 2, #argv do out[#out + 1] = argv[i] end
    return out, note
  end
  return argv, nil
end

---Find the harness CLI's JavaScript entry point inside an npx checkout.
---
---Running `node <entry>` avoids the Windows `.cmd` shim entirely, so this is
---preferred over a PATH lookup when both exist.
---@return string|nil entry
function M.find_npx_entry()
  local home = os.getenv('HOME') or os.getenv('USERPROFILE')
  local candidates = {}
  local sep = util().is_windows() and '\\' or '/'
  if home then
    table.insert(candidates, home .. sep .. 'AppData' .. sep .. 'Local' .. sep .. 'npm-cache' .. sep .. '_npx')
    table.insert(candidates, home .. '/.npm/_npx')
    table.insert(candidates, home .. '/AppData/Local/npm-cache/_npx')
  end
  if os.getenv('LOCALAPPDATA') then
    table.insert(candidates, os.getenv('LOCALAPPDATA') .. '\\npm-cache\\_npx')
  end
  for _, base in ipairs(candidates) do
    local ok, entries = pcall(vim.fn.readdir, base)
    if ok and type(entries) == 'table' then
      for _, dir in ipairs(entries) do
        local bin = base .. '/' .. dir .. '/node_modules/@deepseek-ai/dsh/lib/bin.js'
        if vim.fn.filereadable(bin) == 1 then return bin end
      end
    end
  end
  return nil
end

---Locate the `dsh` CLI as an argv prefix.
---Order: explicit config -> DSHSTUDIO_DSH_BIN -> the npx checkout's entry script
---(most reliable on Windows) -> PATH `dsh` -> npx fallback.
---The result always goes through `normalize_agent_command`.
---
---`profile` is appended when given. The CLI requires it: launching without one
---exits immediately with "error: --profile <name> is required", which is what the
---interactive session and the one-shot path both need (`acp` and `headless`).
---@param profile string|nil  e.g. 'acp'
---@return string[]|nil argv
---@return string|nil how  human readable discovery note
function M.resolve_agent_command(profile)
  ---Append the profile flag to a resolved argv, unless the caller already set one.
  ---@param argv string[]
  ---@param note string|nil
  ---@return string[] argv
  ---@return string note
  local function with_profile(argv, note)
    local base = argv
    local suffix = note or ''
    if profile and profile ~= '' then
      local has_profile = false
      for _, part in ipairs(base) do
        if part == '--profile' then has_profile = true end
      end
      if not has_profile then
        base = vim.list_extend({}, base)
        table.insert(base, '--profile')
        table.insert(base, profile)
      end
      suffix = (suffix ~= '' and (suffix .. ', ') or '') .. 'profile=' .. profile
    end
    return base, suffix
  end

  local cfg = config().get and config().get('agent_command') or nil
  if type(cfg) == 'table' and #cfg > 0 then
    local argv, note = M.normalize_agent_command(cfg)
    return with_profile(argv, 'config' .. (note and (' (' .. note .. ')') or ''))
  elseif type(cfg) == 'string' and cfg ~= '' then
    local argv, note = M.normalize_agent_command({ cfg })
    return with_profile(argv, 'config' .. (note and (' (' .. note .. ')') or ''))
  end

  local env_bin = os.getenv('DSHSTUDIO_DSH_BIN')
  if env_bin and env_bin ~= '' then
    local argv, note = M.normalize_agent_command({ env_bin })
    return with_profile(argv, 'DSHSTUDIO_DSH_BIN' .. (note and (' (' .. note .. ')') or ''))
  end

  -- Preferred: the real entry script, run by node. Immune to the .cmd problem.
  local entry = M.find_npx_entry()
  if entry then
    local node = vim.fn.exepath('node')
    if node == '' then node = 'node' end
    return with_profile({ node, entry }, 'npx cache entry')
  end

  if vim.fn.executable('dsh') == 1 then
    local argv, note = M.normalize_agent_command({ 'dsh' })
    return with_profile(argv, 'PATH' .. (note and (' (' .. note .. ')') or ''))
  end

  if vim.fn.executable('npx') == 1 then
    local argv, note = M.normalize_agent_command({ 'npx', '-y', '@deepseek-ai/dsh' })
    return with_profile(argv, 'npx' .. (note and (' (' .. note .. ')') or ''))
  end
  return nil, 'not found'
end

---Describe the resolved agent command for the status view.
function M.agent_status()
  local argv, how = M.resolve_agent_command()
  return {
    found = argv ~= nil,
    command = argv and table.concat(argv, ' ') or nil,
    discovered_by = how,
    connected = state.connected,
    session_id = state.session_id,
    cwd = state.cwd,
    busy = state.busy,
  }
end

-- ---------------------------------------------------------------------------
-- Connection lifecycle
-- ---------------------------------------------------------------------------

local function make_client()
  -- 'acp' is the profile this client speaks; the CLI requires it and exits with
  -- "error: --profile <name> is required" without it.
  local argv = M.resolve_agent_command('acp')
  if not argv then
    return nil, 'Could not find the DeepSeek Harness CLI (`dsh`). Install it with '
      .. '`npm i -g @deepseek-ai/dsh`, or set `agent_command` in your DSH Studio config.'
  end

  -- Credentials are NOT injected here. The harness owns that problem: its
  -- credential store watches `$DSH_HOME/.credentials.yaml` and reloads on change,
  -- and the launch environment outranks the store. Passing keys in from the
  -- editor would add a second source of truth and mask a key the user set with
  -- the harness' own tooling. `core/auth.lua` writes to that store instead.
  local client = require('dshstudio.core.acp').new({
    command = vim.list_extend({}, argv),
    cwd = state.cwd,
    timeout_ms = 30000,
    log = function(level, msg)
      if level == 'error' or level == 'warn' then
        vim.schedule(function() util().notify('[dsh] ' .. msg, vim.log.levels.DEBUG) end)
      end
    end,
  })
  return client
end

---Register the agent->client callbacks the harness relies on.
---@param client DshAcpClient
local function wire_client(client)
  -- Permission requests: the agent blocks with no server-side timeout, so this
  -- must always answer promptly. DSH ships exactly two optionIds:
  -- "allow-once" (kind allow_once) and "reject-once" (kind reject_once).
  client:on_request('session/request_permission', function(params)
    local options = params.options or {}
    local mode = config().get and config().get('auto_approve') or 'ask'

    -- After a cancel the protocol requires answering with `cancelled` rather
    -- than a selection; anything but allow-once is treated as a rejection.
    if client:is_cancelled() or state.cancelled_turns then
      return { outcome = { outcome = 'cancelled' } }
    end

    local function pick(pattern)
      for _, o in ipairs(options) do
        local id = tostring(o.optionId or '')
        if id:match(pattern) or (o.kind and tostring(o.kind):match(pattern)) then return o end
      end
      return nil
    end

    local chosen
    if mode == 'always' then
      chosen = pick('allow')
    elseif mode == 'never' then
      chosen = pick('reject')
    end
    chosen = chosen or options[1]
    if not chosen then
      return { outcome = { outcome = 'cancelled' } }
    end
    -- Record the decision in the transcript so the user sees what was approved.
    vim.schedule(function()
      M.add_message('tool', ('permission: %s'):format(chosen.name or chosen.optionId or '?'), {
        tool_call_id = params.toolCallId,
        kind = 'permission',
      })
    end)
    return { outcome = { outcome = 'selected', optionId = chosen.optionId } }
  end)

  -- Filesystem access: the agent asks the client to read/write files.
  client:on_request('fs/read_text_file', function(params)
    local path = params.path
    if type(path) ~= 'string' then return nil, { code = -32602, message = 'path required' } end
    local data = util().read_file(path)
    if data == nil then
      return nil, { code = -32000, message = 'cannot read ' .. path }
    end
    local lines = vim.split(data, '\n')
    local line = tonumber(params.line) or 1
    local limit = tonumber(params.limit)
    if limit then
      local out = {}
      for i = line, math.min(#lines, line + limit - 1) do table.insert(out, lines[i]) end
      return { content = table.concat(out, '\n') }
    end
    return { content = data }
  end)

  client:on_request('fs/write_text_file', function(params)
    local path, content = params.path, params.content
    if type(path) ~= 'string' then return nil, { code = -32602, message = 'path required' } end
    local fh = io.open(path, 'w')
    if not fh then return nil, { code = -32000, message = 'cannot write ' .. path } end
    fh:write(content or '')
    fh:close()
    vim.schedule(function()
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent! edit!') end)
      end
    end)
    return {}
  end)

  -- Streaming updates.
  client:on_notification('session/update', function(update)
    M.handle_update(update)
  end)
end

---Fold one `session/update` payload into the transcript.
---@param update table
function M.handle_update(update)
  if type(update) ~= 'table' then return end
  local kind = update.sessionUpdate
  if kind == 'agent_message_chunk' then
    local text = update.content and update.content.text or ''
    if text ~= '' then
      -- The agent streams committed per-block chunks and reports a new
      -- `messageId` for each assistant message. Three rules keep the transcript
      -- readable, and the state machine is subtle enough to be worth stating:
      --   * a changed messageId starts a new message, otherwise consecutive
      --     answers merge into one bubble;
      --   * an unfinished reasoning block ends the bubble, so text that follows
      --     thinking does not grow the message that preceded it;
      --   * a chunk with no messageId continues the message being streamed
      --     unless one of the above applies.
      local mid = update.messageId
      local has_pending_thought = state.active_thought ~= nil
      local id_changed = mid ~= nil and state.last_message_id ~= nil
        and mid ~= state.last_message_id
      if state.active_message == nil or id_changed or has_pending_thought then
        state.active_message = M.add_message('agent', '', { message_id = mid })
      end
      if mid ~= nil then state.last_message_id = mid end
      state.active_thought = nil
      state.last_thought_id = nil
      local msg = state.messages[state.active_message]
      if msg then msg.text = msg.text .. text end
      M.emit('chunk', { role = 'agent', text = text })
      M.emit('messages_changed', state.messages)
    end
  elseif kind == 'agent_thought_chunk' then
    local text = update.content and update.content.text or ''
    if text ~= '' then
      local mid = update.messageId
      if state.active_thought == nil or (mid ~= nil and state.last_thought_id ~= nil and mid ~= state.last_thought_id) then
        state.active_thought = M.add_message('thought', '', { message_id = mid })
      end
      state.last_thought_id = mid or state.last_thought_id
      local msg = state.messages[state.active_thought]
      if msg then msg.text = msg.text .. text end
      M.emit('chunk', { role = 'thought', text = text })
      M.emit('messages_changed', state.messages)
    end
  elseif kind == 'user_message_chunk' then
    local text = update.content and update.content.text or ''
    if text ~= '' then M.emit('chunk', { role = 'user', text = text }) end
  elseif kind == 'tool_call' then
    state.active_message = nil
    state.active_thought = nil
    local id = update.toolCallId or ('tool-' .. tostring(#state.messages))
    local idx = state.pending_tools[id]
    if not idx then
      idx = M.add_message('tool', '', {
        tool_call_id = id,
        title = update.title,
        kind = update.kind,
        status = update.status or 'in_progress',
        raw_input = update.rawInput,
        content_parts = {},
        locations = update.locations,
      })
      state.pending_tools[id] = idx
      table.insert(state.tool_order, id)
    else
      local msg = state.messages[idx]
      if msg then
        msg.meta.title = update.title or msg.meta.title
        msg.meta.kind = update.kind or msg.meta.kind
        msg.meta.status = update.status or msg.meta.status
        msg.meta.raw_input = update.rawInput or msg.meta.raw_input
      end
    end
    M.emit('tool_event', update)
    M.emit('messages_changed', state.messages)
  elseif kind == 'tool_call_update' then
    local id = update.toolCallId
    local idx = id and state.pending_tools[id]
    if idx and state.messages[idx] then
      local msg = state.messages[idx]
      msg.meta.status = update.status or msg.meta.status
      msg.meta.title = update.title or msg.meta.title
      for _, part in ipairs(update.content or {}) do
        local inner = part.content or part
        local text = inner.text
        if text and text ~= '' then
          table.insert(msg.meta.content_parts, text)
          msg.text = table.concat(msg.meta.content_parts, '\n')
        end
      end
      if update.locations then msg.meta.locations = update.locations end
    end
    M.emit('tool_event', update)
    M.emit('messages_changed', state.messages)
  elseif kind == 'usage_update' then
    state.usage = { used = update.used or 0, size = update.size or 0 }
    M.emit('usage', state.usage)
  elseif kind == 'config_option_update' then
    -- The harness pushes the complete replacement option set when the model
    -- topology changes (e.g. a credential is added at runtime).
    if type(update.configOptions) == 'table' then
      state.config_options = update.configOptions
      M.emit('config', state.config_options)
    end
  elseif kind == 'available_commands_update' then
    state.available_commands = update.availableCommands or {}
    M.emit('commands', state.available_commands)
  elseif kind == 'plan' then
    M.emit('plan', update)
  else
    -- Unknown discriminators must never break the stream (forward compatibility).
    M.emit('unknown_update', update)
  end
end

---Connect (if needed) and run the handshake.
---@param on_done fun(ok:boolean, err:string|nil)
function M.ensure_connected(on_done)
  if state.connected and state.client and state.client:is_alive() then
    on_done(true, nil)
    return
  end
  if state.connecting then
    -- Queue behind the in-flight attempt instead of spawning a second agent.
    local wait = M.on('connected', function(ok, err) on_done(ok, err) end)
    return wait
  end

  state.connecting = true
  state.cwd = state.cwd or vim.fn.getcwd()

  local client, err = make_client()
  if not client then
    state.connecting = false
    state.last_error = err
    on_done(false, err)
    return
  end

  local ok, spawn_err = client:start(function(code)
    state.connected = false
    local was_busy = state.busy
    state.busy = false
    local reason = client:stderr_summary()
    vim.schedule(function()
      if code ~= 0 or was_busy then
        local msg = ('DeepSeek agent exited (%s)'):format(tostring(code))
        if reason ~= '' then msg = msg .. ': ' .. reason end
        util().notify(msg, code == 0 and vim.log.levels.WARN or vim.log.levels.ERROR)
        M.add_message('system', msg, { kind = 'error' })
      end
      M.emit('disconnected', code)
    end)
  end)
  if not ok then
    state.connecting = false
    state.last_error = spawn_err
    on_done(false, spawn_err)
    return
  end

  wire_client(client)
  state.client = client

  client:initialize(nil, function(init_ok, result, init_err)
    state.connecting = false
    if not init_ok then
      state.connected = false
      state.last_error = init_err
      client:stop()
      on_done(false, init_err)
      M.emit('connected', false, init_err)
      return
    end
    state.connected = true
    state.agent_info = result and result.agentInfo or {}
    state.auth_methods = (result and result.authMethods) or {}
    M.emit('connected', true, nil)
    on_done(true, nil)
  end)
end

---List persisted sessions known to the harness.
---@param on_done fun(sessions:table[]|nil, err:string|nil)
function M.list_sessions(on_done)
  M.ensure_connected(function(ok, err)
    if not ok then
      on_done(nil, err)
      return
    end
    state.client:request('session/list', {}, function(msg)
      if msg.error then
        on_done(nil, msg.error.message or 'session/list failed')
        return
      end
      state.session_list = (msg.result and msg.result.sessions) or {}
      on_done(state.session_list, nil)
    end, { timeout_ms = 20000 })
  end)
end

---Start a fresh session (or resume an existing one when `session_id` is given).
---@param opts { session_id:string|nil, model:string|nil, reasoning_effort:string|nil, cwd:string|nil }
---@param on_done fun(ok:boolean, session_id:string|nil, err:string|nil)
function M.start_session(opts, on_done)
  opts = opts or {}
  if opts.cwd then state.cwd = opts.cwd end
  M.ensure_connected(function(ok, err)
    if not ok then
      on_done(false, nil, err)
      return
    end
    local function apply_defaults(session_id)
      state.session_id = session_id
      state.busy = false
      local model = opts.model or (config().get and config().get('model')) or nil
      local effort = opts.reasoning_effort or (config().get and config().get('reasoning_effort')) or nil
      local function finish()
        M.emit('session', session_id)
        on_done(true, session_id, nil)
      end
      if model then
        M.set_config_option('model', model, function() 
          if effort then M.set_config_option('reasoning_effort', effort, finish) else finish() end
        end)
      elseif effort then
        M.set_config_option('reasoning_effort', effort, finish)
      else
        finish()
      end
    end

    if opts.session_id then
      state.client:request('session/resume', {
        sessionId = opts.session_id,
        cwd = state.cwd,
        mcpServers = {},
      }, function(msg)
        if msg.error then
          on_done(false, nil, msg.error.message or 'session/resume failed')
          return
        end
        state.config_options = (msg.result and msg.result.configOptions) or {}
        apply_defaults(opts.session_id)
      end, { timeout_ms = 30000 })
      return
    end

    state.client:request('session/new', {
      cwd = state.cwd,
      mcpServers = {},
    }, function(msg)
      if msg.error then
        on_done(false, nil, msg.error.message or 'session/new failed')
        return
      end
      local result = msg.result or {}
      state.config_options = result.configOptions or {}
      apply_defaults(result.sessionId)
    end, { timeout_ms = 60000 })
  end)
end

---Change a negotiated session option.
---The harness accepts a JSON-encoded string for `model` (an array value or a
---stringified array are both rejected) and a plain string for
---`reasoning_effort`. Reproduced from a live `acp` profile.
---@param config_id string
---@param value string
---@param on_done fun(ok:boolean, err:string|nil)|nil
function M.set_config_option(config_id, value, on_done)
  on_done = on_done or function() end
  if not state.client or not state.session_id then
    on_done(false, 'no active session')
    return
  end
  if type(value) ~= 'string' then
    -- Defensive: encode tables the way the harness expects.
    if type(value) == 'table' then
      value = vim.json.encode(value)
    else
      value = tostring(value)
    end
  end
  state.client:request('session/set_config_option', {
    sessionId = state.session_id,
    configId = config_id,
    value = value,
  }, function(msg)
    if msg.error then
      on_done(false, msg.error.message or 'set_config_option failed')
      return
    end
    local result = msg.result or {}
    if result.configOptions then state.config_options = result.configOptions end
    -- Guard against the agent omitting untouched options from its reply.
    if config_id == 'model' and result.configOptions then
      local found = false
      for _, o in ipairs(result.configOptions) do
        if o.id == 'model' then found = true end
      end
      if not found then
        local prev = M.config_option('model')
        if prev then prev.currentValue = value end
      end
    end
    M.emit('config', state.config_options)
    on_done(true, nil)
  end, { timeout_ms = 20000 })
end

---Send a prompt. `text` may include injected context appended by the caller.
---@param text string
---@param on_done fun(ok:boolean, stop_reason:string|nil, err:string|nil)|nil
function M.prompt(text, on_done)
  on_done = on_done or function() end
  if type(text) ~= 'string' or text == '' then
    on_done(false, nil, 'empty prompt')
    return
  end
  M.ensure_connected(function(ok, err)
    if not ok then
      on_done(false, nil, err)
      return
    end
    if not state.session_id then
      M.start_session({}, function(started, _, start_err)
        if not started then
          on_done(false, nil, start_err)
          return
        end
        M.prompt(text, on_done)
      end)
      return
    end

    state.busy = true
    state.stop_reason = nil
    state.active_message = nil
    state.active_thought = nil
    state.last_message_id = nil
    state.last_thought_id = nil
    state.cancelled_turns = false
    state.client:clear_cancel()
    M.emit('busy', true)

    state.client:request('session/prompt', {
      sessionId = state.session_id,
      prompt = { { type = 'text', text = text } },
    }, function(msg)
      state.busy = false
      M.emit('busy', false)
      if msg.error then
        local m = msg.error.message or 'prompt failed'
        state.last_error = m
        local lower = m:lower()
        if lower:find('401') or lower:find('api key') or lower:find('unauthor') then
          m = m .. '\n\nHint: the selected model provider rejected the request. Either'
            .. '\n  * set its key from here:  :DshAuth     (see :DshProviders for status), or'
            .. '\n  * choose a model from a provider that is already signed in: <leader>dm, or'
            .. '\n  * run `dsh` once in a terminal to sign in.'
        end
        M.add_message('system', m, { kind = 'error' })
        on_done(false, nil, m)
        return
      end
      local stop = msg.result and msg.result.stopReason or 'end_turn'
      state.stop_reason = stop
      M.emit('turn_end', stop)
      on_done(true, stop, nil)
    end, { timeout_ms = 15 * 60 * 1000 })
  end)
end

---Ask the agent to stop the current turn.
function M.cancel()
  if state.client and state.session_id then
    state.cancelled_turns = true
    state.client:cancel(state.session_id)
    -- Optimistically unblock the UI; the prompt response still settles later.
    if state.busy then
      state.busy = false
      M.emit('busy', false)
    end
  end
end

---Close the active session but keep the agent process alive.
function M.close_session(on_done)
  on_done = on_done or function() end
  if not state.client or not state.session_id then
    on_done(true)
    return
  end
  local sid = state.session_id
  state.session_id = nil
  state.client:request('session/close', { sessionId = sid }, function()
    M.emit('session', nil)
    on_done(true)
  end, { timeout_ms = 15000 })
end

---Tear everything down (process included).
function M.shutdown()
  if state.client then
    pcall(function() state.client:stop() end)
  end
  state.client = nil
  state.connected = false
  state.busy = false
  state.session_id = nil
  M.emit('shutdown')
end

---Open (or focus) the sidebar. Implemented in the UI layer; this indirection
---lets keymaps and other modules trigger it without a hard dependency.
function M.toggle()
  local ok, sidebar = pcall(require, 'dshstudio.ui.sidebar')
  if not ok or type(sidebar) ~= 'table' or type(sidebar.toggle) ~= 'function' then
    util().notify('sidebar module unavailable: ' .. tostring(sidebar), vim.log.levels.ERROR)
    return
  end
  sidebar.toggle()
end

---Interactive model picker delegate.
function M.pick_model()
  local ok, sidebar = pcall(require, 'dshstudio.ui.sidebar')
  if not ok then return end
  sidebar.pick_model()
end

return M
