---HTTP/SSE client for opencode server.
---
---This module owns communication with the OpenCode backend server.
---
---It has two closely related responsibilities:
---1. one-shot JSON requests to backend HTTP endpoints
---2. a long-lived SSE subscription for backend file/edit events
---
---This is distinct from `opencode.bridge`, which is the localhost loopback
---bridge between Neovim and the child `opencode attach` TUI process.
---Attached-session state lives in `opencode.session`.
local M = {}
local config = require("opencode.config")
local session = require("opencode.session")
local util = require("opencode.util")

---@class opencode.ClientAuth
---@field username string
---@field password string

---@class opencode.SseState
---@field url string|nil
---@field directory string|nil Directory scope currently attached to the backend SSE subscription
---@field job_id integer|nil
---@field connected boolean

---@class opencode.PathResponse
---@field directory string
---@field worktree string

---@class opencode.ModelRef
---@field providerID string
---@field modelID string

---@class opencode.PromptAsyncOpts
---@field directory? string Backend directory scope for the request
---@field agent? string
---@field model? opencode.ModelRef
---@field variant? string

---@class opencode.SessionMessagesOpts
---@field directory? string Backend directory scope for the request
---@field limit? integer

---@alias opencode.JsonRequestResponse table|string|nil
---@alias opencode.JsonRequestCallback fun(err: string|nil, response: opencode.JsonRequestResponse, status: integer|nil)

---@return opencode.SseState
local function new_sse_state()
  return {
    url = nil,
    directory = nil,
    job_id = nil,
    connected = false,
  }
end

---Tracks the current backend SSE connection state. Only one subscription at a time.
---@type opencode.SseState
local sse_state = new_sse_state()

---Timer to detect connection loss. Reset on every received event.
---@type uv.uv_timer_t
local heartbeat_timer = assert(vim.uv.new_timer(), "Failed to create heartbeat timer")

---Retry timer used while reconnecting after a disconnect or failed probe.
---@type uv.uv_timer_t
local reconnect_timer = assert(vim.uv.new_timer(), "Failed to create reconnect timer")

---Timeout slightly longer than the server's 10s heartbeat interval.
local HEARTBEAT_TIMEOUT_MS = 15000

---Bounded reconnect backoff. Keep this short so server restarts recover quickly.
local RECONNECT_DELAYS_MS = { 250, 500, 1000, 2000, 3000 }

---Incremented whenever the active SSE transport is replaced or stopped.
---Callbacks from stale transports must not schedule reconnects.
local sse_generation = 0

---Current reconnect attempt count, reset after the stream becomes healthy again.
local reconnect_attempt = 0

---Read backend auth from Neovim's process environment via `opencode.config`.
---@return opencode.ClientAuth|nil
local function auth()
  return config.get_auth()
end

---Add HTTP basic auth flags to a curl command when auth is configured.
---@param command string[]
local function add_auth(command)
  local value = auth()
  if not value then
    return
  end

  table.insert(command, "-u")
  table.insert(command, value.username .. ":" .. value.password)
end

---Append a path to a backend base URL without duplicating `/`.
---@param base string
---@param path string
---@return string
local function endpoint(base, path)
  return base:gsub("/$", "") .. path
end

---Resolve the directory scope the backend SSE stream should subscribe to.
---
---Prefer the active embedded-TUI cwd reported through `opencode.session`. Fall
---back to the configured terminal directory before any session is active.
---@return string|nil
local function subscription_directory()
  local active = session.get_state()
  if active.cwd and active.cwd ~= "" then
    return active.cwd
  end

  local terminal = config.opts.terminal or {}
  local dir = terminal.dir or "."
  return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
end

---Build the SSE endpoint URL, including optional backend directory scoping.
---@param base string
---@return string
local function sse_endpoint(base)
  local url = endpoint(base, "/event")
  local directory = subscription_directory()
  if directory and directory ~= "" then
    url = url .. "?directory=" .. vim.uri_encode(directory)
  end
  return url
end

---@return integer
local function reconnect_delay_ms()
  local index = math.min(reconnect_attempt + 1, #RECONNECT_DELAYS_MS)
  return RECONNECT_DELAYS_MS[index]
end

local function clear_reconnect_state()
  reconnect_timer:stop()
  reconnect_attempt = 0
end

---@param url string|nil
local function emit_disconnected(url)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OpencodeEvent:server.disconnected",
    data = { event = { type = "server.disconnected" }, url = url },
  })
end

---Probe the configured backend with `/path` and return its URL when reachable.
---
---This is used before establishing SSE so we can fail fast with a clearer
---message when the configured backend is unavailable. One-shot JSON request
---helpers use the configured URL directly and surface transport errors there.
---@return string|nil, string|nil
local function get_validated_url()
  local url = config.get_url()
  ---@type string[]
  local command = {
    "curl",
    "-s",
    "--connect-timeout",
    "1",
  }
  add_auth(command)
  table.insert(command, endpoint(url, "/path"))

  local ok, result = pcall(function()
    local curl_result = vim.system(command):wait()
    util.check_system_call(curl_result, "curl")

    local decoded_ok, data = pcall(vim.fn.json_decode, curl_result.stdout)
    if decoded_ok and (data.directory or data.worktree) then
      return data
    end

    error("Failed to parse `opencode` path data: " .. curl_result.stdout, 0)
  end)

  if ok and result then
    return url, nil
  end

  return nil, "No `opencode` responding at configured URL: " .. url
end

---Start a curl process that streams newline-delimited JSON/SSE data.
---
---This helper exists specifically for the backend event stream path used by
---`M.sse_subscribe()`.
---@param url string
---@param method "GET"|"POST"
---@param body table|nil
---@param callback fun(response: opencode.Event)|nil
---@param on_exit? fun(code: integer, stderr_lines: string[])
---@return integer job_id
local function curl(url, method, body, callback, on_exit)
  ---@type string[]
  local command = {
    "curl",
    "-s",
    "--connect-timeout",
    "1",
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-H",
    "Accept: text/event-stream",
    "-N",
  }

  add_auth(command)

  if body then
    table.insert(command, "-d")
    table.insert(command, vim.fn.json_encode(body))
  end

  table.insert(command, url)

  ---@type string[]
  local response_buffer = {}
  local function process_response_buffer()
    if #response_buffer == 0 then
      return
    end

    local full_event = table.concat(response_buffer)
    response_buffer = {}
    vim.schedule(function()
      local ok, response = pcall(vim.fn.json_decode, full_event)
      if ok then
        if callback then
          callback(response)
        end
        return
      end

      vim.notify(
        "Response decode error: " .. full_event .. "; " .. response,
        vim.log.levels.ERROR,
        { title = "opencode" }
      )
    end)
  end

  ---@type string[]
  local stderr_lines = {}
  return vim.fn.jobstart(command, {
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line == "" then
          process_response_buffer()
        else
          table.insert(response_buffer, (line:gsub("^data: ?", "")))
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        process_response_buffer()
      end

      if on_exit then
        on_exit(code, stderr_lines)
        return
      end

      if code ~= 18 and code ~= 143 then
        local error_message = "curl command failed with exit code: "
          .. code
          .. "\nstderr:\n"
          .. (#stderr_lines > 0 and table.concat(stderr_lines, "\n") or "<none>")
        vim.notify(error_message, vim.log.levels.ERROR, { title = "opencode" })
      end
    end,
  })
end

---Build the optional directory-scope header for backend JSON requests.
---@param directory string|nil
---@return table<string, string>|nil
local function directory_headers(directory)
  if not directory or directory == "" then
    return nil
  end

  return {
    ["x-opencode-directory"] = vim.uri_encode(directory),
  }
end

---Issue a one-shot JSON request against the backend HTTP API.
---@param url string
---@param method "GET"|"POST"
---@param body table|nil
---@param headers? table<string, string>
---@param callback opencode.JsonRequestCallback|nil
---@return vim.SystemObj
local function request_json(url, method, body, headers, callback)
  ---@type string[]
  local command = {
    "curl",
    "-sS",
    "--connect-timeout",
    "1",
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-w",
    "\n%{http_code}",
  }

  add_auth(command)

  if headers then
    for key, value in pairs(headers) do
      table.insert(command, "-H")
      table.insert(command, key .. ": " .. value)
    end
  end

  if body then
    table.insert(command, "-d")
    table.insert(command, vim.fn.json_encode(body))
  end

  table.insert(command, url)

  return vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err = "curl command failed with exit code: "
          .. tostring(result.code)
          .. "\nstderr:\n"
          .. ((result.stderr and result.stderr ~= "") and result.stderr or "<none>")
        if callback then
          callback(err, nil, nil)
        end
        return
      end

      local stdout = result.stdout or ""
      local response_text, status_text = stdout:match("^(.*)\n(%d%d%d)%s*$")
      if not status_text then
        response_text = stdout
      end

      local status = tonumber(status_text)
      local decoded = nil
      if response_text and response_text ~= "" then
        local ok, value = pcall(vim.fn.json_decode, response_text)
        decoded = ok and value or response_text
      end

      if status and status >= 200 and status < 300 then
        if callback then
          callback(nil, decoded, status)
        end
        return
      end

      local message = "HTTP request failed"
      if status then
        message = message .. " with status " .. tostring(status)
      end
      if type(decoded) == "table" and decoded.error then
        message = message .. ": " .. tostring(decoded.error)
      elseif type(decoded) == "string" and decoded ~= "" then
        message = message .. ": " .. decoded
      end

      if callback then
        callback(message, decoded, status)
      end
    end)
  end)
end

---Send prompt parts directly to an OpenCode session over the backend API.
---@param session_id string
---@param parts table[]
---@param opts? opencode.PromptAsyncOpts
---@param callback? opencode.JsonRequestCallback
---@return vim.SystemObj|nil
function M.prompt_async(session_id, parts, opts, callback)
  local url = config.get_url()

  local headers = directory_headers(opts and opts.directory or nil)

  local body = { parts = parts }
  if opts and opts.agent then
    body.agent = opts.agent
  end
  if opts and opts.model then
    body.model = opts.model
  end
  if opts and opts.variant then
    body.variant = opts.variant
  end

  return request_json(endpoint(url, "/session/" .. session_id .. "/prompt_async"), "POST", body, headers, callback)
end

---Fetch recent messages for an OpenCode session.
---@param session_id string
---@param opts? opencode.SessionMessagesOpts
---@param callback? opencode.JsonRequestCallback
---@return vim.SystemObj|nil
function M.session_messages(session_id, opts, callback)
  local url = config.get_url()

  local headers = directory_headers(opts and opts.directory or nil)

  local limit = (opts and opts.limit) or 100
  local path = "/session/" .. session_id .. "/message?limit=" .. tostring(limit)
  return request_json(endpoint(url, path), "GET", nil, headers, callback)
end

---@class opencode.Event
---@field type string
---@field properties table<string, any>|nil

---@return boolean was_connected
---@return string|nil previous_url
local function reset_sse_state()
  heartbeat_timer:stop()
  sse_generation = sse_generation + 1

  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end

  local was_connected = sse_state.connected
  local previous_url = sse_state.url
  sse_state = new_sse_state()
  return was_connected, previous_url
end

---@param code integer
---@param stderr_lines string[]
---@return string
local function exit_reason(code, stderr_lines)
  if code == 0 then
    return "stream ended"
  end

  if code == 18 then
    return "stream interrupted"
  end

  if code == 28 then
    return "connect timed out"
  end

  if code == 7 then
    return "connect failed"
  end

  if #stderr_lines > 0 then
    return stderr_lines[#stderr_lines]
  end

  return "curl exited with code " .. tostring(code)
end

local attempt_subscribe

local function schedule_reconnect()
  reconnect_timer:stop()
  local delay = reconnect_delay_ms()
  reconnect_attempt = reconnect_attempt + 1
  reconnect_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      attempt_subscribe(false, false)
    end)
  )
end

---Subscribe to backend SSE events for the current backend directory scope.
---
---The backend stream is directory-scoped, so when the active embedded-TUI cwd
---changes we must re-subscribe with the new `?directory=` query value.
---@param url string
---@param callback? fun(event: opencode.Event)
function M.sse_subscribe(url, callback)
  local directory = subscription_directory()
  if sse_state.url == url and sse_state.directory == directory and (sse_state.connected or sse_state.job_id) then
    return
  end

  if sse_state.job_id then
    reset_sse_state()
  end

  reconnect_timer:stop()

  local first_event = true
  local generation = sse_generation + 1
  sse_generation = generation
  sse_state = {
    url = url,
    directory = directory,
    connected = false,
    job_id = curl(sse_endpoint(url), "GET", nil, function(response)
      if generation ~= sse_generation then
        return
      end

      if first_event then
        first_event = false
        clear_reconnect_state()
        sse_state.connected = true
        vim.notify("SSE connected: " .. url, vim.log.levels.INFO, { title = "opencode" })
      end

      heartbeat_timer:stop()
      heartbeat_timer:start(
        HEARTBEAT_TIMEOUT_MS,
        0,
        vim.schedule_wrap(function()
          M.sse_reconnect("heartbeat timeout")
        end)
      )

      vim.api.nvim_exec_autocmds("User", {
        pattern = "OpencodeEvent:" .. response.type,
        data = { event = response, url = url },
      })

      if callback then
        callback(response)
      end
    end, function(code, stderr_lines)
      vim.schedule(function()
        if generation ~= sse_generation then
          return
        end

        sse_state.job_id = nil
        M.sse_reconnect(exit_reason(code, stderr_lines))
      end)
    end),
  }
end

---Unsubscribe from SSE events (clean shutdown, no auto-reconnect).
function M.sse_unsubscribe()
  local was_connected, previous_url = reset_sse_state()
  clear_reconnect_state()

  if was_connected then
    vim.notify("SSE disconnected", vim.log.levels.INFO, { title = "opencode" })
    emit_disconnected(previous_url)
  end
end

---Reconnect the backend SSE stream after a disconnect or heartbeat timeout.
---@param reason? string
function M.sse_reconnect(reason)
  local was_connected, previous_url = reset_sse_state()

  if was_connected then
    vim.notify(
      "SSE connection lost" .. (reason and (": " .. reason) or ""),
      vim.log.levels.WARN,
      { title = "opencode" }
    )
    emit_disconnected(previous_url)
  end

  schedule_reconnect()
end

---@param notify_on_error? boolean
---@param reset_backoff boolean
attempt_subscribe = function(notify_on_error, reset_backoff)
  reconnect_timer:stop()
  if reset_backoff then
    reconnect_attempt = 0
  end

  local url, err = get_validated_url()
  if err or not url then
    if notify_on_error and err then
      vim.notify("SSE cannot connect: " .. err, vim.log.levels.WARN, { title = "opencode" })
    end
    schedule_reconnect()
    return
  end

  M.sse_subscribe(url)
end

---Ensure the backend SSE subscription is connected for the active directory scope.
---@param notify_on_error? boolean
function M.ensure_subscribed(notify_on_error)
  attempt_subscribe(notify_on_error, true)
end

---Return whether the backend SSE stream is currently marked connected.
---@return boolean
function M.is_connected()
  return sse_state.connected
end

---@class opencode.SseStatus
---@field connected boolean
---@field url string|nil
---@field directory string|nil

---@return opencode.SseStatus
function M.get_status()
  return {
    connected = sse_state.connected,
    url = sse_state.url,
    directory = sse_state.directory,
  }
end

return M
