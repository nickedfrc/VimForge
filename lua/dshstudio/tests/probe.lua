-- dshstudio/tests/probe.lua
--
-- Offline self-tests for the ACP client and the context builder.
--
-- The transport is injectable, so the protocol state machine can be driven
-- against a scripted peer without spawning a process. That keeps these tests
-- runnable in CI and in sandboxes that forbid piped stdio.
--
-- Run with `:DshSelfTest`, or headlessly:
--   nvim --headless --cmd "set rtp+=<repo>" -c "lua require('dshstudio.tests.probe').run_all()" -c qa

local M = {}

local results = {}

local function record(name, ok, detail)
  table.insert(results, { name = name, ok = ok, detail = detail })
end

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    record(name, true)
  else
    record(name, false, tostring(err))
  end
end

local function eq(actual, expected, label)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(label or 'value', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function ok(value, label)
  if not value then error((label or 'assertion') .. ': expected truthy', 2) end
end

---A scripted peer that records what the client wrote and can inject frames.
local function fake_transport()
  local t = {
    written = {},
    killed = false,
    handlers = {},
  }
  function t.spawn(handlers)
    t.handlers = handlers
    return true
  end
  function t.write(payload)
    table.insert(t.written, payload)
    return true
  end
  function t.kill() t.killed = true end

  ---Frames the client has sent, decoded.
  function t.sent()
    local out = {}
    for _, raw in ipairs(t.written) do
      for line in raw:gmatch('[^\n]+') do
        local decoded = vim.json.decode(line)
        table.insert(out, decoded)
      end
    end
    return out
  end

  ---Find the first sent frame with a given method.
  function t.sent_method(method)
    for _, frame in ipairs(t.sent()) do
      if frame.method == method then return frame end
    end
    return nil
  end

  ---Inject a frame from the "agent".
  function t.emit(frame)
    local payload = type(frame) == 'string' and frame or (vim.json.encode(frame) .. '\n')
    t.handlers.on_stdout(payload)
  end

  function t.emit_stderr(text) t.handlers.on_stderr(text) end
  function t.exit(code) t.handlers.on_exit(code, 0) end
  return t
end

local function new_client(transport)
  local acp = require('dshstudio.core.acp')
  return acp.new({
    command = { 'unused' },
    transport = transport,
    timeout_ms = 2000,
  })
end

-- ---------------------------------------------------------------------------
-- Protocol tests
-- ---------------------------------------------------------------------------

local function test_framing()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()

  local results_seen = {}
  client:request('initialize', { protocolVersion = 1 }, function(msg) table.insert(results_seen, msg) end)

  local sent = transport.sent()
  eq(#sent, 1, 'one frame written')
  eq(sent[1].jsonrpc, '2.0', 'jsonrpc version')
  eq(sent[1].method, 'initialize', 'method')
  eq(sent[1].id, 1, 'first id is 1')
  ok(transport.written[1]:sub(-1) == '\n', 'frame is newline terminated')
  ok(not transport.written[1]:find('Content-Length', 1, true), 'no Content-Length framing')

  -- A response split across two chunks must still be correlated.
  transport.emit('{"jsonrpc":"2.0","id":1,"resu')
  eq(#results_seen, 0, 'partial frame is buffered')
  transport.emit('lt":{"protocolVersion":1}}\n')
  eq(#results_seen, 1, 'split frame decoded')
  eq(results_seen[1].result.protocolVersion, 1, 'result payload')
end

local function test_crlf_and_blank_lines()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  local seen = 0
  client:request('session/list', {}, function() seen = seen + 1 end)
  transport.emit('\r\n')
  transport.emit('{"jsonrpc":"2.0","id":1,"result":{"sessions":[]}}\r\n')
  eq(seen, 1, 'crlf frame decoded once')
end

local function test_multiple_frames_in_one_chunk()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  local got = {}
  client:request('a', {}, function(msg) table.insert(got, msg.result.n) end)
  client:request('b', {}, function(msg) table.insert(got, msg.result.n) end)
  transport.emit('{"jsonrpc":"2.0","id":1,"result":{"n":1}}\n{"jsonrpc":"2.0","id":2,"result":{"n":2}}\n')
  eq(#got, 2, 'both frames decoded')
  eq(got[1], 1, 'first result order')
  eq(got[2], 2, 'second result order')
end

local function test_error_response()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  local captured = nil
  client:request('session/new', {}, function(msg) captured = msg end)
  transport.emit({ jsonrpc = '2.0', id = 1, error = { code = -32602, message = 'cwd must be an absolute path' } })
  ok(captured ~= nil, 'error delivered')
  eq(captured.error.code, -32602, 'error code')
  ok(captured.error.message:find('absolute'), 'error message')
end

local function test_agent_request_permission()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  client:on_request('session/request_permission', function(params)
    eq(params.toolCall.toolCallId, 'call-1', 'toolCallId reaches handler')
    return { outcome = { outcome = 'selected', optionId = 'allow-once' } }
  end)
  transport.emit({
    jsonrpc = '2.0', id = 42, method = 'session/request_permission',
    params = {
      sessionId = 's1',
      toolCall = { toolCallId = 'call-1' },
      options = {
        { optionId = 'allow-once', name = 'Allow once', kind = 'allow_once' },
        { optionId = 'reject-once', name = 'Reject', kind = 'reject_once' },
      },
    },
  })
  local reply = transport.sent_method('session/request_permission')
  -- The answer is a response frame with the same id and no method.
  local answered = nil
  for _, frame in ipairs(transport.sent()) do
    if frame.id == 42 and frame.result then answered = frame end
  end
  ok(answered ~= nil, 'client answered the permission request')
  eq(answered.result.outcome.outcome, 'selected', 'outcome kind')
  eq(answered.result.outcome.optionId, 'allow-once', 'optionId echoed')
  ok(reply == nil, 'permission answer is a response, not a call')
end

local function test_unhandled_agent_request()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  transport.emit({ jsonrpc = '2.0', id = 7, method = 'terminal/create', params = {} })
  local answered = nil
  for _, frame in ipairs(transport.sent()) do
    if frame.id == 7 and frame.error then answered = frame end
  end
  ok(answered ~= nil, 'unknown request answered')
  eq(answered.error.code, -32601, 'method not found code')
end

local function test_streaming_updates()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  local updates = {}
  client:on_notification('session/update', function(update) table.insert(updates, update) end)

  transport.emit({
    jsonrpc = '2.0', method = 'session/update',
    params = { sessionId = 's', update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'Hel' } } },
  })
  transport.emit({
    jsonrpc = '2.0', method = 'session/update',
    params = { sessionId = 's', update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'lo' } } },
  })
  transport.emit({
    jsonrpc = '2.0', method = 'session/update',
    params = { sessionId = 's', update = { sessionUpdate = 'usage_update', used = 10, size = 100 } },
  })

  eq(#updates, 3, 'three updates dispatched')
  eq(updates[1].content.text, 'Hel', 'first chunk')
  eq(updates[2].content.text, 'lo', 'second chunk')
  eq(updates[3].sessionUpdate, 'usage_update', 'usage update')
end

local function test_cancel_uses_notification()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  client:cancel('session-9')
  local frame = transport.sent_method('session/cancel')
  ok(frame ~= nil, 'cancel notification sent')
  eq(frame.params.sessionId, 'session-9', 'cancel carries sessionId')
  eq(frame.id, nil, 'cancel is a notification (no id)')
  ok(client:is_cancelled(), 'client records cancellation')
end

local function test_exit_fails_pending()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  local captured = nil
  client:request('session/prompt', {}, function(msg) captured = msg end)
  transport.exit(1)
  ok(captured ~= nil, 'pending request settled on exit')
  ok(captured.error ~= nil, 'settled with an error')
  ok(not client:is_alive(), 'client marked dead')
end

local function test_stderr_tail_is_surfaced()
  local transport = fake_transport()
  local client = new_client(transport)
  client:start()
  transport.emit_stderr('warning: no credentials\n')
  transport.emit_stderr('error: 401 Invalid API Key\n')
  eq(client:stderr_summary(), 'error: 401 Invalid API Key', 'last stderr line kept')
end

-- ---------------------------------------------------------------------------
-- Session / context tests
-- ---------------------------------------------------------------------------

local function test_session_transcript()
  local session = require('dshstudio.core.session')
  session.clear()
  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'm1', content = { type = 'text', text = 'Hello ' } })
  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'm1', content = { type = 'text', text = 'world' } })
  local msgs = session.get_messages()
  eq(#msgs, 1, 'chunks with one messageId merge')
  eq(msgs[1].text, 'Hello world', 'text concatenated')

  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'm2', content = { type = 'text', text = 'Second' } })
  eq(#session.get_messages(), 2, 'a new messageId starts a message')
  eq(session.get_messages()[2].text, 'Second', 'the new message holds only its own text')

  -- Regression: a third message must not be appended to the second.
  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'm3', content = { type = 'text', text = 'Third' } })
  eq(#session.get_messages(), 3, 'each messageId is its own message')
  eq(session.get_messages()[3].text, 'Third', 'third message text isolated')

  -- Chunks without a messageId keep appending to the current message.
  session.handle_update({ sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = '!' } })
  eq(session.get_messages()[#session.get_messages()].text, 'Third!',
    'a chunk without an id continues the current message')

  -- A reasoning block opens its own entry and ends the current text bubble, so
  -- text that follows the thinking becomes a new message rather than growing the
  -- one that preceded it.
  local before_thought = #session.get_messages()
  session.handle_update({ sessionUpdate = 'agent_thought_chunk', messageId = 't1', content = { type = 'text', text = 'thinking' } })
  session.handle_update({ sessionUpdate = 'agent_thought_chunk', messageId = 't1', content = { type = 'text', text = ' more' } })
  eq(#session.get_messages(), before_thought + 1, 'thought chunks merge by their own id')
  local thought = session.get_messages()[before_thought + 1]
  eq(thought.role, 'thought', 'thought role recorded')
  eq(thought.text, 'thinking more', 'thought text concatenated')

  local before_after = #session.get_messages()
  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'm4', content = { type = 'text', text = 'After thinking' } })
  eq(#session.get_messages(), before_after + 1, 'text after reasoning is its own message')
  eq(session.get_messages()[#session.get_messages()].text, 'After thinking',
    'text after reasoning is not appended to the earlier bubble')

  session.handle_update({
    sessionUpdate = 'tool_call', toolCallId = 't1', title = 'glob',
    kind = 'other', status = 'in_progress', rawInput = { pattern = '*' },
  })
  session.handle_update({
    sessionUpdate = 'tool_call_update', toolCallId = 't1', status = 'completed',
    content = { { type = 'content', content = { type = 'text', text = 'a.f90\nb.f90' } } },
  })
  local tool_msg = nil
  for _, m in ipairs(session.get_messages()) do
    if m.role == 'tool' then tool_msg = m end
  end
  ok(tool_msg ~= nil, 'tool call recorded')
  eq(tool_msg.meta.status, 'completed', 'tool status updated')
  ok(tool_msg.text:find('a%.f90'), 'tool output captured')

  session.handle_update({ sessionUpdate = 'usage_update', used = 5, size = 1000 })
  eq(session.get_usage().used, 5, 'usage tracked')

  -- Unknown discriminators must not raise.
  session.handle_update({ sessionUpdate = 'some_future_update', payload = 1 })
  session.clear()
  eq(#session.get_messages(), 0, 'clear empties the transcript')

  -- After clear, streaming restarts cleanly (state must not leak).
  session.handle_update({ sessionUpdate = 'agent_message_chunk', messageId = 'n1', content = { type = 'text', text = 'fresh' } })
  eq(#session.get_messages(), 1, 'streaming resumes after clear')
  eq(session.get_messages()[1].text, 'fresh', 'no stale text after clear')
  session.clear()
end

local function test_model_choices()
  local session = require('dshstudio.core.session')
  session.state.config_options = {
    {
      id = 'model', name = 'Model', category = 'model', type = 'select',
      currentValue = '["deepseek-official","deepseek-v4-flash"]',
      options = {
        {
          group = 'deepseek-official', name = 'DeepSeek',
          options = {
            { value = '["deepseek-official","deepseek-v4-flash"]', name = 'DeepSeek-V4-Flash' },
            { value = '["deepseek-official","deepseek-v4-pro"]', name = 'DeepSeek-V4-Pro' },
          },
        },
      },
    },
    {
      id = 'reasoning_effort', name = 'Reasoning effort', category = 'thought_level',
      type = 'select', currentValue = 'high',
      options = { { value = 'off', name = 'Off' }, { value = 'high', name = 'High' } },
    },
  }
  local choices = session.model_choices()
  eq(#choices, 2, 'flattened model groups')
  eq(choices[1].name, 'DeepSeek-V4-Flash', 'first model name')
  ok(choices[1].current, 'current model flagged')
  eq(session.model_choices()[2].config_id, 'model', 'config id attached')
  eq(session.effort_choices()[2].name, 'High', 'effort choices')
  eq(session.model_label(), 'DeepSeek-V4-Flash', 'model label resolves')
  session.state.config_options = {}
end

local function test_context_build()
  local ctx = require('dshstudio.core.context')
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'module demo', 'contains', '  subroutine hello()', '    print *, "hi"', '  end subroutine', 'end module',
  })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'fortran'
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. '/demo.f90')

  local text = ctx.build({ mode = 'file', include_buffers = false })
  ok(text:find('Editor context', 1, true) ~= nil, 'header present')
  ok(text:find('```fortran', 1, true) ~= nil, 'fenced with the fortran language')
  ok(text:find('subroutine hello', 1, true) ~= nil, 'file content included')
  ok(text:find('demo.f90', 1, true) ~= nil, 'path attributed')

  local payload = ctx.compose_prompt('Explain this', { mode = 'file', include_buffers = false })
  ok(payload:find('## Request', 1, true) ~= nil, 'request section appended')
  ok(payload:find('Explain this', 1, true) ~= nil, 'user text present')
  ok(#payload > #text, 'payload includes the context')

  eq(ctx.fence_language('fortran'), 'fortran', 'fortran fence')
  eq(ctx.fence_language('cpp'), 'cpp', 'cpp fence')
  eq(ctx.fence_language('weirdlang'), 'weirdlang', 'unknown fence passes through')

  -- Byte budget must be honoured.
  local huge = {}
  for i = 1, 5000 do huge[i] = 'x = ' .. i .. ' ! padding to exceed the context budget' end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, huge)
  local capped = ctx.build({ mode = 'file', include_buffers = false })
  ok(#capped < 60000, ('context capped by byte budget (got %d)'):format(#capped))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---The offline extractor must survive a UTF-8 BOM, which Windows editors add by
---default. A leading BOM hides the first line from `^module`/`^program`, so the
---primary declaration of a file silently vanished from the outline and the
---project report until this was fixed.
local function test_symbols_bom_and_merge()
  local symbols = require('dshstudio.project.symbols')

  -- Without a BOM.
  local plain = symbols.extract_source('module demo_mod\n  implicit none\nend module demo_mod\n', 'fortran')
  ok(#plain >= 1, 'plain module extracted')
  eq(plain[1].kind, 'module', 'module kind')
  eq(plain[1].name, 'demo_mod', 'module name')

  -- With a UTF-8 BOM prepended.
  local bom = '\239\187\191' .. 'module demo_mod\n  implicit none\nend module demo_mod\n'
  local with_bom = symbols.extract_source(bom, 'fortran')
  ok(#with_bom >= 1, 'module extracted despite the BOM')
  eq(with_bom[1].kind, 'module', 'BOM does not change the kind')
  eq(with_bom[1].name, 'demo_mod', 'BOM does not corrupt the name')

  -- A program unit on the first line behaves the same way.
  local prog = symbols.extract_source('\239\187\191' .. 'program solver\nend program solver\n', 'fortran')
  ok(#prog >= 1, 'program extracted despite the BOM')
  eq(prog[1].name, 'solver', 'program name')

  -- Nested declarations must be attributed to their enclosing module.
  local nested = symbols.extract_source(table.concat({
    'module outer_mod',
    'contains',
    '  subroutine inner()',
    '  end subroutine inner',
    'end module outer_mod',
    '',
  }, '\n'), 'fortran')
  local inner
  for _, s in ipairs(nested) do
    if s.name == 'inner' then inner = s end
  end
  ok(inner ~= nil, 'nested subroutine extracted')
  eq(inner.parent, 'outer_mod', 'nested subroutine attributed to its module')
end

local function test_headless_clip()
  local headless = require('dshstudio.core.headless')
  local short = 'hello'
  eq(headless.clip(short, 100), short, 'short strings untouched')
  local long = string.rep('a', 500)
  local clipped = headless.clip(long, 100)
  ok(#clipped > 100, 'clipping appends a marker')
  ok(clipped:find('truncated'), 'marker mentions truncation')
  -- Multi-byte safety: must not split a UTF-8 sequence.
  local cjk = string.rep('中', 100) -- 300 bytes
  local cut = headless.clip(cjk, 50)
  ok(vim.fn.strchars(cut) > 0, 'cjk clip is valid')
  ok(#cut - #('… [digest truncated to fit the command line]') <= 50 + 1, 'cjk clip respects the byte budget')
end

---`vim.system` returns a string with `text = true` and a list otherwise; the
---first version of the headless runner assumed a list and crashed on every
---successful call.
local function test_headless_output_normalisation()
  local headless = require('dshstudio.core.headless')
  eq(headless.join_output(nil), '', 'nil stream becomes empty')
  eq(headless.join_output('DSH_OK\n'), 'DSH_OK\n', 'string stream passes through')
  eq(headless.join_output({ 'a', 'b' }), 'a\nb', 'list stream is joined with newlines')
  eq(headless.join_output({}), '', 'empty list becomes empty')
  eq(headless.join_output(42), '42', 'unexpected types degrade to tostring')
end

local function test_agent_discovery()
  local session = require('dshstudio.core.session')
  local argv, how = session.resolve_agent_command()
  -- Discovery must either find a command or explain itself; it must not throw.
  ok(type(how) == 'string', 'discovery reports how it resolved')
  if argv then
    ok(type(argv) == 'table' and #argv > 0, 'argv is a non-empty table')
  end
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local ALL = {
  ['acp: newline framing and id correlation'] = test_framing,
  ['acp: CRLF and blank lines tolerated'] = test_crlf_and_blank_lines,
  ['acp: multiple frames in one chunk'] = test_multiple_frames_in_one_chunk,
  ['acp: error responses delivered'] = test_error_response,
  ['acp: permission request answered'] = test_agent_request_permission,
  ['acp: unknown request -> -32601'] = test_unhandled_agent_request,
  ['acp: streaming update dispatch'] = test_streaming_updates,
  ['acp: cancel is a notification'] = test_cancel_uses_notification,
  ['acp: exit settles pending requests'] = test_exit_fails_pending,
  ['acp: stderr tail surfaced'] = test_stderr_tail_is_surfaced,
  ['session: transcript assembly'] = test_session_transcript,
  ['session: model option flattening'] = test_model_choices,
  ['context: build and budget'] = test_context_build,
  ['headless: task clipping'] = test_headless_clip,
  ['headless: system output normalisation'] = test_headless_output_normalisation,
  ['symbols: BOM tolerance and module nesting'] = test_symbols_bom_and_merge,
  ['session: agent discovery'] = test_agent_discovery,
}

---Names of every registered test, sorted.
---@return string[]
function M.names()
  local names = vim.tbl_keys(ALL)
  table.sort(names)
  return names
end

---Run a single named test. Useful for isolating a hang or a failure.
---@param name string
---@return boolean ok
---@return string|nil err
function M.run_one(name)
  local fn = ALL[name]
  if not fn then
    return false, 'no such test: ' .. tostring(name)
  end
  local ok, err = pcall(fn)
  return ok, ok and nil or tostring(err)
end

---Run every test, print a report, and return true when all passed.
---@param opts { quiet:boolean|nil }|nil
---@return boolean all_passed
function M.run_all(opts)
  opts = opts or {}
  results = {}
  local names = vim.tbl_keys(ALL)
  table.sort(names)
  for _, name in ipairs(names) do
    check(name, ALL[name])
  end

  local passed, failed = 0, 0
  local lines = { '', 'DSH Studio self-test', string.rep('─', 52) }
  for _, r in ipairs(results) do
    if r.ok then
      passed = passed + 1
      table.insert(lines, ('  PASS  %s'):format(r.name))
    else
      failed = failed + 1
      table.insert(lines, ('  FAIL  %s'):format(r.name))
      table.insert(lines, ('        %s'):format(r.detail or ''))
    end
  end
  table.insert(lines, string.rep('─', 52))
  table.insert(lines, ('  %d passed, %d failed, %d total'):format(passed, failed, passed + failed))
  table.insert(lines, '')

  if not opts.quiet then
    -- Headless runs need the text on stdout; interactive runs get a buffer.
    if #vim.api.nvim_list_uis() == 0 then
      io.stdout:write(table.concat(lines, '\n') .. '\n')
    else
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = 'dshstudio_test'
      vim.api.nvim_open_win(buf, true, {
        relative = 'editor', width = math.min(84, vim.o.columns - 4),
        height = math.min(#lines, vim.o.lines - 4), row = 1, col = 2,
        style = 'minimal', border = 'rounded', title = ' DSH Self-Test ',
      })
      vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
    end
  end

  return failed == 0
end

---Exit code helper for headless CI usage.
function M.main()
  local ok = M.run_all({ quiet = false })
  if #vim.api.nvim_list_uis() == 0 then
    vim.cmd(ok and 'qa!' or 'cquit!')
  end
end

return M
