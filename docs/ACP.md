# The ACP wire contract used by the DeepSeek panel

This is the protocol reference that `lua/dshstudio/core/acp.lua` and
`lua/dshstudio/core/session.lua` implement. It was derived from the installed
packages and then **confirmed against a live agent** while building this editor;
where the two disagreed, the live observation is recorded here.

Ground truth: `@agentclientprotocol/sdk@1.4.0`, `@deepseek-ai/dsh-acp@0.1.5-rc.3`,
and the shipped profile `@deepseek-ai/dsh-acp-app/cordis.patch.yml`.

If you change the bridge, re-verify the points marked **CONFIRMED**.

---

## 1. Transport

**CONFIRMED: newline-delimited JSON-RPC 2.0, not `Content-Length` framing.**

- One compact JSON object per line, terminated by `\n` (0x0A). No blank separator
  line, no BOM, no preamble.
- Stdout carries **only** protocol frames. Diagnostics go to stderr.
- No initial handshake bytes: the first thing written is the `initialize` request.
- `session/cancel` and `session/update` are notifications (no `id`).
- Inbound lines are trimmed, so CRLF is tolerated; emit bare `\n` anyway.
- One JSON value per line: ACP v1 sets `allowBatches: false`, so a JSON-RPC batch
  array is a protocol violation.
- **stdin EOF shuts the agent down.** Keep stdin open for the life of the session.

The client therefore buffers stdout and splits on `\n` itself: a frame may be
split across chunks, or several frames may arrive in one chunk. `acp.lua` keeps a
string buffer and drains complete lines, and the self-tests cover exactly those
two cases.

## 2. `initialize`

Request:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true}},"clientInfo":{"name":"dshstudio","version":"0.1.0"}}}
```

`protocolVersion` is the number `1` and is the only required field. The agent
**ignores** the params (`async initialize(_params)`), so the response does not
depend on what the client advertises.

**CONFIRMED response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"deepseek-harness-acp","version":"0.0.1"},"agentCapabilities":{"mcpCapabilities":{"http":true},"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"sessionCapabilities":{"close":{},"list":{},"resume":{}}},"authMethods":[]}}
```

Notes:
- `authMethods` is `[]` — there is no authentication step in this profile.
- `loadSession`, `sessionCapabilities.delete`, `providers`, `nes` and
  `positionEncoding` are deliberately absent. Do not rely on them.
- **No model list here.** Models are per-session (see §6).

## 3. `session/new`

```json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"C:\\work\\repo","mcpServers":[]}}
```

- `cwd` must be **absolute**; a relative path returns `-32602`
  `cwd must be an absolute path: <cwd>`.
- `mcpServers` is **required** (pass `[]`). Non-empty `additionalDirectories`
  returns `-32602 additionalDirectories is not supported`.

**CONFIRMED response** — exactly `{sessionId, configOptions}`, with no `modes`,
no `models` and no `_meta`:

```json
{"jsonrpc":"2.0","id":2,"result":{"sessionId":"e63db16c-c970-4565-a2df-630caa45eeed","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"[\"deepseek-official\",\"deepseek-v4-flash\"]","options":[{"group":"deepseek-official","name":"DeepSeek","options":[{"value":"[\"deepseek-official\",\"deepseek-v4-flash\"]","name":"DeepSeek-V4-Flash"}]},{"group":"xiaomi","name":"xiaomi","options":[{"value":"[\"xiaomi\",\"mimo-v2.5-pro\"]","name":"MiMo-V2.5-Pro"}]}]},{"id":"reasoning_effort","name":"Reasoning effort","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"off","name":"Off"},{"value":"low","name":"Low"},{"value":"high","name":"High"},{"value":"max","name":"Max"}]}]}}
```

`sessionId` is a fresh UUID. Option order is not guaranteed beyond the shipped
profile placing `model` first.

## 4. `session/prompt`

```json
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"<sid>","prompt":[{"type":"text","text":"Explain this function."}]}}
```

One in-flight prompt per session; the whole batch is validated before queueing, so
one bad block fails the request with `-32602`.

Content block variants:

| `type` | required fields |
|---|---|
| `text` | `text` |
| `image` | `data` (base64), `mimeType` — only when `promptCapabilities.image` is true |
| `audio` | `data`, `mimeType` — **unsupported by this agent** |
| `resource_link` | `name`, `uri` |
| `resource` | `resource` — **unsupported by this agent** (`embeddedContext: false`) |

This profile always accepts `text` and `resource_link`. It never accepts `audio`
or `resource`.

**CONFIRMED response:**

```json
{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
```

`stopReason` is one of `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`,
`cancelled` — but in practice this profile only ever emits `end_turn`,
`max_tokens` or `cancelled`. Note that an aborted turn maps to `end_turn` while an
interrupted one maps to `cancelled`, so **do not use `stopReason` alone to detect a
user cancellation**; track cancellation client-side (this editor does).

The response is always the **last** frame of a turn: it settles only after the
agent is idle and all ordered updates are delivered.

## 5. `session/update` notifications

Envelope: method `session/update`, params `{sessionId, update}` where `update` is
discriminated by `sessionUpdate`.

Variants this agent actually emits: `agent_message_chunk`, `agent_thought_chunk`,
`tool_call`, `tool_call_update`, `usage_update`, `config_option_update`.
Treat anything else as unknown and ignore it — never crash on a new discriminator.

**CONFIRMED — streaming text.** Chunks are committed per block (not raw provider
deltas) and every chunk of one message shares a `messageId`. Concatenate in arrival
order and start a new message when `messageId` changes:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"agent_message_chunk","messageId":"49e5e638-...","content":{"type":"text","text":"PONG"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"agent_thought_chunk","messageId":"1c562cf3-...","content":{"type":"text","text":"The user asked me to..."}}}}
```

**CONFIRMED — tool calls.** `tool_call` carries `kind: "other"` and
`status: "in_progress"` hardcoded, `title` = tool name, `rawInput` = the parsed
arguments; there are **no `locations`**. The follow-up `tool_call_update` carries
the terminal `status` and the output:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"tool_call","toolCallId":"call_00_ET_...","title":"glob","kind":"other","status":"in_progress","rawInput":{"pattern":"*"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_00_ET_...","status":"completed","content":[{"type":"content","content":{"type":"text","text":"a.f90\nb.f90\n"}}]}}}
```

`status` is `completed` or `failed`. Only the `"content"` arm of `ToolCallContent`
appears (never `diff` or `terminal`).

**CONFIRMED — usage.** Emitted when both a usage total and a context window are
known; `cost` is never set:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"usage_update","used":7802,"size":1000000}}}
```

`config_option_update` carries the **complete** replacement `configOptions` array
and arrives when the model topology changes (for example a provider's catalogue
becomes available). Replace, do not merge.

## 6. Model and reasoning-effort selection

Selection is a session config option, advertised in `session/new` and changed
with `session/set_config_option`. It is **not** a field on `session/new` or
`session/prompt`.

- `configOptions[].id == "model"`, `type: "select"`, `category: "model"`, options
  grouped per provider as `{group, name, options: [{value, name, description?}]}`.
- **Every model option's `value` is `JSON.stringify([provider, model])`** — a JSON
  array encoded as a **string**, e.g. the literal text
  `["deepseek-official","deepseek-v4-flash"]`. Always echo back a value you were
  given; never construct one.
- `configOptions[].id == "reasoning_effort"`, `category: "thought_level"`, values
  `off` / `low` / `high` / `max`. `currentValue: ""` means "provider default" and is
  offered only when the model declares no default effort.

**CONFIRMED setter** — `configId` (not `optionId`) and a **string** `value`:

```json
{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"<sid>","configId":"model","value":"[\"deepseek-official\",\"deepseek-v4-pro\"]"}}
```

Live observations that cost real debugging time:

| Attempt | Result |
|---|---|
| `value: ["deepseek-official","deepseek-v4-pro"]` (raw array) | `-32602 Invalid params` — `expected boolean/string, received array` |
| `value: '[\"deepseek-official\",\"deepseek-v4-pro\"]'` (string) | **works** |
| `value: 'max'` for `reasoning_effort` | **works** |
| `optionId` instead of `configId` | `-32602` — `configId: expected string, received undefined` |
| unknown `configId` | `-32602 unknown session config option: nope` |
| unknown model value | `-32602 unknown model option: [...]` |

The successful response returns the **full** `{configOptions}`. The shipped profile
also drops untouched options from that reply, so a client that caches the previous
`model` must re-insert it when the reply omits it (this editor does).

A prompt snapshots the selection before the turn starts; a change made while a turn
runs applies to the **next** turn.

### Credentials

Selecting a model whose provider is not signed in is accepted by
`set_config_option` but fails at the next prompt:

```
-32603 Internal error: turn failed: 401: {"message":"Invalid API Key", ...}
```

The panel detects this pattern and appends a hint pointing at the model picker.
This is why the editor surfaces the stderr tail and never leaves a request hanging.

## 7. Client callbacks

**The client must implement exactly one method: `session/request_permission`.**
This agent never calls `fs/*`, `terminal/*`, `elicitation/*` or `mcp/*` even when
the client advertises them.

```json
{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"<sid>","toolCall":{"toolCallId":"call_00_..."},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}
```

- `optionId` uses **hyphens** (`allow-once`), `kind` uses **underscores**
  (`allow_once`). These are the only two options; there is no `allow_always`.
- Result — note the deliberate double `outcome`:

```json
{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}
{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"cancelled"}}}
```

Anything other than `allow-once` is treated as a rejection.

**The agent blocks with no server-side timeout.** A client that never answers
leaves the turn stuck until the request's abort signal fires (session cancel,
close, or connection loss), which resolves it as `cancelled`. Always answer
promptly, and answer `cancelled` for every pending permission request when you
send `session/cancel`.

## 8. Cancel, close, list and resume

`session/cancel` is a **notification** (no response):

```json
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"<sid>"}}
```

It cancels the in-flight prompt (which then settles with `cancelled`, or sometimes
`end_turn`) or the agent's autonomous work. An unknown session id is a silent no-op.

`session/close` is a **request** returning `{}`; the session stays persisted and
listable:

```json
{"jsonrpc":"2.0","id":8,"method":"session/close","params":{"sessionId":"<sid>"}}
```

**CONFIRMED** `session/list` returns only `{sessionId, cwd}` per entry, newest
first, excluding active sessions — no titles or timestamps:

```json
{"jsonrpc":"2.0","id":9,"method":"session/list","params":{}}
{"jsonrpc":"2.0","id":9,"result":{"sessions":[{"sessionId":"e63db16c-...","cwd":"C:\\Users\\1\\Desktop"}]}}
```

`session/resume` takes `{sessionId, cwd, mcpServers?}` where `cwd` must match the
persisted workspace, and responds with `{configOptions}` only — **no `sessionId`
echo and no history replay**. Errors are `-32602`: `session is already active`,
`session is not resumable`, or `session cwd does not match`.

## 9. Errors

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"cwd must be an absolute path: x","data":{}}}
```

| code | meaning |
|---|---|
| `-32700` | parse error |
| `-32600` | invalid request |
| `-32601` | method not found (unregistered methods such as `session/load`, `session/delete`, `session/fork`, session-level `set_mode`, `providers/*`) |
| `-32602` | invalid params — the agent's main caller-error code |
| `-32603` | internal error (takes precedence for turn failures, e.g. the `401` above) |
| `-32800` | request cancelled |
| `-32000` | auth required (never emitted by this profile) |
| `-32002` | resource not found |

Note that a turn-level failure (including provider `401`) is reported as
`-32603 Internal error: turn failed: ...`, not as a prompt result. Treat any
prompt error as a turn failure and surface `message` verbatim.

## 10. What this editor does differently

Design decisions that follow from the above, all visible in the code:

- **Cancellation is tracked client-side** (`state.cancelled_turns`) because
  `stopReason` is ambiguous, and pending permission requests are answered
  `cancelled` while it is set.
- **Pending requests are failed on agent exit** instead of hanging, and the last
  stderr line is appended to the error — that is how `401 Invalid API Key` becomes
  a readable message.
- **The model reply is re-normalised** when `set_config_option` omits the `model`
  option from its returned set.
- **Unknown `sessionUpdate` discriminators are ignored**, so a future agent version
  cannot break the stream.
- **Long turns use a 15-minute request timeout** with an explicit cancel path,
  because the agent itself imposes no approval deadline.
- **Headless work passes the task through argv**, because this profile rejects a
  piped stdin task with `error: a task is required`; large digests are therefore
  written to a file that the agent reads with its own tools.
