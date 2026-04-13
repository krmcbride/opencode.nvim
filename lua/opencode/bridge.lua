---Local HTTP bridge for the embedded OpenCode TUI.
---
---The TUI plugin posts the currently visible session back to this Neovim
---instance so Lua can target the active session with direct API requests.
local M = {}

local state = {
  server = nil,
  url = nil,
  token = nil,
  instance_id = nil,
  route = "home",
  session_id = nil,
}

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

---@param body string
---@return string|nil
local function decode_chunked(body)
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

---@param body string
---@return table<string, any>|nil
local function decode_json_body(body)
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

---@param client uv_tcp_t
---@param status integer
---@param body string
local function respond(client, status, body)
  local text = body or ""
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

---@param payload table<string, any>
local function update_state(payload)
  state.route = payload.route == "session" and "session" or "home"
  state.session_id = state.route == "session" and payload.sessionID or nil

  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "OpencodeSessionChanged",
      data = {
        route = state.route,
        session_id = state.session_id,
        instance_id = state.instance_id,
      },
    })
  end)
end

---@param request string
---@return integer, string
local function handle_request(request)
  local line = request:match("^([^\r\n]+)")
  if not line then
    return 400, '{"error":"bad request"}'
  end

  local method, target = line:match("^(%u+)%s+([^%s]+)")
  local path = target and normalize_target(target)
  if method ~= "POST" or path ~= "/opencode/session" then
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

  update_state(payload)
  return 200, '{"ok":true}'
end

---@param buffer string
---@return integer|nil, integer|nil, string|nil
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

local function stop_server()
  if state.server then
    state.server:close()
  end
  state.server = nil
end

local function ensure_autocmd()
  if autocmd_registered then
    return
  end

  autocmd_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = stop_server,
  })
end

---@return string
local function generate_id()
  return tostring(vim.fn.getpid()) .. "-" .. tostring(vim.uv.hrtime())
end

---@return table<string, string>
function M.ensure()
  if state.server and state.url and state.token and state.instance_id then
    return {
      OPENCODE_NVIM_BRIDGE_URL = state.url,
      OPENCODE_NVIM_BRIDGE_TOKEN = state.token,
      OPENCODE_NVIM_INSTANCE_ID = state.instance_id,
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
  state.server = server
  state.token = generate_id()
  state.instance_id = generate_id()
  state.url = "http://127.0.0.1:" .. tostring(socket.port) .. "/opencode/session"

  ensure_autocmd()

  return {
    OPENCODE_NVIM_BRIDGE_URL = state.url,
    OPENCODE_NVIM_BRIDGE_TOKEN = state.token,
    OPENCODE_NVIM_INSTANCE_ID = state.instance_id,
  }
end

---@return { url: string|nil, route: string, session_id: string|nil, instance_id: string|nil }
function M.get_state()
  return {
    url = state.url,
    route = state.route,
    session_id = state.session_id,
    instance_id = state.instance_id,
  }
end

return M
