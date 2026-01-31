---HTTP/SSE client for opencode server.
---
---Communicates with opencode's HTTP API to append prompts, execute commands,
---and subscribe to Server-Sent Events (SSE) for file change notifications.
---
---SSE Connection Lifecycle:
---  1. ensure_subscribed() - Entry point, gets server port and calls sse_subscribe()
---  2. sse_subscribe(port) - Starts long-running curl job to GET /event endpoint
---  3. On first event received: marks connected, notifies user
---  4. On each event: resets heartbeat timer, fires User autocmd
---  5. If heartbeat times out (no events for 35s): triggers sse_reconnect()
---  6. sse_reconnect() - Cleans up, notifies user, schedules retry after 1s
---
---The server sends a "server.heartbeat" event every 30 seconds. The client's
---35-second timeout provides a 5-second buffer for network latency.
local M = {}

--- Tracks the current SSE connection state. Only one connection at a time.
local sse_state = {
  port = nil,
  ---@type number|nil
  job_id = nil,
  connected = false,
}

--- Timer to detect connection loss. Reset on every received event.
--- If no event arrives within HEARTBEAT_TIMEOUT_MS, connection is presumed dead.
local heartbeat_timer = assert(vim.uv.new_timer(), "Failed to create heartbeat timer")

--- Timeout slightly longer than server's 30s heartbeat interval to allow for latency.
local HEARTBEAT_TIMEOUT_MS = 35000

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

  if body then
    table.insert(command, "-d")
    table.insert(command, vim.fn.json_encode(body))
  end

  table.insert(command, url)

  local response_buffer = {}
  local function process_response_buffer()
    if #response_buffer > 0 then
      local full_event = table.concat(response_buffer)
      response_buffer = {}
      vim.schedule(function()
        local ok, response = pcall(vim.fn.json_decode, full_event)
        if ok then
          if callback then
            callback(response)
          end
        else
          vim.notify(
            "Response decode error: " .. full_event .. "; " .. response,
            vim.log.levels.ERROR,
            { title = "opencode" }
          )
        end
      end)
    end
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
          local clean_line = (line:gsub("^data: ?", ""))
          table.insert(response_buffer, clean_line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        process_response_buffer()
      elseif code ~= 18 and code ~= 143 then
        local error_message = "curl command failed with exit code: "
            .. code
            .. "\nstderr:\n"
            .. (#stderr_lines > 0 and table.concat(stderr_lines, "\n") or "<none>")
        vim.notify(error_message, vim.log.levels.ERROR, { title = "opencode" })
      end
    end,
  })
end

---Call an opencode server endpoint.
---@param port number
---@param path string
---@param method "GET"|"POST"
---@param body table|nil
---@param callback fun(response: table)|nil
---@return number job_id
function M.call(port, path, method, body, callback)
  return curl("http://localhost:" .. port .. path, method, body, callback)
end

---@class opencode.PathResponse
---@field directory string
---@field worktree string

---Get the server's working directory (synchronous).
---@param port number
---@return opencode.PathResponse
function M.get_path(port)
  local curl_result = vim
      .system({
        "curl",
        "-s",
        "--connect-timeout",
        "1",
        "http://localhost:" .. port .. "/path",
      })
      :wait()
  require("opencode.util").check_system_call(curl_result, "curl")

  local ok, data = pcall(vim.fn.json_decode, curl_result.stdout)
  if ok and (data.directory or data.worktree) then
    return data
  else
    error("Failed to parse `opencode` CWD data: " .. curl_result.stdout, 0)
  end
end

---Append text to the TUI prompt.
---@param port number
---@param text string
---@param callback? fun(response: table)
function M.append_prompt(port, text, callback)
  M.call(port, "/tui/publish", "POST", { type = "tui.prompt.append", properties = { text = text } }, callback)
end

---Execute a TUI command.
---@param port number
---@param command string
---@param callback? fun(response: table)
function M.execute_command(port, command, callback)
  M.call(port, "/tui/publish", "POST", { type = "tui.command.execute", properties = { command = command } }, callback)
end

---Request opencode to exit (synchronous).
---Triggers the same clean exit path as pressing Ctrl+C in the TUI.
---@param port number
---@return boolean success
function M.exit(port)
  local result = vim
      .system({
        "curl",
        "-s",
        "--connect-timeout",
        "1",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        vim.fn.json_encode({
          type = "tui.command.execute",
          properties = { command = "app.exit" },
        }),
        "http://localhost:" .. port .. "/tui/publish",
      })
      :wait()
  return result.code == 0
end

---@class opencode.Event
---@field type string
---@field properties table

---Subscribe to SSE events from the opencode server.
---
---Starts a long-running curl job to the /event endpoint. The callback is invoked
---for each event received, including "server.heartbeat" events sent every 30s.
---Events are also broadcast via User autocmds (pattern: "OpencodeEvent:{type}").
---
---@param port number
---@param callback? fun(event: opencode.Event)
function M.sse_subscribe(port, callback)
  -- Already subscribed to this port
  if sse_state.port == port and sse_state.connected then
    return
  end

  -- Clean up existing subscription
  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end

  local first_event = true
  sse_state = {
    port = port,
    connected = false,
    job_id = M.call(port, "/event", "GET", nil, function(response)
      -- Notify on first event (connection established)
      if first_event then
        first_event = false
        sse_state.connected = true
        vim.notify("SSE connected on port " .. port, vim.log.levels.INFO, { title = "opencode" })
      end

      -- Reset heartbeat timer on any event (including server.heartbeat).
      -- If no event arrives before timeout, assume connection is dead.
      heartbeat_timer:stop()
      heartbeat_timer:start(
        HEARTBEAT_TIMEOUT_MS,
        0,
        vim.schedule_wrap(function()
          M.sse_reconnect("heartbeat timeout")
        end)
      )

      -- Fire autocmd for the event (e.g., "OpencodeEvent:file.changed")
      vim.api.nvim_exec_autocmds("User", {
        pattern = "OpencodeEvent:" .. response.type,
        data = { event = response, port = port },
      })

      if callback then
        callback(response)
      end
    end),
  }
end

---Unsubscribe from SSE events (clean shutdown, no auto-reconnect).
---
---Use this for intentional disconnects. Fires "server.disconnected" autocmd
---but does NOT attempt to reconnect. Contrast with sse_reconnect().
function M.sse_unsubscribe()
  heartbeat_timer:stop()

  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end

  local was_connected = sse_state.connected
  sse_state = { port = nil, job_id = nil, connected = false }

  if was_connected then
    vim.notify("SSE disconnected", vim.log.levels.INFO, { title = "opencode" })
    vim.api.nvim_exec_autocmds("User", {
      pattern = "OpencodeEvent:server.disconnected",
      data = { event = { type = "server.disconnected" } },
    })
  end
end

---Handle unexpected disconnect and schedule reconnection.
---
---Use this for connection failures (e.g., heartbeat timeout). Notifies user
---and automatically retries after 1 second. Contrast with sse_unsubscribe().
---
---@param reason? string Description of why disconnect occurred
function M.sse_reconnect(reason)
  local was_connected = sse_state.connected

  -- Clean up current connection
  heartbeat_timer:stop()
  if sse_state.job_id then
    vim.fn.jobstop(sse_state.job_id)
  end
  sse_state = { port = nil, job_id = nil, connected = false }

  if was_connected then
    vim.notify(
      "SSE connection lost" .. (reason and (": " .. reason) or ""),
      vim.log.levels.WARN,
      { title = "opencode" }
    )
  end

  -- Try to reconnect after a short delay
  vim.defer_fn(function()
    M.ensure_subscribed()
  end, 1000)
end

---Main entry point for establishing SSE connection.
---
---Discovers the server port and subscribes if not already connected.
---Called by toggle()/start() in opencode.lua, and by sse_reconnect() for retries.
---
---@param notify_on_error? boolean Whether to notify on connection failure
function M.ensure_subscribed(notify_on_error)
  require("opencode.server").get_port(function(err, port)
    if err or not port then
      if notify_on_error and err then
        vim.notify("SSE cannot connect: " .. err, vim.log.levels.WARN, { title = "opencode" })
      end
      return
    end
    M.sse_subscribe(port)
  end, false)
end

---Check if SSE is currently connected.
---@return boolean
function M.is_connected()
  return sse_state.connected
end

---Get current SSE connection status.
---@return { connected: boolean, port: number|nil }
function M.get_status()
  return {
    connected = sse_state.connected,
    port = sse_state.port,
  }
end

return M
