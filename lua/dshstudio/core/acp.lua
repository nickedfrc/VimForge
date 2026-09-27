-- dshstudio/core/acp.lua
--
-- Minimal, dependency-free Agent Client Protocol (ACP) v1 client for Neovim.
--
-- DeepSeek Harness exposes an ACP stdio endpoint (`dsh --profile acp`). The
-- wire format is newline-delimited JSON-RPC 2.0 on stdin/stdout, with stdout
-- strictly reserved for protocol frames. This module owns framing, request
-- correlation, agent->client callbacks, and cancellation notices.
--
-- The transport is injectable so the protocol logic can be exercised against a
-- fake peer in tests (`:DshSelfTest`) without spawning a process.

local M = {}

local uv = vim.uv or vim.loop

---@class DshAcpClient
---@field job integer|nil
---@field alive boolean
---@field next_id integer
---@field pending table<integer, {resolve:fun(msg:table), opts:table|nil}>
---@field inflight table<integer, integer>  request id -> protocol level
---@field group table<integer, table<integer, boolean>> level -> request ids
---@field handlers table<string, fun(params:table, client:DshAcpClient)>
---@field notifications table<string, fun(params:table)>
---@field stderr_tail string[]
---@field buffer string
---@field cancel_requested boolean
---@field last_cancel_ids integer[]
local Client = {}
Client.__index = Client

local function now_ms()
  return math.floor((uv.hrtime() / 1e6))
end

---Create a client.
---@param opts table {
---   command: string[]         -- argv used to spawn the agent
---   cwd: string|nil,
---   env: table|nil,
---   transport: table|nil      -- test seam: spawn/write/kill overrides
---   log: fun(level:string, msg:string)|nil
---   on_stderr: fun(line:string)|nil
---}
---@return DshAcpClient
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Client)
  self.opts = opts
  self.job = nil
  self.alive = false
  self.next_id = 0
  self.pending = {}
  self.inflight = {}
  self.group = {}
  self.handlers = {}
  self.notifications = {}
  self.buffer = ''
  self.stderr_tail = {}
  self.log_lines = {}
  self.cancel_requested = false
  self.last_cancel_ids = {}
  self.timeout_ms = opts.timeout_ms or 60000
  self.max_stderr_lines = 40
  return self
end

function Client:log(level, msg)
  table.insert(self.log_lines, ('[%s] %s'):format(level, msg))
  if #self.log_lines > 400 then table.remove(self.log_lines, 1) end
  if self.opts.log then self.opts.log(level, msg) end
end

function Client:is_alive()
  return self.alive
end

function Client:note_stderr(line)
  if not line or line == '' then return end
  table.insert(self.stderr_tail, line)
  if #self.stderr_tail > self.max_stderr_lines then table.remove(self.stderr_tail, 1) end
  self:log('stderr', line)
  if self.opts.on_stderr then self.opts.on_stderr(line) end
end

---Last non-empty stderr lines, for surfacing boot/credential failures.
---@return string
function Client:stderr_summary()
  for i = #self.stderr_tail, 1, -1 do
    local line = self.stderr_tail[i]
    if line and line:match('%S') then return line end
  end
  return ''
end

function Client:transport()
  return self.opts.transport
end

---Start the agent process.
---@param on_exit fun(code:integer, signal:integer)|nil
---@return boolean ok, string|nil err
function Client:start(on_exit)
  if self.alive then return true end
  local t = self:transport()
  if t and t.spawn then
    local ok, err = t.spawn({
      on_stdout = function(chunk) self:on_bytes(chunk) end,
      on_stderr = function(chunk) self:on_stderr_bytes(chunk) end,
      on_exit = function(code, signal) self:on_exit(code, signal, on_exit) end,
    })
    if not ok then return false, err or 'transport spawn failed' end
    self.alive = true
    return true
  end

  local argv = self.opts.command
  if type(argv) ~= 'table' or #argv == 0 then
    return false, 'no command configured'
  end
  local spawn_opts = {
    cwd = self.opts.cwd,
    env = self.opts.env,
    stdin = true,
    stdout = true,
    stderr = true,
    text = false,
    on_stderr = function(_, data)
      if data then self:on_stderr_bytes(table.concat(data, '\n')) end
    end,
    on_exit = function(_, code, _) self:on_exit(code, 0, on_exit) end,
  }
  local ok, job = pcall(vim.fn.jobstart, argv, vim.tbl_extend('force', spawn_opts, {
    on_stdout = function(_, data)
      if data then self:on_bytes(table.concat(data, '\n')) end
    end,
  }))
  if not ok then
    return false, ('failed to spawn: %s'):format(tostring(job))
  end
  if job <= 0 then
    return false, ('failed to spawn %s (jobstart returned %d)'):format(argv[1] or '?', job)
  end
  self.job = job
  self.alive = true
  self:log('info', 'agent started: ' .. table.concat(argv, ' '))
  return true
end

function Client:on_exit(code, signal, cb)
  local was_alive = self.alive
  self.alive = false
  self.job = nil
  -- Fail every outstanding request so callers never hang on a dead agent.
  for id, entry in pairs(self.pending) do
    entry.resolve({ error = { code = -32000, message = ('agent exited (code=%s)'):format(tostring(code)) } })
    self.pending[id] = nil
  end
  if was_alive then
    self:log('warn', ('agent exited code=%s signal=%s'):format(tostring(code), tostring(signal)))
  end
  if cb then cb(code, signal) end
end

---Feed raw bytes from the agent's stdout. Handles partial frames.
---@param chunk string
function Client:on_bytes(chunk)
  if not chunk or chunk == '' then return end
  self.buffer = self.buffer .. chunk
  -- Tolerate both LF and CRLF framing.
  while true do
    local nl = self.buffer:find('\n', 1, true)
    if not nl then break end
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    line = line:gsub('\r$', '')
    if line:match('%S') then self:on_line(line) end
  end
end

function Client:on_stderr_bytes(chunk)
  if not chunk or chunk == '' then return end
  for line in (chunk .. '\n'):gmatch('([^\n]*)\n') do self:note_stderr(line) end
end

---Parse and dispatch one protocol frame.
---@param line string
function Client:on_line(line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' then
    self:log('warn', 'non-JSON frame ignored: ' .. line:sub(1, 200))
    return
  end
  self:dispatch(msg)
end

---Route one decoded frame. Public so tests can inject frames directly.
---@param msg table
function Client:dispatch(msg)
  -- Response to one of our requests.
  if msg.id ~= nil and (msg.result ~= nil or msg.error ~= nil) then
    local entry = self.pending[msg.id]
    if entry then
      self.pending[msg.id] = nil
      if entry.opts and entry.opts.level then self:leave_group(entry.opts.level, msg.id) end
      entry.resolve(msg)
    end
    return
  end

  local method = msg.method
  if type(method) ~= 'string' then return end

  -- Request from the agent that expects a response from us.
  if msg.id ~= nil then
    self:handle_agent_request(msg)
    return
  end

  if method == 'session/update' then
    local params = msg.params or {}
    local update = params.update or params
    local handler = self.notifications['session/update']
    if handler then handler(update, params) end
    return
  end

  local handler = self.notifications[method]
  if handler then handler(msg.params or {}, msg) end
end

---Answer an agent->client request using a registered handler.
---@param msg table
function Client:handle_agent_request(msg)
  local handler = self.handlers[msg.method]
  if not handler then
    self:log('warn', 'unhandled agent request: ' .. tostring(msg.method))
    self:respond(msg.id, nil, { code = -32601, message = 'Method not found: ' .. tostring(msg.method) })
    return
  end
  local ok, result, err = pcall(handler, msg.params or {}, self, msg)
  if not ok then
    self:log('error', 'handler error for ' .. tostring(msg.method) .. ': ' .. tostring(result))
    self:respond(msg.id, nil, { code = -32603, message = 'Internal error: ' .. tostring(result) })
    return
  end
  self:respond(msg.id, result, err)
end

---Register the callback that answers an agent->client request.
---@param method string
---@param fn fun(params:table, client:DshAcpClient):table|nil, table|nil
function Client:on_request(method, fn)
  self.handlers[method] = fn
end

---Register a notification listener (e.g. `session/update`, `session/cancel`).
---@param method string
---@param fn fun(params:table, params_raw:table|nil)
function Client:on_notification(method, fn)
  self.notifications[method] = fn
end

function Client:send_raw(payload)
  local t = self:transport()
  if t and t.write then return t.write(payload) end
  if not self.job then return false, 'agent not running' end
  local ok, err = pcall(vim.fn.chansend, self.job, payload)
  if not ok then return false, tostring(err) end
  return true
end

---Send a request and wait for its response (callback style, never blocks).
---@param method string
---@param params table
---@param on_result fun(msg:table)
---@param opts {timeout_ms:integer|nil, level:integer|nil}|nil
---@return integer request_id
function Client:request(method, params, on_result, opts)
  if not self.alive then
    on_result({ error = { code = -32000, message = 'agent not running' } })
    return 0
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  opts = opts or {}
  self.pending[id] = { resolve = on_result, opts = opts }
  if opts.level then self:enter_group(opts.level, id) end
  local frame = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params }) .. '\n'
  local ok, err = self:send_raw(frame)
  if not ok then
    self.pending[id] = nil
    on_result({ error = { code = -32000, message = 'send failed: ' .. tostring(err) } })
    return 0
  end
  if opts.timeout_ms then
    local timer = uv.new_timer()
    timer:start(opts.timeout_ms, 0, function()
      timer:stop()
      timer:close()
      local entry = self.pending[id]
      if entry then
        self.pending[id] = nil
        entry.resolve({ error = { code = -32000, message = ('request %s timed out after %dms'):format(method, opts.timeout_ms) } })
      end
    end)
  end
  return id
end

---Send a notification (no response expected).
---@param method string
---@param params table
function Client:notify(method, params)
  local frame = vim.json.encode({ jsonrpc = '2.0', method = method, params = params }) .. '\n'
  return self:send_raw(frame)
end

---Answer an inbound request.
---@param id integer|string
---@param result table|nil
---@param err table|nil
function Client:respond(id, result, err)
  local frame
  if err then
    frame = vim.json.encode({ jsonrpc = '2.0', id = id, error = err })
  else
    frame = vim.json.encode({ jsonrpc = '2.0', id = id, result = result or vim.empty_dict() })
  end
  self:send_raw(frame .. '\n')
end

-- Cancellation groups: everything issued under one group id can be cancelled at
-- once via `session/cancel`, which is how ACP asks the agent to stop a turn.
function Client:enter_group(level, id)
  self.group[level] = self.group[level] or {}
  self.group[level][id] = true
end

function Client:leave_group(level, id)
  local g = self.group[level]
  if not g then return end
  g[id] = nil
  if next(g) == nil then self.group[level] = nil end
end

---Request cancellation of a session's active turn.
---@param session_id string
function Client:cancel(session_id)
  self.cancel_requested = true
  self:log('info', 'cancelling session ' .. tostring(session_id))
  self:notify('session/cancel', { sessionId = session_id })
end

function Client:is_cancelled()
  return self.cancel_requested
end

function Client:clear_cancel()
  self.cancel_requested = false
end

---Stop the agent process and fail outstanding requests.
function Client:stop()
  local t = self:transport()
  if t and t.kill then
    self.alive = false
    t.kill()
    return
  end
  if self.job then
    pcall(vim.fn.jobstop, self.job)
    self.job = nil
  end
  self.alive = false
end

---Convenience: connect and run the ACP handshake.
---@param client_info table
---@param on_done fun(ok:boolean, result:table|nil, err:string|nil)
function Client:initialize(client_info, on_done)
  local params = {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
    },
    clientInfo = client_info or { name = 'dshstudio', version = '0.1.0' },
  }
  self:request('initialize', params, function(msg)
    if msg.error then
      local extra = self:stderr_summary()
      local message = msg.error.message or 'initialize failed'
      if extra ~= '' and not message:find(extra, 1, true) then
        message = message .. ' | ' .. extra
      end
      on_done(false, nil, message)
      return
    end
    local result = msg.result or {}
    if result.protocolVersion == nil then
      on_done(false, nil, 'agent did not negotiate a protocol version')
      return
    end
    self.agent_info = result.agentInfo or {}
    self.agent_caps = result.agentCapabilities or {}
    self.auth_methods = result.authMethods or {}
    on_done(true, result, nil)
  end, { timeout_ms = self.timeout_ms })
end

M.Client = Client
M._now_ms = now_ms
return M
