-- dshstudio/ui/sidebar.lua
--
-- The DeepSeek Harness panel: a right-hand split holding a streaming transcript
-- plus a dedicated input buffer.
--
-- Design notes:
--   * Two buffers in one column keeps the focus model predictable and avoids
--     fighting with floating-window resize events.
--   * Transcript rendering is scheduled and throttled: streaming chunks arrive
--     far faster than a redraw is useful, and re-rendering on every chunk also
--     steals the user's cursor position in the input buffer.
--   * The panel holds no conversation state of its own; everything comes from
--     `dshstudio.core.session`, so closing the panel never loses a session.

local M = {}

local uv = vim.uv or vim.loop

local ns = vim.api.nvim_create_namespace('dshstudio.sidebar')

local S = {
  win = nil,
  buf = nil,          -- transcript buffer
  input_buf = nil,
  input_win = nil,
  open = false,
  dirty = false,
  render_timer = nil,
  last_render = 0,
  unsubscribe = {},
  last_meta = nil,
  width = 46,
  spinner = 0,
}

local SPIN = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return { notify = function(m, l) vim.notify(m, l, { title = 'DSH Studio' }) end }
end

local function session()
  local ok, mod = pcall(require, 'dshstudio.core.session')
  if not ok then return nil end
  return mod
end

local function config()
  local ok, mod = pcall(require, 'dshstudio.config')
  if ok and mod.get then return mod end
  return { get = function(_, default) return default end }
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function usage_line()
  local s = session()
  if not s then return '' end
  local u = s.get_usage()
  local parts = {}
  table.insert(parts, 'model: ' .. s.model_label())
  local effort = s.config_option('reasoning_effort')
  if effort and effort.currentValue and effort.currentValue ~= '' then
    table.insert(parts, 'effort: ' .. tostring(effort.currentValue))
  end
  if u and u.size and u.size > 0 then
    table.insert(parts, ('ctx: %d/%d'):format(u.used or 0, u.size))
  end
  if s.is_busy() then
    S.spinner = (S.spinner % #SPIN) + 1
    table.insert(parts, SPIN[S.spinner] .. ' working')
  end
  return table.concat(parts, '  |  ')
end

local function header_lines()
  local s = session()
  local out = {}
  local title = '  DSH Studio — DeepSeek Harness'
  table.insert(out, title)
  local status = usage_line()
  if status ~= '' then table.insert(out, '  ' .. status) end
  table.insert(out, '')
  if s and not s.is_connected() then
    local st = s.agent_status()
    if not st.found then
      table.insert(out, '  agent not found: ' .. (st.discovered_by or 'unknown'))
      table.insert(out, '  install with: npm i -g @deepseek-ai/dsh')
      table.insert(out, '  then press <leader>dd again.')
      table.insert(out, '')
    end
  end
  return out
end

local function push_message(out, hl, msg)
  local role = msg.role
  if role == 'user' then
    table.insert(out, { '▌ You', 'DshSidebarUser' })
    for _, line in ipairs(vim.split(msg.text or '', '\n')) do
      table.insert(out, { '  ' .. line, 'DshSidebarUserText' })
    end
    table.insert(out, { '' })
  elseif role == 'agent' then
    table.insert(out, { '▌ DSH', 'DshSidebarAgent' })
    local text = msg.text or ''
    if text == '' then text = '…' end
    for _, line in ipairs(vim.split(text, '\n')) do
      table.insert(out, { '  ' .. line, 'DshSidebarAgentText' })
    end
    table.insert(out, { '' })
  elseif role == 'thought' then
    local text = msg.text or ''
    local first = vim.split(text, '\n')[1] or ''
    table.insert(out, { '  · ' .. first:sub(1, 200), 'DshSidebarThought' })
    local n = select(2, text:gsub('\n', '\n'))
    if n > 0 then
      table.insert(out, { ('    … %d more lines of reasoning'):format(n), 'DshSidebarThought' })
    end
  elseif role == 'tool' then
    local meta = msg.meta or {}
    local mark = ({ in_progress = '◐', completed = '●', failed = '✗' })[meta.status] or '○'
    local title = meta.title or meta.kind or 'tool'
    table.insert(out, { ('  %s %s'):format(mark, title), 'DshSidebarTool' })
    if meta.raw_input and next(meta.raw_input) ~= nil then
      local ok, encoded = pcall(vim.json.encode, meta.raw_input)
      if ok then
        local clipped = tostring(encoded):sub(1, 240)
        table.insert(out, { '      ' .. clipped, 'DshSidebarToolDetail' })
      end
    end
    local body = msg.text or ''
    if body ~= '' then
      local lines = vim.split(body, '\n')
      for i = 1, math.min(#lines, 8) do
        table.insert(out, { '      ' .. lines[i]:sub(1, 300), 'DshSidebarToolDetail' })
      end
      if #lines > 8 then
        table.insert(out, { ('      … %d more lines (press gx to jump to the file)'):format(#lines - 8), 'DshSidebarToolDetail' })
      end
    end
  elseif role == 'system' then
    for _, line in ipairs(vim.split(msg.text or '', '\n')) do
      table.insert(out, { '  ' .. line, 'DshSidebarSystem' })
    end
    table.insert(out, { '' })
  end
end

---Recompute and paint the transcript buffer.
function M.render()
  S.dirty = false
  S.last_render = uv.hrtime() / 1e6
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end

  local lines = header_lines()
  local s = session()
  local msgs = s and s.get_messages() or {}
  for _, msg in ipairs(msgs) do push_message(lines, nil, msg) end
  if #msgs == 0 then
    table.insert(lines, { '  Ask about the current file, a selection, or the project.', 'DshSidebarHint' })
    table.insert(lines, { '  <leader>da asks; <leader>dp runs the project analysis.', 'DshSidebarHint' })
    table.insert(lines, { '' })
    table.insert(lines, { '  <leader>dm switch model     <leader>dc clear', 'DshSidebarHint' })
    table.insert(lines, { '  <leader>dn new session      <leader>di insert last reply', 'DshSidebarHint' })
  end

  local text, highlights = {}, {}
  for i, entry in ipairs(lines) do
    if type(entry) == 'table' then
      text[i] = entry[1]
      if entry[2] then highlights[i - 1] = entry[2] end
    else
      text[i] = entry
    end
  end

  local was_at_end = false
  if vim.api.nvim_win_is_valid(S.win) then
    local info = vim.fn.getwininfo(S.win)[1]
    if info then
      was_at_end = (info.botline >= vim.api.nvim_buf_line_count(S.buf) - 1)
    end
  else
    was_at_end = true
  end

  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, text)
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for lnum, group in pairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, group, lnum, 0, -1)
  end
  -- Markdown-ish emphasis on the transcript for readability.
  for i, line in ipairs(text) do
    if line:match('^▌ You') then
      pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, 'DshSidebarUser', i - 1, 0, -1)
    elseif line:match('^▌ DSH') then
      pcall(vim.api.nvim_buf_add_highlight, S.buf, ns, 'DshSidebarAgent', i - 1, 0, -1)
    end
  end
  vim.bo[S.buf].modifiable = false

  if was_at_end and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_win_set_cursor(S.win, { math.max(1, #text), 0 })
  end
end

---Throttled render request (streaming safe).
function M.schedule_render()
  S.dirty = true
  if S.render_timer then return end
  local elapsed = (uv.hrtime() / 1e6) - S.last_render
  local delay = math.max(0, 60 - elapsed)
  S.render_timer = uv.new_timer()
  S.render_timer:start(delay, 0, function()
    S.render_timer:stop()
    S.render_timer:close()
    S.render_timer = nil
    vim.schedule(function()
      if S.open then M.render() end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Input buffer
-- ---------------------------------------------------------------------------

local function input_buf()
  if S.input_buf and vim.api.nvim_buf_is_valid(S.input_buf) then return S.input_buf end
  local buf = vim.api.nvim_create_buf(false, true)
  S.input_buf = buf
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'dshstudio_input'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })

  local map = function(lhs, rhs, desc, mode)
    vim.keymap.set(mode or { 'n', 'i' }, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  local function send()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, '\n')
    if text:match('%S') then
      M.send(text)
    end
  end
  map('<C-s>', send, 'Send prompt')
  map('<C-CR>', send, 'Send prompt')
  map('<C-j>', send, 'Send prompt')
  map('<CR>', function()
    if vim.fn.mode() == 'n' then
      send()
    else
      -- Insert a literal newline in insert mode.
      return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'n', false)
    end
  end, 'Send (normal) / newline (insert)')
  map('q', '<cmd>lua require("dshstudio.ui.sidebar").close()<CR>', 'Close panel', 'n')
  map('?', function()
    util().notify('<C-s> send · <CR> send · i insert · q close · <leader>dm model · <leader>dc clear',
      vim.log.levels.INFO)
  end, 'Help', 'n')
  map('gd', function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    S.jump_from_input(cursor[1])
  end, 'Jump to file mentioned on this line', 'n')

  vim.api.nvim_create_autocmd({ 'BufWipeout' }, {
    buffer = buf,
    callback = function() S.input_buf = nil end,
  })
  return buf
end

---Try to open the first path-looking token on the transcript line under the
---cursor of the input buffer (helps after a tool call result).
---@param _ integer
function S.jump_from_input(_)
  local s = session()
  if not s then return end
  -- Search the transcript backwards for a path-like token, newest first.
  local msgs = s.get_messages()
  for i = #msgs, 1, -1 do
    local msg = msgs[i]
    local hay = (msg.text or '') .. ' ' .. (msg.meta and msg.meta.title or '')
    for candidate in hay:gmatch('[%w%._/\\%-]+%.[%a]+') do
      local path = candidate
      if vim.fn.filereadable(path) == 0 then
        local rel = vim.fn.getcwd() .. '/' .. candidate
        if vim.fn.filereadable(rel) == 1 then path = rel end
      end
      if vim.fn.filereadable(path) == 1 then
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        util().notify('opened ' .. path, vim.log.levels.INFO)
        return
      end
    end
  end
  util().notify('no referenced file found in the transcript', vim.log.levels.WARN)
end

-- ---------------------------------------------------------------------------
-- Window management
-- ---------------------------------------------------------------------------

local function set_win_options(win)
  pcall(vim.api.nvim_set_option_value, 'number', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'relativenumber', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'signcolumn', 'no', { win = win })
  pcall(vim.api.nvim_set_option_value, 'cursorline', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'wrap', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'linebreak', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'winfixwidth', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'list', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'winbar',
    '%#DshSidebarBar# DSH Studio %= %#DshSidebarBarDim#<leader>dd close  <C-s> send ',
    { win = win })
end

function M.open_panel()
  if S.open and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_set_current_win(S.input_win or S.win)
    return
  end
  local width = tonumber(config().get('sidebar_width')) or 46
  width = math.max(28, math.min(width, math.floor(vim.o.columns * 0.6)))
  S.width = width

  vim.cmd('botright vertical new')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  S.win, S.buf = win, buf
  vim.api.nvim_win_set_width(win, width)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'dshstudio'
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, 'dsh://transcript')
  set_win_options(win)

  -- Input split below the transcript.
  vim.cmd('belowright split')
  local iwin = vim.api.nvim_get_current_win()
  local ibuf = input_buf()
  vim.api.nvim_win_set_buf(iwin, ibuf)
  vim.api.nvim_win_set_height(iwin, 7)
  S.input_win = iwin
  set_win_options(iwin)
  pcall(vim.api.nvim_set_option_value, 'wrap', true, { win = iwin })

  S.open = true
  S:wire()
  M.render()
  vim.api.nvim_set_current_win(iwin)
  vim.cmd('startinsert')
  util().notify('DeepSeek panel open — type and press <C-s> to send', vim.log.levels.INFO)
end

function M.close()
  if S.input_win and vim.api.nvim_win_is_valid(S.input_win) then
    pcall(vim.api.nvim_win_close, S.input_win, true)
  end
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  S.win, S.input_win, S.open = nil, nil, false
end

function M.toggle()
  if S.open and vim.api.nvim_win_is_valid(S.win) then
    M.close()
  else
    M.open_panel()
  end
end

function M.is_open()
  return S.open and S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

---Send the raw input text with automatic context injection.
---@param text string
---@param opts { mode:string|nil, echo:boolean|nil }|nil
function M.send(text, opts)
  opts = opts or {}
  local s = session()
  if not s then
    util().notify('session module unavailable', vim.log.levels.ERROR)
    return
  end
  if s.is_busy() then
    util().notify('a request is already running — press <leader>dq to cancel', vim.log.levels.WARN)
    return
  end

  -- Clear the input buffer immediately so the UI feels responsive.
  if S.input_buf and vim.api.nvim_buf_is_valid(S.input_buf) then
    vim.api.nvim_buf_set_lines(S.input_buf, 0, -1, false, { '' })
  end

  local mode = opts.mode
  if mode == nil then
    mode = (config().get('auto_context') == false) and 'none' or 'file'
  end
  local payload, meta
  local ok, ctx = pcall(require, 'dshstudio.core.context')
  if ok then
    payload, meta = ctx.compose_prompt(text, { mode = mode })
  else
    payload = text
    meta = { included = {} }
  end
  S.last_meta = meta

  s.add_message('user', text, { context = meta and meta.included or {} })
  s.prompt(payload, function(ok2, _stop, err)
    if not ok2 and err then
      vim.schedule(function()
        M.schedule_render()
        util().notify('request failed: ' .. err, vim.log.levels.ERROR)
      end)
    end
  end)
  M.schedule_render()
end

---Open the panel and prefill the input buffer (used by <leader>da etc).
---@param prefill string|nil
---@param mode string|nil
function M.ask(prefill, mode)
  if not M.is_open() then M.open_panel() end
  local buf = input_buf()
  if prefill and prefill ~= '' then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(prefill, '\n'))
  end
  S.pending_mode = mode
  if S.input_win and vim.api.nvim_win_is_valid(S.input_win) then
    vim.api.nvim_set_current_win(S.input_win)
    vim.cmd('startinsert')
    vim.api.nvim_win_set_cursor(S.input_win, { 1, 0 })
  end
end

---Ask about the current selection directly (no typing).
function M.ask_selection()
  local s = session()
  if not s then return end
  local sr, er = nil, nil
  local ok, ctx = pcall(require, 'dshstudio.core.context')
  if ok then sr, er = ctx.selection_range() end
  if not sr then
    util().notify('no visual selection — select code first, then <leader>da', vim.log.levels.WARN)
    return
  end
  M.ask(('Explain the selected code (lines %d-%d) and point out any bug.'):format(sr, er), 'selection')
end

-- ---------------------------------------------------------------------------
-- Model / session commands
-- ---------------------------------------------------------------------------

function M.pick_model()
  local s = session()
  if not s then return end
  local function present(choices, title)
    if #choices == 0 then
      util().notify('no ' .. title .. ' options reported by the agent yet', vim.log.levels.WARN)
      return
    end
    vim.ui.select(choices, {
      prompt = 'Select ' .. title,
      format_item = function(item)
        local mark = item.current and '● ' or '  '
        local desc = item.description and (' — ' .. item.description:sub(1, 60)) or ''
        return ('%s%s/%s%s'):format(mark, item.group or '', item.name or item.value, desc)
      end,
    }, function(choice)
      if not choice then return end
      s.set_config_option(choice.config_id, choice.value, function(ok, err)
        if ok then
          util().notify(('%s set to %s'):format(choice.config_id, choice.name), vim.log.levels.INFO)
        else
          util().notify('switch failed: ' .. tostring(err), vim.log.levels.ERROR)
        end
        M.schedule_render()
      end)
    end)
  end

  if not s.is_connected() or not s.get_session_id() then
    -- Ensure there is a session so the agent can advertise its options.
    s.start_session({}, function(ok, _sid, err)
      if not ok then
        util().notify('cannot start session: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      present(s.model_choices(), 'model')
    end)
    return
  end
  present(s.model_choices(), 'model')
end

function M.pick_effort()
  local s = session()
  if not s then return end
  local choices = s.effort_choices()
  vim.ui.select(choices, {
    prompt = 'Reasoning effort',
    format_item = function(item) return (item.current and '● ' or '  ') .. tostring(item.name) end,
  }, function(choice)
    if not choice then return end
    s.set_config_option('reasoning_effort', choice.value, function(ok, err)
      util().notify(ok and ('reasoning effort: ' .. choice.name) or ('failed: ' .. tostring(err)),
        ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end)
end

function M.new_session()
  local s = session()
  if not s then return end
  s.close_session(function()
    s.clear()
    s.start_session({}, function(ok, _sid, err)
      if ok then
        util().notify('new DSH session started', vim.log.levels.INFO)
      else
        util().notify('failed to start session: ' .. tostring(err), vim.log.levels.ERROR)
      end
      M.schedule_render()
    end)
  end)
end

---Insert the last agent reply into the file behind the panel.
function M.insert_last_reply()
  local s = session()
  if not s then return end
  local msgs = s.get_messages()
  for i = #msgs, 1, -1 do
    if msgs[i].role == 'agent' and (msgs[i].text or '') ~= '' then
      local text = msgs[i].text
      -- Prefer fenced code content when the reply is a single code block.
      local blocks = {}
      for body in text:gmatch('```[%w%+%-]*\n(.-)\n```') do table.insert(blocks, body) end
      local payload = (#blocks == 1) and blocks[1] or text
      local lines = vim.split(payload, '\n')
      local target = vim.api.nvim_get_current_buf()
      if not vim.api.nvim_buf_is_valid(target) then return end
      local cursor = vim.api.nvim_win_get_cursor(0)
      vim.api.nvim_buf_set_lines(target, cursor[1], cursor[1], false, lines)
      util().notify('inserted last reply below the cursor', vim.log.levels.INFO)
      return
    end
  end
  util().notify('no agent reply to insert yet', vim.log.levels.WARN)
end

---Copy the transcript (or the last reply) to the system clipboard.
function M.copy_last_reply()
  local s = session()
  if not s then return end
  local msgs = s.get_messages()
  for i = #msgs, 1, -1 do
    if msgs[i].role == 'agent' and (msgs[i].text or '') ~= '' then
      vim.fn.setreg('+', msgs[i].text)
      util().notify('last reply copied to clipboard', vim.log.levels.INFO)
      return
    end
  end
  util().notify('nothing to copy yet', vim.log.levels.WARN)
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

function S:wire()
  local s = session()
  if not s or self.wired then return end
  self.wired = true
  s.on('messages_changed', function() M.schedule_render() end)
  s.on('usage', function() M.schedule_render() end)
  s.on('busy', function()
    M.schedule_render()
    -- Keep the header spinner ticking while a turn runs.
    local timer = uv.new_timer()
    timer:start(120, 120, function()
      vim.schedule(function()
        local sess = session()
        if not sess or not sess.is_busy() or not M.is_open() then
          timer:stop()
          timer:close()
          return
        end
        M.schedule_render()
      end)
    end)
  end)
  s.on('connected', function() M.schedule_render() end)
  s.on('turn_end', function() M.schedule_render() end)
end

return M
