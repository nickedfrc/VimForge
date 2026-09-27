-- dshstudio/core/headless.lua
--
-- One-shot DeepSeek Harness jobs via `dsh --profile headless`.
--
-- Verified against the real CLI:
--   * the task MUST be passed as a positional argv argument; an empty argv with
--     a piped stdin exits 1 with `error: a task is required, for example:
--     dsh --profile headless "run the tests"`.
--   * on success the final answer is written to stdout and nothing else is.
--
-- Because argv is the only channel, the payload is bounded (see
-- `MAX_TASK_BYTES`) to stay clear of the ~32k Windows command-line limit. The
-- caller (project analysis) is responsible for keeping its digest compact.

local M = {}

local uv = vim.uv or vim.loop

---Hard cap for the argv task payload. Windows CreateProcess allows ~32767
---UTF-16 units for the whole command line; UTF-8 Chinese text costs 3 bytes per
---character, so this leaves generous headroom.
M.MAX_TASK_BYTES = 20000

local jobs = {}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return {
    notify = function(msg, level) vim.notify(msg, level, { title = 'DSH Studio' }) end,
    is_windows = function() return package.config:sub(1, 1) == '\\' end,
    write_file = function(path, data)
      local fh = io.open(path, 'w')
      if not fh then return false end
      fh:write(data)
      fh:close()
      return true
    end,
  }
end

local function config()
  local ok, mod = pcall(require, 'dshstudio.config')
  if ok and mod.get then return mod end
  return { get = function(_, default) return default end }
end

local function session_module()
  local ok, mod = pcall(require, 'dshstudio.core.session')
  if ok then return mod end
  return nil
end

---Resolve the launcher argv for a profile.
---Reuses the session module's discovery so interactive and batch paths agree.
---@param profile string
---@return string[]|nil argv
---@return string how
function M.resolve_argv(profile)
  local s = session_module()
  local base, how
  if s and s.resolve_agent_command then
    base, how = s.resolve_agent_command()
  end
  if not base then
    if vim.fn.executable('dsh') == 1 then
      base, how = { 'dsh' }, 'PATH'
    else
      base, how = nil, 'not found'
    end
  end
  if not base then return nil, how end
  local argv = vim.list_extend({}, base)
  table.insert(argv, '--profile')
  table.insert(argv, profile)
  return argv, how
end

---Count bytes in a UTF-8 string.
local function byte_len(s)
  return #s
end

---Truncate a UTF-8 string to at most `limit` bytes without splitting a
---character, appending a marker when truncation happened.
---@param s string
---@param limit integer
---@return string
function M.clip(s, limit)
  if not s or #s <= limit then return s or '' end
  local cut = limit
  -- Walk back off a UTF-8 continuation byte (10xxxxxx).
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut) .. '\n… [digest truncated to fit the command line]'
end

---Normalize a `vim.system` output field to a single string.
---
---`text = true` yields a string, the non-text form yields a list of lines, and a
---missing stream is nil. Concatenating the string form with `table.concat`
---raises "bad argument #1 to 'concat' (table expected, got string)", which is
---exactly how a working harness call was reported as a crash during testing.
---@param value string|string[]|nil
---@return string
function M.join_output(value)
  if value == nil then return '' end
  if type(value) == 'string' then return value end
  if type(value) == 'table' then return table.concat(value, '\n') end
  return tostring(value)
end

---Run one headless task.
---@param opts {
---   prompt: string,
---   profile: string|nil,      -- default 'headless'
---   cwd: string|nil,
---   timeout_ms: integer|nil,
---   label: string|nil,
---   on_done: fun(ok:boolean, text:string|nil, err:string|nil)
--- }
---@return table|nil handle  { cancel = fun(), job = any, argv = string[] }
function M.run(opts)
  opts = opts or {}
  local on_done = opts.on_done or function() end
  local profile = opts.profile or 'headless'
  local argv, how = M.resolve_argv(profile)
  if not argv then
    on_done(false, nil, 'DeepSeek Harness CLI not found (' .. tostring(how) .. '). '
      .. 'Install it with `npm i -g @deepseek-ai/dsh`, or set `agent_command` in the config.')
    return nil
  end

  local task = opts.prompt or ''
  if task:match('^%s*$') then
    on_done(false, nil, 'empty task')
    return nil
  end
  local clipped = M.clip(task, M.MAX_TASK_BYTES)
  table.insert(argv, clipped)

  local cwd = opts.cwd or vim.fn.getcwd()
  local label = opts.label or 'DSH headless task'
  local timeout = opts.timeout_ms or (10 * 60 * 1000)
  local settled = false

  local function finish(ok, text, err)
    if settled then return end
    settled = true
    on_done(ok, text, err)
  end

  local ok, sys = pcall(vim.system, argv, {
    cwd = cwd,
    text = true,
    timeout = timeout,
  }, function(res)
    vim.schedule(function()
      local out = M.join_output(res.stdout)
      local errout = M.join_output(res.stderr)
      if res.code ~= 0 then
        local message = errout
        if message == '' then message = out end
        if message == '' then message = ('exit code %s'):format(tostring(res.code)) end
        if res.signal and res.signal ~= 0 then
          message = message .. (' (terminated by signal %s — the task probably exceeded the %ds timeout)'):format(
            tostring(res.signal), math.floor(timeout / 1000))
        end
        finish(false, nil, message:sub(1, 4000))
        return
      end
      finish(true, out, nil)
    end)
  end)

  if not ok or not sys then
    finish(false, nil, ('failed to spawn `%s`: %s'):format(table.concat(argv, ' '), tostring(sys)))
    return nil
  end

  local handle = {
    argv = argv,
    job = sys,
    clipped = #clipped < byte_len(task),
    cancel = function()
      pcall(function() sys:kill(9) end)
      finish(false, nil, 'cancelled')
    end,
  }
  table.insert(jobs, handle)
  if handle.clipped then
    vim.schedule(function()
      util().notify('the request was too large for one command line and was truncated; '
        .. 'results may be less complete', vim.log.levels.WARN)
    end)
  end
  pcall(function()
    util().notify(('%s started (this can take a minute)'):format(label), vim.log.levels.INFO)
  end)
  return handle
end

---High-level: ask the harness to document a project from a prepared digest.
---
---The digest is written to a file inside the project and the agent is asked to
---read it. That keeps the argv task short (the headless profile takes the task
---only through argv) and lets the harness read a digest of any size with its own
---file tools.
---@param request { root:string, prompt:string, context:string, model:string|nil, max_files:integer|nil }
---@param on_done fun(ok:boolean, text:string|nil, err:string|nil)
function M.analyze(request, on_done)
  if type(request) ~= 'table' then
    on_done(false, nil, 'invalid request')
    return nil
  end

  local root = request.root or vim.fn.getcwd()
  local dir = root .. '/.dshstudio'
  pcall(vim.fn.mkdir, dir, 'p')
  local digest_path = ('%s/digest-%d.md'):format(dir, math.floor(uv.hrtime() / 1e6))
  if not util().write_file(digest_path, request.context or '') then
    -- Fall back to an inline digest when the project is read-only.
    digest_path = nil
  end

  local instructions = table.concat({
    request.prompt or 'Analyze this project and describe its architecture.',
    '',
    digest_path
      and ('The static project digest is in the file `%s`. Read it first with your file tools.'):format(digest_path)
      or 'The static project digest follows at the end of this message.',
    'Answer using only what the digest supports; do not invent files or symbols.',
    '',
    'Cover, in this order:',
    '1. Overall architecture and the role of each top-level module.',
    '2. Data flow between modules (who calls whom, what is shared).',
    '3. The most important subroutines/functions and what they are responsible for.',
    '4. Coupling and cohesion risks, plus duplicated or dead-looking code.',
    '5. Concrete, prioritized suggestions for refactoring or documentation.',
    '',
    'Output Markdown with headings and bullet lists. Write in Chinese.',
    'Keep it under 1200 words. Do not repeat the digest back verbatim.',
    'Do not modify any file in the repository.',
  }, '\n')

  if not digest_path then
    local footer = '\n\n--- END PROJECT DIGEST ---\n'
    local budget = M.MAX_TASK_BYTES - #instructions - #footer - 64
    if budget < 2000 then budget = 2000 end
    instructions = instructions .. '\n\n--- BEGIN PROJECT DIGEST ---\n\n'
      .. M.clip(request.context or '', budget) .. footer
  end

  return M.run({
    prompt = instructions,
    cwd = root,
    timeout_ms = 15 * 60 * 1000,
    label = 'project analysis',
    on_done = on_done,
  })
end

---Self-check: confirm the CLI is reachable and the headless profile answers.
---@param on_done fun(ok:boolean, text:string|nil, err:string|nil)
function M.self_check(on_done)
  local argv, how = M.resolve_argv('headless')
  if not argv then
    on_done(false, nil, 'CLI not found (' .. tostring(how) .. ')')
    return nil
  end
  return M.run({
    prompt = 'Reply with exactly: DSH_OK',
    timeout_ms = 120000,
    label = 'harness self check',
    on_done = on_done,
  })
end

---Cancel every running one-shot job.
function M.cancel_all()
  for _, h in ipairs(jobs) do
    if h.cancel then pcall(h.cancel) end
  end
  jobs = {}
end

function M.running()
  return #jobs
end

return M
