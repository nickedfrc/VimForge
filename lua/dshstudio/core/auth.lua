-- dshstudio/core/auth.lua
--
-- Model providers and API keys, implemented the harness' own way.
--
-- There is no editor-private key store here on purpose. The harness already owns
-- this problem, and duplicating it would mean two sources of truth and a key the
-- user cannot find later. Everything goes through the official places:
--
--   * Secrets  -> `$DSH_HOME/.credentials.yaml`, the `refs:` section, which maps
--                 environment-variable names to values. The store watches the
--                 file and reloads on change, so a key saved here is usable by
--                 the very next request without restarting anything.
--   * Providers -> `$DSH_HOME/settings.yaml`. The shipped composition routes
--                 DeepSeek and Xiaomi; further providers are declared as pi-ai
--                 routes with an `apiKeyEnv` credential reference, or arrive
--                 through ambient provider discovery.
--
-- Two credential facts from the harness documentation shape the design:
--   * Precedence is launch environment, then the stored file, then the project
--     `.env`, then the harness-home `.env`. So an environment variable you export
--     deliberately still wins over anything written here.
--   * `describe` reports whether a key is configured, where it comes from and
--     whether it is writable, and never the value. This module only ever shows
--     that, plus a masked confirmation of what the user just typed.
--
-- SECURITY: the harness runs agent tool processes as the same OS user, so an API
-- key the agent can use is a key the agent can read. File permissions cannot
-- isolate the two. Do not store a key with wider scope than you would hand to the
-- agent itself.

local M = {}

local function util()
  local ok, mod = pcall(require, 'dshstudio.util')
  if ok then return mod end
  return {
    notify = function(msg, level) vim.notify(msg, level, { title = 'DSH Studio' }) end,
    read_file = function(path)
      local fh = io.open(path, 'r')
      if not fh then return nil end
      local data = fh:read('*a')
      fh:close()
      return data
    end,
    write_file = function(path, data)
      local fh = io.open(path, 'w')
      if not fh then return false end
      fh:write(data)
      fh:close()
      return true
    end,
    mkdirp = function(path) pcall(vim.fn.mkdir, path, 'p') end,
  }
end

-- ---------------------------------------------------------------------------
-- Locations
-- ---------------------------------------------------------------------------

---Harness home, honouring DSH_HOME the way the CLI does.
---@return string
function M.harness_home()
  local env = os.getenv('DSH_HOME')
  if env and env ~= '' then return env end
  local home = os.getenv('HOME') or os.getenv('USERPROFILE') or vim.fn.expand('~')
  return home .. '/.dsh'
end

---The harness' credential file (its `refs:` section holds API keys).
---@return string
function M.credentials_path()
  return M.harness_home() .. '/.credentials.yaml'
end

---The harness' settings file (declares providers and the default model).
---@return string
function M.settings_path()
  return M.harness_home() .. '/settings.yaml'
end

-- ---------------------------------------------------------------------------
-- Reading the credential store
-- ---------------------------------------------------------------------------

---Parse the `refs:` section of the credential file.
---
---A narrow line-oriented reader rather than a YAML parser: the section is a flat
---`NAME: value` map, and the store preserves comments and formatting, so an
---in-place line edit is both sufficient and the least invasive option.
---@return table<string, string> refs
function M.read_refs()
  local data = util().read_file(M.credentials_path())
  if not data then return {} end
  local refs = {}
  local in_refs = false
  for line in (data .. '\n'):gmatch('([^\n]*)\n') do
    if line:match('^refs:%s*$') then
      in_refs = true
    elseif line:match('^%S') then
      in_refs = false
    elseif in_refs then
      local name, value = line:match('^%s+([%w_%-%.]+):%s*(.-)%s*$')
      if name and value and value ~= '' then
        value = value:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
        refs[name] = value
      end
    end
  end
  return refs
end

---Set or remove a key in the credential store.
---
---This is the operation the harness' own `ctx.credentials.set`/`unset` performs;
---writing the documented shape directly is what the store's documentation invites
---("you can edit the file directly - the store reloads it automatically").
---Guards: valid POSIX identifier name, non-empty value when setting, a timestamped
---backup before the first change in a session, and a refusal rather than a guess
---when an existing entry cannot be located.
---@param name string   e.g. DEEPSEEK_API_KEY
---@param value string|nil  nil removes the entry
---@return boolean ok
---@return string|nil err
function M.set_key(name, value)
  if type(name) ~= 'string' or not name:match('^[%w_]+$') then
    return false, 'a credential name must be a POSIX identifier, e.g. DEEPSEEK_API_KEY'
  end
  if value ~= nil and (type(value) ~= 'string' or value == '') then
    return false, 'the value must be a non-empty string'
  end

  local path = M.credentials_path()
  local data = util().read_file(path)

  if not data then
    if value == nil then return true, nil end
    util().mkdirp(vim.fn.fnamemodify(path, ':h'))
    if not util().write_file(path, ('version: 1\nrefs:\n  %s: %s\n'):format(name, value)) then
      return false, 'could not write ' .. path
    end
    pcall(vim.fn.setfperm, path, 'rw-------')
    return true, nil
  end

  -- Back up once per session, before the first modification.
  if not M._backed_up then
    util().write_file(path .. '.bak-' .. os.date('%Y%m%d-%H%M%S'), data)
    M._backed_up = true
  end

  local lines = vim.split(data, '\n')
  local refs_start, refs_last, existing
  for i, line in ipairs(lines) do
    if not refs_start then
      if line:match('^refs:%s*$') then refs_start = i end
    elseif line:match('^%s+[%w_%-%.]+:') then
      refs_last = i
      if line:match('^%s+' .. name .. ':%s*') then existing = i end
      -- A comment line directly above an entry is that entry's note; keep it.
    elseif line:match('^%S') then
      break
    elseif line:match('^%s*$') then
      -- Blank line: treat as the end of the contiguous block for insertion but
      -- keep scanning for the key itself.
    end
  end

  if not refs_start then
    while #lines > 0 and lines[#lines] == '' do table.remove(lines) end
    if #lines > 0 and lines[#lines]:match('^%S') then table.insert(lines, '') end
    table.insert(lines, 'refs:')
    if value ~= nil then table.insert(lines, ('  %s: %s'):format(name, value)) end
    table.insert(lines, '')
  elseif existing then
    if value == nil then
      table.remove(lines, existing)
    else
      local indent = lines[existing]:match('^(%s+)') or '  '
      lines[existing] = ('%s%s: %s'):format(indent, name, value)
    end
  elseif value ~= nil then
    table.insert(lines, (refs_last or refs_start) + 1, ('  %s: %s'):format(name, value))
  end

  local out = table.concat(lines, '\n')
  if not out:match('\n$') then out = out .. '\n' end
  if not util().write_file(path, out) then
    return false, 'could not write ' .. path
  end
  pcall(vim.fn.setfperm, path, 'rw-------')
  return true, nil
end

---Where a key currently comes from, using the harness' precedence order.
---@param env_name string
---@return boolean configured
---@return string|nil source   'launch environment' | 'harness store' | '.env file'
function M.describe_key(env_name)
  if not env_name or env_name == '' then return false, nil end
  if (os.getenv(env_name) or '') ~= '' then return true, 'launch environment' end
  local refs = M.read_refs()
  if (refs[env_name] or '') ~= '' then return true, 'harness store' end
  -- The store also consults .env files; report them if present without reading
  -- values, so the panel does not claim a key is missing when it is not.
  local candidates = { vim.fn.getcwd() .. '/.env', M.harness_home() .. '/.env' }
  for _, file in ipairs(candidates) do
    local data = util().read_file(file)
    if data and data:find('^%s*' .. env_name .. '%s*=') then
      return true, '.env file'
    end
  end
  return false, nil
end

-- ---------------------------------------------------------------------------
-- Provider catalogue
-- ---------------------------------------------------------------------------

---Providers the shipped harness composition knows about.
---@return table<string, {label:string, key_env:string, hint:string}>
function M.known_providers()
  return {
    ['deepseek-official'] = {
      label = 'DeepSeek',
      key_env = 'DEEPSEEK_API_KEY',
      hint = 'platform.deepseek.com -> API keys',
    },
    ['xiaomi'] = {
      label = 'Xiaomi (MiMo)',
      key_env = 'XIAOMI_API_KEY',
      hint = 'an apiKeyEnv reference in settings.yaml',
    },
    ['openai'] = { label = 'OpenAI', key_env = 'OPENAI_API_KEY', hint = 'platform.openai.com' },
    ['anthropic'] = {
      label = 'Anthropic',
      key_env = 'ANTHROPIC_API_KEY',
      hint = 'console.anthropic.com',
    },
  }
end

---Providers declared in the user's settings file, as pi-ai routes with an
---`apiKeyEnv` credential reference.
---
---A depth-aware scan of the `llm-pi-ai: providers:` map. Depth is relative to the
---`providers:` line rather than absolute, so the block may be indented however the
---user's file is written. Only the fields this module reports are read; the file
---is never rewritten by the editor.
---@return table[]  { provider, api_key_env, display_name, base_url }
function M.settings_providers()
  local data = util().read_file(M.settings_path())
  if not data then return {} end

  local out = {}
  local in_pi_ai = false
  local base_indent, current = nil, nil

  for line in (data .. '\n'):gmatch('([^\n]*)\n') do
    local stripped = line:gsub('%s+$', '')
    if stripped:match('^%s*$') or stripped:match('^%s*#') then
      -- Blank line or comment: does not end a block.
    else
      local indent = #(stripped:match('^%s*') or '')
      local key = stripped:match('^%s*([%w_%-%.]+):')

      if indent == 0 then
        in_pi_ai = (key == 'llm-pi-ai')
        base_indent, current = nil, nil
      elseif in_pi_ai and not base_indent and key == 'providers' then
        base_indent = indent
      elseif base_indent then
        if indent <= base_indent then
          -- Left the providers map.
          base_indent, current, in_pi_ai = nil, nil, false
        elseif indent == base_indent + 2 then
          -- A provider route name.
          if key then
            current = { provider = key, api_key_env = nil, display_name = nil, base_url = nil }
            table.insert(out, current)
          end
        elseif current and indent >= base_indent + 4 then
          -- A field of the current route.
          local value = stripped:match(':%s*(.-)%s*$')
          if value and value ~= '' then
            value = value:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
            if key == 'apiKeyEnv' then
              current.api_key_env = value
            elseif key == 'displayName' then
              current.display_name = value
            elseif key == 'baseURL' then
              current.base_url = value
            end
          end
        end
      end
    end
  end
  return out
end

---The model this harness uses by default, as recorded in settings.
---@return string|nil provider
---@return string|nil model
function M.default_model()
  local data = util().read_file(M.settings_path())
  if not data then return nil, nil end
  local provider, model
  local in_block = false
  for line in (data .. '\n'):gmatch('([^\n]*)\n') do
    local key = line:match('^%s*([%w_%-%.]+):')
    local indent = #(line:match('^%s*') or '')
    if indent == 0 then
      in_block = (key == 'agent-default-model')
    elseif in_block then
      local value = line:match(':%s*(.-)%s*$')
      if key == 'provider' and value and value ~= '' then provider = value end
      if key == 'model' and value and value ~= '' then model = value end
      if key == 'reasoningEffort' and value and value ~= '' then
        M._settings_reasoning = value
      end
    end
  end
  return provider, model
end

---Providers the agent currently advertises, taken from the live session's model
---options so no extra request is needed.
---@return table[]  { provider, label, models, key_env, key_set, key_source, default }
function M.providers()
  local order, seen = {}, {}
  local ok, session = pcall(require, 'dshstudio.core.session')
  if ok and session.model_choices then
    for _, choice in ipairs(session.model_choices()) do
      local provider = choice.group or 'default'
      if not seen[provider] then
        seen[provider] = { provider = provider, models = {}, key_set = false }
        table.insert(order, seen[provider])
      end
      table.insert(seen[provider].models, {
        name = choice.name,
        value = choice.value,
        description = choice.description,
        current = choice.current,
      })
      if choice.current then seen[provider].current = true end
    end
  end

  local known = M.known_providers()
  local declared = M.settings_providers()
  local declared_by_name = {}
  for _, entry in ipairs(declared) do declared_by_name[entry.provider] = entry end

  -- Providers declared in settings but not yet advertised still belong in the
  -- list: the user added them precisely because they want to use them.
  for _, entry in ipairs(declared) do
    if not seen[entry.provider] then
      seen[entry.provider] = { provider = entry.provider, models = {}, key_set = false, declared = true }
      table.insert(order, seen[entry.provider])
    end
  end

  local default_provider, default_model = M.default_model()
  for _, entry in ipairs(order) do
    local info = known[entry.provider]
    local decl = declared_by_name[entry.provider]
    entry.label = (info and info.label) or (decl and decl.display_name) or entry.provider
    entry.key_env = (decl and decl.api_key_env) or (info and info.key_env)
      or (entry.provider:upper():gsub('[^%w]', '_') .. '_API_KEY')
    entry.hint = info and info.hint or nil
    entry.is_default = (entry.provider == default_provider)
    if entry.is_default then entry.default_model = default_model end
    entry.key_set, entry.key_source = M.describe_key(entry.key_env)
  end
  return order
end

-- ---------------------------------------------------------------------------
-- Interactive management
-- ---------------------------------------------------------------------------

local function mask(value)
  if not value or value == '' then return '' end
  if #value <= 8 then return string.rep('•', #value) end
  return value:sub(1, 3) .. string.rep('•', math.min(10, #value - 6)) .. value:sub(-3)
end

---Render the provider/key report into a scratch buffer.
---@param providers table[]|nil
function M.report(providers)
  local list = providers or M.providers()
  local lines = {
    '# Model providers and API keys',
    '',
    'Keys live in the harness credential store; the editor does not keep its own copy.',
    '',
    '| Provider | Key variable | Key | Source | Models |',
    '| --- | --- | --- | --- | --- |',
  }
  if #list == 0 then
    table.insert(lines, '| _(none advertised yet)_ | | | | |')
  end
  for _, p in ipairs(list) do
    table.insert(lines, ('| %s%s | `%s` | %s | %s | %s |'):format(
      p.label or p.provider,
      p.is_default and ' _(default)_' or '',
      p.key_env,
      p.key_set and 'set' or '**missing**',
      p.key_source or '-',
      #p.models > 0 and tostring(#p.models) or (p.declared and 'declared' or '?')))
  end
  table.insert(lines, '')
  table.insert(lines, ('- Credential store: `%s`'):format(M.credentials_path()))
  table.insert(lines, ('- Settings: `%s`'):format(M.settings_path()))
  if #list == 0 then
    table.insert(lines, '')
    table.insert(lines, 'No providers are known yet. Open the panel once (<leader>dd) so the')
    table.insert(lines, 'agent can advertise its models, or declare a provider in settings.yaml.')
  end
  table.insert(lines, '')
  table.insert(lines, 'Set a key with `:DshAuth`, or choose a model with `<leader>dm`.')
  table.insert(lines, 'Precedence for a key: launch environment, then the store, then `.env`.')

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(100, vim.o.columns - 4),
    height = math.min(#lines + 1, vim.o.lines - 6),
    row = 1,
    col = 2,
    style = 'minimal',
    border = 'rounded',
    title = ' DSH providers ',
  })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
  return buf
end

---Ask for a key and write it into the harness credential store.
---@param provider table
function M.set_provider_key(provider)
  local label = provider.label or provider.provider
  local env_name = provider.key_env
  if not env_name then
    util().notify('no apiKeyEnv is known for ' .. label, vim.log.levels.WARN)
    return
  end

  vim.ui.input({
    prompt = ('%s key (%s) — enter a value, or "remove" to delete it: '):format(label, env_name),
  }, function(input)
    if input == nil then return end
    input = vim.trim(input)
    if input == '' then return end

    if input:lower() == 'remove' then
      local ok, err = M.set_key(env_name, nil)
      if ok then
        util().notify(('removed %s from the harness store'):format(env_name), vim.log.levels.INFO)
      else
        util().notify('could not remove the key: ' .. tostring(err), vim.log.levels.ERROR)
      end
      M.report()
      return
    end

    local ok, err = M.set_key(env_name, input)
    if not ok then
      util().notify('could not save the key: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    util().notify(('%s saved (%s) in the harness store; it applies to the next request'):format(
      env_name, mask(input)), vim.log.levels.INFO)
    M.report()

    -- A newly stored key is picked up on the next request, but the model list was
    -- negotiated when the session opened. Restarting the session makes the new
    -- provider's models appear immediately instead of after an editor restart.
    vim.ui.select({ 'Yes, refresh the session now', 'No, later' }, {
      prompt = 'Reload the harness session so the new credentials take effect?',
    }, function(choice)
      if choice ~= 'Yes, refresh the session now' then return end
      local ok_session, session = pcall(require, 'dshstudio.core.session')
      if not ok_session then return end
      session.close_session(function()
        session.start_session({}, function(started, _sid, start_err)
          if started then
            util().notify('session restarted; the model list is refreshed', vim.log.levels.INFO)
          else
            util().notify('session restart failed: ' .. tostring(start_err), vim.log.levels.WARN)
          end
          local ok_sidebar, sidebar = pcall(require, 'dshstudio.ui.sidebar')
          if ok_sidebar and sidebar.schedule_render then sidebar.schedule_render() end
        end)
      end)
    end)
  end)
end

---Interactive entry point for `:DshAuth [provider]`.
---@param provider_arg string|nil
function M.manage(provider_arg)
  local providers = M.providers()

  if provider_arg and provider_arg ~= '' then
    for _, p in ipairs(providers) do
      if p.provider == provider_arg then
        M.set_provider_key(p)
        return
      end
    end
    util().notify('unknown provider: ' .. provider_arg .. ' (try :DshProviders)',
      vim.log.levels.WARN)
    return
  end

  M.report(providers)

  if #providers == 0 then return end

  local items = {}
  for _, p in ipairs(providers) do
    table.insert(items, {
      entry = p,
      label = ('%-22s key: %-14s %s'):format(
        p.label or p.provider,
        p.key_set and (p.key_source or 'set') or 'NOT SET',
        p.is_default and '(default model)' or ''),
    })
  end
  table.insert(items, { label = 'Show the summary table again', entry = nil })

  vim.ui.select(items, {
    prompt = 'Configure the API key for which provider?',
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice or not choice.entry then return end
    M.set_provider_key(choice.entry)
  end)
end

---Status lines for `:DshHealth`.
---@return string[]
function M.status_lines()
  local lines = {}
  local providers = M.providers()
  lines[#lines + 1] = ('  credential store: %s'):format(M.credentials_path())
  if #providers == 0 then
    lines[#lines + 1] = '  (no providers known yet; open the panel once so the agent can advertise models)'
    return lines
  end
  for _, p in ipairs(providers) do
    lines[#lines + 1] = ('  %-18s key %-12s %-20s %s model%s%s'):format(
      p.provider,
      p.key_set and 'SET' or 'missing',
      p.key_source or '-',
      #p.models,
      #p.models == 1 and '' or 's',
      p.is_default and '  (default)' or '')
  end
  return lines
end

---Short status for the statusline / report.
---@return string
function M.status()
  local providers = M.providers()
  local missing = 0
  for _, p in ipairs(providers) do
    if not p.key_set then missing = missing + 1 end
  end
  if #providers == 0 then return 'providers: unknown' end
  if missing == 0 then return ('providers: %d ok'):format(#providers) end
  return ('providers: %d/%d keyed'):format(#providers - missing, #providers)
end

return M
