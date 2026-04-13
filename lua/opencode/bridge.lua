---Local HTTP bridge between the embedded OpenCode TUI process and Neovim.
---
---This is not the backend API client.
---
---Flow overview:
---
---  Neovim Lua                  child `opencode attach` TUI
---  (this plugin)               + bundled `opencode-plugin/tui.ts`
---       ^                                   |
---       |  localhost HTTP POST              |
---       +---------(this module)-------------+
---
---  Separate path:
---  Neovim Lua  <---- HTTP/SSE ---->  OpenCode backend
---
---The embedded `opencode attach` terminal runs in a child process, so it cannot
---call Neovim Lua directly. Instead, the bundled TUI plugin
---(`opencode-plugin/tui.ts`) reads bridge env vars, posts JSON payloads to a
---loopback HTTP server owned by this module, and reports:
---1. which TUI route/session is currently visible
---2. the TUI process cwd
---3. selected TUI events that Neovim may want to react to
---
---Active attached-session state is delegated to `opencode.session`.
local M = {}
local constants = require("opencode.constants")
local session = require("opencode.session")
local BRIDGE_PATH = constants.BRIDGE_PATH
local BRIDGE_ENV = constants.BRIDGE_ENV

---@alias opencode.BridgeRoute "home"|"session"

---@class opencode.BridgePayload
---@field token string|nil
---@field instanceID string|nil
---@field route opencode.BridgeRoute|nil
---@field sessionID string|nil
---@field cwd string|nil
---@field kind? "event"|nil
---@field event? opencode.Event

---@class opencode.BridgeRuntimeState
---@field server uv.uv_tcp_t|nil
---@field url string|nil
---@field token string|nil
---@field instance_id string|nil

---@type opencode.BridgeRuntimeState
local state = {
  server = nil,
  url = nil,
  token = nil,
  instance_id = nil,
}

---Normalize the raw HTTP request target to just the bridge path.
---
---Some runtimes may send an absolute-form target like
---`http://127.0.0.1:PORT/opencode/session`; the bridge only cares about the
---path component when matching requests.
---@param target string
---@return string
local function normalize_target(target)
  local absolute = target:match("^https?://[^/]+(/.*)$")
  if absolute then
    return absolute
  end
  if target == "*" then
    return target
  end
  return target
end

---Decode a chunked HTTP request body.
---
---The local bridge server reads raw TCP bytes, so it must handle transfer
---encodings itself when the embedded TUI runtime sends chunked POST bodies.
---@param body string
---@return string|nil
local function decode_chunked(body)
  ---@type string[]
  local out = {}
  local index = 1

  while true do
    local line_end = body:find("\r\n", index, true) or body:find("\n", index, true)
    if not line_end then
      return nil
    end

    local size_text = body:sub(index, line_end - 1):match("^%s*([0-9a-fA-F]+)")
    local size = size_text and tonumber(size_text, 16)
    if not size then
      return nil
    end

    local delimiter = body:sub(line_end, line_end + 1) == "\r\n" and 2 or 1
    local chunk_start = line_end + delimiter
    if size == 0 then
      return table.concat(out)
    end

    local chunk_end = chunk_start + size - 1
    if #body < chunk_end then
      return nil
    end

    table.insert(out, body:sub(chunk_start, chunk_end))
    index = chunk_end + 1

    if body:sub(index, index + 1) == "\r\n" then
      index = index + 2
    elseif body:sub(index, index) == "\n" then
      index = index + 1
    else
      return nil
    end
  end
end

---Decode a JSON object from a sanitized HTTP body candidate.
---
---The bridge is intentionally tolerant here because raw TCP reads may include
---NUL bytes, surrounding whitespace, or extra framing artifacts around the JSON
---object before the request parser has fully normalized the payload.
---@param body string
---@return opencode.BridgePayload|nil
local function decode_json_body(body)
  ---@type string[]
  local candidates = {}

  local cleaned = body:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
  table.insert(candidates, cleaned)

  local start_index = cleaned:find("{", 1, true)
  local end_index
  for i = #cleaned, 1, -1 do
    if cleaned:sub(i, i) == "}" then
      end_index = i
      break
    end
  end
  if start_index and end_index and end_index >= start_index then
    table.insert(candidates, cleaned:sub(start_index, end_index))
  end

  for _, candidate in ipairs(candidates) do
    if candidate ~= "" then
      local ok, decoded
      if vim.json and vim.json.decode then
        ok, decoded = pcall(vim.json.decode, candidate)
      else
        ok, decoded = pcall(vim.fn.json_decode, candidate)
      end
      if ok and type(decoded) == "table" then
        return decoded
      end
    end
  end

  return nil
end

local autocmd_registered = false

---Write a minimal HTTP/1.1 response and close the client socket.
---@param client uv.uv_tcp_t
---@param status integer
---@param body string
local function respond(client, status, body)
  local text = body or ""
  ---@type string[]
  local lines = {
    ("HTTP/1.1 %d %s"):format(status, status == 200 and "OK" or status == 403 and "Forbidden" or "Bad Request"),
    "Content-Type: application/json",
    "Content-Length: " .. #text,
    "Connection: close",
    "",
    text,
  }

  client:write(table.concat(lines, "\r\n"), function()
    client:shutdown(function()
      client:close()
    end)
  end)
end

---Apply a state publish from the embedded TUI.
---
---Regular bridge publishes report the current visible route/session/cwd. The
---session module owns that state and emits `OpencodeSessionChanged` when it
---actually changes.
---@param payload opencode.BridgePayload
local function update_state(payload)
  session.update_active({
    route = payload.route,
    session_id = payload.sessionID,
    cwd = payload.cwd,
    instance_id = state.instance_id,
  })
end

---Forward a selected embedded-TUI event into Neovim `User` autocmds.
---
---These become `OpencodeActiveEvent:<type>` events scoped to the local embedded
---TUI, distinct from backend SSE events emitted by `opencode.client`.
---@param payload opencode.BridgePayload
local function emit_active_event(payload)
  local event = payload.event
  if type(event) ~= "table" or type(event.type) ~= "string" or event.type == "" then
    return
  end

  local current = session.get_state()
  local route = payload.route == "session" and "session" or "home"
  local session_id = type(payload.sessionID) == "string" and payload.sessionID ~= "" and payload.sessionID or nil
  local cwd = payload.cwd or current.cwd

  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "OpencodeActiveEvent:" .. event.type,
      data = {
        event = event,
        route = route,
        session_id = session_id,
        instance_id = state.instance_id,
        cwd = cwd,
      },
    })
  end)
end

---Validate and dispatch one complete bridge request.
---@param request string
---@return integer, string
local function handle_request(request)
  local line = request:match("^([^\r\n]+)")
  if not line then
    return 400, '{"error":"bad request"}'
  end

  local method, target = line:match("^(%u+)%s+([^%s]+)")
  local path = target and normalize_target(target)
  if method ~= "POST" or path ~= BRIDGE_PATH then
    return 400, '{"error":"bad request"}'
  end

  local body = request:match("\r\n\r\n(.*)$") or request:match("\n\n(.*)$") or ""
  local payload = decode_json_body(body)
  if type(payload) ~= "table" then
    return 400, '{"error":"invalid json"}'
  end

  if payload.token ~= state.token or payload.instanceID ~= state.instance_id then
    return 403, '{"error":"forbidden"}'
  end

  if payload.kind == "event" then
    if type(payload.event) ~= "table" or type(payload.event.type) ~= "string" then
      return 400, '{"error":"invalid event"}'
    end

    emit_active_event(payload)
    return 200, '{"ok":true}'
  end

  update_state(payload)

  return 200, '{"ok":true}'
end

---Try to extract one complete HTTP request from the accumulated TCP buffer.
---
---The embedded TUI runtime may send:
---1. a normal `Content-Length` request
---2. a chunked request body
---3. a simple body we can validate as raw JSON once headers are present
---@param buffer string
---@return integer|nil body_start
---@return integer|nil content_length
---@return string|nil request
local function parse_request(buffer)
  local header_end, delimiter_length = buffer:find("\r\n\r\n", 1, true), 4
  if not header_end then
    header_end, delimiter_length = buffer:find("\n\n", 1, true), 2
  end
  if not header_end then
    return nil, nil, nil
  end

  local headers = buffer:sub(1, header_end + delimiter_length - 1)
  local body_start = header_end + delimiter_length
  local content_length = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
  if content_length then
    return body_start, content_length, buffer:sub(1, body_start + content_length - 1)
  end

  local transfer_encoding = headers:match("[Tt]ransfer%-[Ee]ncoding:%s*([^\r\n]+)")
  if transfer_encoding and transfer_encoding:lower():find("chunked", 1, true) then
    local decoded = decode_chunked(buffer:sub(body_start))
    if not decoded then
      return nil, nil, nil
    end
    local request = headers .. decoded
    return body_start, #decoded, request
  end

  local request = buffer
  local ok = pcall(vim.fn.json_decode, request:sub(body_start))
  if ok then
    return body_start, #request:sub(body_start), request
  end

  return nil, nil, nil
end

---Stop the loopback bridge server.
local function stop_server()
  if state.server then
    state.server:close()
  end
  state.server = nil
end

---Register one shutdown autocmd for bridge cleanup.
local function ensure_autocmd()
  if autocmd_registered then
    return
  end

  autocmd_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = stop_server,
  })
end

---Generate a process-local identifier for bridge auth/state correlation.
---@return string
local function generate_id()
  return tostring(vim.fn.getpid()) .. "-" .. tostring(vim.uv.hrtime())
end

---Ensure the local bridge server exists and return env vars for the child TUI.
---
---`opencode.terminal` injects these values into the `opencode attach` process.
---The bundled TUI plugin reads them and POSTs state/event payloads back to this
---bridge server.
---@return table<string, string>
function M.ensure()
  if state.server and state.url and state.token and state.instance_id then
    return {
      [BRIDGE_ENV.URL] = state.url,
      [BRIDGE_ENV.TOKEN] = state.token,
      [BRIDGE_ENV.INSTANCE_ID] = state.instance_id,
    }
  end

  local server = assert(vim.uv.new_tcp(), "Failed to create OpenCode bridge server")
  server:bind("127.0.0.1", 0)
  server:listen(16, function(err)
    if err then
      vim.schedule(function()
        vim.notify("OpenCode bridge error: " .. err, vim.log.levels.ERROR, { title = "opencode" })
      end)
      return
    end

    local client = assert(vim.uv.new_tcp(), "Failed to accept OpenCode bridge connection")
    server:accept(client)

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err then
        client:read_stop()
        respond(client, 400, '{"error":"read error"}')
        return
      end

      if not chunk then
        client:read_stop()
        respond(client, 400, '{"error":"incomplete request"}')
        return
      end

      buffer = buffer .. chunk

      local body_start, content_length, request = parse_request(buffer)
      if not body_start or not content_length or not request then
        return
      end

      local body = buffer:sub(body_start)
      if #body < content_length then
        return
      end

      client:read_stop()
      local status, response_body = handle_request(request)
      respond(client, status, response_body)
    end)
  end)

  local socket = server:getsockname()
  local port = socket and socket.port or nil
  assert(port, "Failed to determine OpenCode bridge port")
  state.server = server
  state.token = generate_id()
  state.instance_id = generate_id()
  state.url = "http://127.0.0.1:" .. tostring(port) .. BRIDGE_PATH

  ensure_autocmd()

  return {
    [BRIDGE_ENV.URL] = state.url,
    [BRIDGE_ENV.TOKEN] = state.token,
    [BRIDGE_ENV.INSTANCE_ID] = state.instance_id,
  }
end

---Return the local bridge URL for diagnostics and status reporting.
---
---This is the loopback endpoint consumed by the embedded TUI plugin, not the
---OpenCode backend server URL configured in `opencode.config`.
---@return string|nil
function M.get_url()
  return state.url
end

return M
