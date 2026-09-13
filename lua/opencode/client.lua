---OpenCode v2 HTTP client and one process-wide, volatile SSE subscription.
local M = {}
local config = require("opencode.config")
local session = require("opencode.session")
local http = require("opencode.http")
local protocol = require("opencode.protocol")
local sse = require("opencode.sse")

---@class opencode.Event
---@field type string
---@field data table
---@field location? { directory: string, workspaceID?: string }

local state = { connected = false }
local generation, attempt = 0, 0
local heartbeat = assert(vim.uv.new_timer())
local retry = assert(vim.uv.new_timer())
local HEARTBEAT_TIMEOUT_MS = 45000 -- upstream comments arrive every 15 seconds
local DELAYS_MS = { 250, 500, 1000, 2000, 3000 }
local wanted = false
local subscribe

local function endpoint(base, path)
  return base:gsub("/+$", "") .. path
end

local function scope()
  local current = session.get_state()
  current.cwd = current.cwd or vim.fn.fnamemodify((config.opts.terminal or {}).dir or ".", ":p")
  return current
end

local function emit(event, url)
  local current = scope()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OpencodeEvent:" .. event.type,
    data = { event = event, url = url, directory = current.cwd, workspace_id = current.workspace_id },
  })
end

---Fetch authoritative session state for notification/status integrations.
---The callback receives the unwrapped Session.Info (agent/model/location/outcome).
function M.get_session(session_id, callback)
  return http.request(
    endpoint(config.get_url(), "/api/session/" .. vim.uri_encode(session_id)),
    "GET",
    nil,
    function(err, response, status)
      local data = response and response.data
      if not err and (type(data) ~= "table" or data.id ~= session_id) then
        err = "Invalid OpenCode session response"
      end
      callback(err, not err and data or nil, status)
    end
  )
end

---A completed connection is a resync boundary, not replay of missed events.
function M.resync()
  local current, version = scope(), generation
  vim.api.nvim_exec_autocmds("User", { pattern = "OpencodeResync", data = current })
  if not current.session_id then
    return
  end
  M.get_session(current.session_id, function(err, value)
    if err or version ~= generation or session.get_state().session_id ~= current.session_id then
      return
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "OpencodeSessionRefreshed", data = { session = value } })
  end)
end

---Submit once. Success means durable inbox admission, not finished execution.
---A transport error or malformed acknowledgement is never retried automatically.
function M.prompt(session_id, parts, opts, callback)
  opts = opts or {}
  local ok, body = pcall(protocol.prompt, parts, opts.delivery or "queue")
  if not ok then
    vim.schedule(function()
      callback(body, nil, nil)
    end)
    return
  end
  return http.request(
    endpoint(config.get_url(), "/api/session/" .. vim.uri_encode(session_id) .. "/prompt"),
    "POST",
    body,
    function(err, response, status)
      if not err and not protocol.admitted(response, session_id) then
        err = "Invalid OpenCode prompt acknowledgement"
      end
      if err then
        callback(err .. ". Check the TUI before sending again; receipt may be uncertain.", nil, status)
        return
      end
      callback(nil, response.data, status)
    end
  )
end

local function reset()
  generation = generation + 1
  heartbeat:stop()
  retry:stop()
  local old = state
  state = { connected = false }
  if old.process then
    pcall(old.process.kill, old.process, 15)
  end
  if old.probe then
    pcall(old.probe.kill, old.probe, 15)
  end
  return old
end

local function schedule_retry()
  if not wanted then
    return
  end
  local delay = DELAYS_MS[math.min(attempt + 1, #DELAYS_MS)]
  attempt = attempt + 1
  retry:start(
    delay,
    0,
    vim.schedule_wrap(function()
      subscribe(false)
    end)
  )
end

function M.sse_reconnect(reason)
  local old = reset()
  if old.connected then
    vim.notify(
      "OpenCode event stream disconnected" .. (reason and (": " .. reason) or ""),
      vim.log.levels.WARN,
      { title = "opencode" }
    )
    emit({ type = "server.disconnected", data = {} }, old.url)
  end
  schedule_retry()
end

local function watch_heartbeat(version)
  heartbeat:start(
    HEARTBEAT_TIMEOUT_MS,
    0,
    vim.schedule_wrap(function()
      if version == generation then
        M.sse_reconnect("heartbeat timeout")
      end
    end)
  )
end

---Subscribe after a successful v2 health probe. Scope is read for each event;
---switching sessions/locations does not needlessly replace the global stream.
function M.sse_subscribe(url, callback)
  if state.process and state.url == url then
    return
  end
  reset()
  wanted = true
  state.url = url
  local version, warned = generation, false
  local parser = sse.new(function(raw)
    if version ~= generation then
      return
    end
    local ok, value = pcall(vim.json.decode, raw)
    if not ok then
      if not warned then
        warned = true
        vim.notify("Ignoring malformed OpenCode event", vim.log.levels.WARN, { title = "opencode" })
      end
      return
    end
    local event = protocol.event(value, scope())
    if not event then
      return
    end
    emit(event, url)
    if callback then
      callback(event)
    end
  end, function()
    if version ~= generation then
      return
    end
    watch_heartbeat(version)
    if state.connected then
      return
    end
    state.connected = true
    attempt = 0
    vim.notify("OpenCode event stream connected", vim.log.levels.INFO, { title = "opencode" })
    M.resync()
  end)
  local command, input = http.command(endpoint(url, "/api/event"), "GET")
  vim.list_extend(command, { "--fail", "-N", "-H", "Accept: text/event-stream" })
  watch_heartbeat(version) -- also bounds a connected peer that never sends data
  local ok, process = pcall(vim.system, command, {
    stdin = input,
    stdout = function(err, chunk)
      if err or not chunk then
        return
      end
      vim.schedule(function()
        if version == generation then
          parser.feed(chunk)
        end
      end)
    end,
    stderr = function() end, -- curl errors may contain request details
  }, function(result)
    vim.schedule(function()
      if version == generation then
        M.sse_reconnect("curl exit " .. result.code)
      end
    end)
  end)
  if not ok then
    M.sse_reconnect("could not start curl")
    return
  end
  state.process = process
end

subscribe = function(notify_on_error)
  local url = config.get_url()
  if state.url == url and (state.process or state.probe) then
    return
  end
  reset()
  state.url = url
  local version = generation
  state.probe = http.request(endpoint(url, "/api/health"), "GET", nil, function(err, value)
    if version ~= generation or not wanted then
      return
    end
    state.probe = nil
    if err or not protocol.health(value) then
      if notify_on_error then
        vim.notify(
          "OpenCode v2 is required at " .. url .. (err and (": " .. err) or "; incompatible health response"),
          vim.log.levels.WARN,
          { title = "opencode" }
        )
      end
      schedule_retry()
      return
    end
    M.sse_subscribe(url)
  end, 5)
end

function M.ensure_subscribed(notify_on_error)
  wanted = true
  subscribe(notify_on_error)
end

function M.sse_unsubscribe()
  wanted = false
  local old = reset()
  attempt = 0
  if old.connected then
    emit({ type = "server.disconnected", data = {} }, old.url)
  end
end

function M.is_connected()
  return state.connected
end

function M.get_status()
  local current = scope()
  return { connected = state.connected, url = state.url, directory = current.cwd, workspace_id = current.workspace_id }
end

return M
