---HTTP/SSE client for opencode server.
---
---Communicates with a configured opencode HTTP API and subscribes to
---Server-Sent Events (SSE) for file change notifications.
local M = {}

--- Tracks the current SSE connection state. Only one connection at a time.
local sse_state = {
  url = nil,
  ---@type number|nil
  job_id = nil,
  connected = false,
}

--- Timer to detect connection loss. Reset on every received event.
local heartbeat_timer = assert(vim.uv.new_timer(), "Failed to create heartbeat timer")

--- Timeout slightly longer than server's 30s heartbeat interval to allow for latency.
local HEARTBEAT_TIMEOUT_MS = 35000

---@return { username: string, password: string }|nil
local function auth()
  return require("opencode.config").get_auth()
end

---@param command string[]
local function add_auth(command)
  local value = auth()
  if not value then
    return
  end

  table.insert(command, "-u")
  table.insert(command, value.username .. ":" .. value.password)
end

---@param base string
---@param path string
---@return string
local function endpoint(base, path)
  return base:gsub("/$", "") .. path
end

---@param url string
---@param method string
---@param body table|nil
---@param callback fun(response: table)|nil
---@return number job_id
local function curl(url, method, body, callback)
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

---@param url string
---@param method string
---@param body table|nil
---@param callback fun(err: string|nil, response: table|string|nil, status: integer|nil)|nil
---@return vim.SystemObj
local function request_json(url, method, body, callback)
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

---Call an opencode server endpoint.
---@param url string
---@param path string
---@param method "GET"|"POST"
---@param body table|nil
---@param callback fun(response: table)|nil
---@return number job_id
function M.call(url, path, method, body, callback)
  return curl(endpoint(url, path), method, body, callback)
end

---@class opencode.PathResponse
---@field directory string
---@field worktree string

---Get the server's working directory (synchronous).
---@param url string
---@return opencode.PathResponse
function M.get_path(url)
  local command = {
    "curl",
    "-s",
    "--connect-timeout",
    "1",
  }
  add_auth(command)
  table.insert(command, endpoint(url, "/path"))

  local curl_result = vim.system(command):wait()
  require("opencode.util").check_system_call(curl_result, "curl")

  local ok, data = pcall(vim.fn.json_decode, curl_result.stdout)
  if ok and (data.directory or data.worktree) then
    return data
  end

  error("Failed to parse `opencode` path data: " .. curl_result.stdout, 0)
end

---Execute a TUI command through the shared backend event bus.
---
---This is global to all TUI clients attached to the same server. Prefer local
---terminal control for commands scoped to one embedded TUI.
---@param url string
---@param command string
---@param callback? fun(response: table)
function M.execute_command(url, command, callback)
  M.call(url, "/tui/publish", "POST", { type = "tui.command.execute", properties = { command = command } }, callback)
end

---Send prompt parts directly to a session.
---@param url string
---@param session_id string
---@param parts table[]
---@param callback? fun(err: string|nil, response: table|string|nil, status: integer|nil)
function M.prompt_async(url, session_id, parts, callback)
  return request_json(endpoint(url, "/session/" .. session_id .. "/prompt_async"), "POST", { parts = parts }, callback)
end

---@class opencode.Event
---@field type string
---@field properties table

---Subscribe to SSE events from the opencode server.
---@param url string
---@param callback? fun(event: opencode.Event)
function M.sse_subscribe(url, callback)
  if sse_state.url == url and sse_state.connected then
    return
  end

  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end

  local first_event = true
  sse_state = {
    url = url,
    connected = false,
    job_id = M.call(url, "/event", "GET", nil, function(response)
      if first_event then
        first_event = false
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
    end),
  }
end

---Unsubscribe from SSE events (clean shutdown, no auto-reconnect).
function M.sse_unsubscribe()
  heartbeat_timer:stop()

  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end

  local was_connected = sse_state.connected
  sse_state = { url = nil, job_id = nil, connected = false }

  if was_connected then
    vim.notify("SSE disconnected", vim.log.levels.INFO, { title = "opencode" })
    vim.api.nvim_exec_autocmds("User", {
      pattern = "OpencodeEvent:server.disconnected",
      data = { event = { type = "server.disconnected" } },
    })
  end
end

---@param reason? string
function M.sse_reconnect(reason)
  local was_connected = sse_state.connected

  heartbeat_timer:stop()
  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end
  sse_state = { url = nil, job_id = nil, connected = false }

  if was_connected then
    vim.notify(
      "SSE connection lost" .. (reason and (": " .. reason) or ""),
      vim.log.levels.WARN,
      { title = "opencode" }
    )
  end

  vim.defer_fn(function()
    M.ensure_subscribed()
  end, 1000)
end

---@param notify_on_error? boolean
function M.ensure_subscribed(notify_on_error)
  require("opencode.server").get_url(function(err, url)
    if err or not url then
      if notify_on_error and err then
        vim.notify("SSE cannot connect: " .. err, vim.log.levels.WARN, { title = "opencode" })
      end
      return
    end
    M.sse_subscribe(url)
  end)
end

---@return boolean
function M.is_connected()
  return sse_state.connected
end

---@return { connected: boolean, url: string|nil }
function M.get_status()
  return {
    connected = sse_state.connected,
    url = sse_state.url,
  }
end

return M
