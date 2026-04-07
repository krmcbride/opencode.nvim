---Terminal management for opencode via snacks.nvim.
---
---Provides toggle/start/stop for a local opencode TUI client running in a
---snacks terminal. The client attaches to a configured backend server.
local M = {}
local warned_username = false
local state = {
  session_id = nil,
  follow_session = false,
}

local DEFAULT_SNACKS_OPTS = {
  auto_close = true,
  start_insert = true,
  auto_insert = true,
  win = {
    position = "right",
    enter = false,
    wo = { winbar = "" },
    bo = { filetype = "opencode_terminal" },
  },
}

---@param env table<string, string|number|boolean>|nil
---@return table<string, string>|nil
local function normalize_env(env)
  if not env or vim.tbl_isempty(env) then
    return nil
  end

  local normalized = {}
  for key, value in pairs(env) do
    if value ~= nil then
      normalized[key] = tostring(value)
    end
  end

  if vim.tbl_isempty(normalized) then
    return nil
  end

  return normalized
end

---@param text string
---@return string
local function quote(text)
  return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---@return table<string, string>|nil
local function get_env()
  local config = require("opencode.config")
  local terminal = config.opts.terminal or {}
  local env = vim.deepcopy(terminal.env or {})
  local auth = config.get_auth()
  local bridge = require("opencode.bridge").ensure()

  if auth then
    env.OPENCODE_SERVER_PASSWORD = auth.password
  end

  for key, value in pairs(bridge) do
    env[key] = value
  end

  return normalize_env(env)
end

---@param target? { session_id?: string|nil }
---@return string
local function get_cmd(target)
  local config = require("opencode.config")
  local terminal = config.opts.terminal or {}
  target = target or state
  if terminal.cmd then
    return terminal.cmd
  end

  local auth = config.get_auth()
  if auth and auth.username ~= "opencode" then
    if not warned_username then
      warned_username = true
      vim.schedule(function()
        vim.notify(
          "Generated attach mode currently expects backend username `opencode`",
          vim.log.levels.WARN,
          { title = "opencode" }
        )
      end)
    end
  end

  local cmd = {
    "opencode attach",
    quote(config.get_url()),
    "--dir",
    quote(terminal.dir or "."),
  }
  if target.session_id and target.session_id ~= "" then
    table.insert(cmd, "--session")
    table.insert(cmd, quote(target.session_id))
  elseif terminal["continue"] ~= false then
    table.insert(cmd, "--continue")
  end
  return table.concat(cmd, " ")
end

---@param target? { session_id?: string|nil }
local function get_opts(target)
  local config = require("opencode.config").opts.terminal or {}
  local snacks_opts = vim.deepcopy(DEFAULT_SNACKS_OPTS)

  snacks_opts.win.width = config.width
  snacks_opts.env = get_env()

  return get_cmd(target), snacks_opts
end

---@return snacks.win|nil
---@param target? { session_id?: string|nil }
---@param create? boolean
function M.get(target, create)
  local cmd, snacks_opts = get_opts(target)
  local opts = vim.tbl_deep_extend("force", snacks_opts, { create = false })
  if create ~= nil then
    opts.create = create
  end
  return require("snacks.terminal").get(cmd, opts)
end

---@return integer|nil
---@param target? { session_id?: string|nil }
local function get_buf(target)
  local terminal = M.get(target)
  if not terminal then
    return nil
  end

  if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
    return terminal.buf
  end

  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    return vim.api.nvim_win_get_buf(terminal.win)
  end

  return nil
end

---@return integer|nil
---@param target? { session_id?: string|nil }
local function get_job(target)
  local buf = get_buf(target)
  if not buf then
    return nil
  end

  local job = vim.b[buf] and vim.b[buf].terminal_job_id
  if job and job > 0 then
    return job
  end

  return nil
end

---@param callback fun(err: string|nil, job: integer|nil)
---@param target? { session_id?: string|nil }
local function wait_job(callback, target)
  local job = get_job(target)
  if job then
    callback(nil, job)
    return
  end

  local retries = 0
  local timer = vim.uv.new_timer()
  if not timer then
    callback("Failed to create timer for terminal startup", nil)
    return
  end

  local closed = false
  timer:start(
    25,
    25,
    vim.schedule_wrap(function()
      if closed then
        return
      end

      local next = get_job(target)
      if next then
        closed = true
        timer:stop()
        timer:close()
        callback(nil, next)
        return
      end

      retries = retries + 1
      if retries < 80 then
        return
      end

      closed = true
      timer:stop()
      timer:close()
      callback("Timed out waiting for opencode terminal", nil)
    end)
  )
end

---@param text string
---@param callback? fun(err: string|nil)
function M.send(text, callback)
  if not M.get(nil, false) then
    M.start()
  end

  wait_job(function(err, job)
    if err or not job then
      if callback then
        callback(err or "No opencode terminal job found")
      end
      return
    end

    vim.api.nvim_chan_send(job, text)
    if callback then
      callback(nil)
    end
  end, nil)
end

---@param command string
---@param callback? fun(err: string|nil, handled: boolean|nil)
function M.command(command, callback)
  local keys = (require("opencode.config").opts.terminal or {}).keys or {}

  local value = keys[command]
  if not value then
    if callback then
      callback(nil, false)
    end
    return
  end

  M.send(value, function(err)
    if callback then
      callback(err, err == nil)
    end
  end)
end

function M.toggle()
  local cmd, snacks_opts = get_opts()
  require("snacks.terminal").toggle(cmd, snacks_opts)
end

function M.start()
  if not M.get(nil, false) then
    local cmd, snacks_opts = get_opts()
    require("snacks.terminal").open(cmd, snacks_opts)
  end
end

---@param target? { session_id?: string|nil }
function M.stop(target)
  local job = get_job(target)
  local terminal = M.get(target)

  if job then
    vim.fn.jobstop(job)
  end

  if terminal then
    terminal:close()
  end
end

---@param session_id string
---@return boolean, string?
function M.attach_session(session_id)
  local trimmed = vim.trim(session_id)
  if trimmed == "" then
    return false, "Session ID is required"
  end

  local current = { session_id = state.session_id }
  local next = { session_id = trimmed }
  if current.session_id ~= next.session_id then
    M.stop(current)
  end

  state.session_id = trimmed
  state.follow_session = true
  M.start()
  return true
end

---@param session_id string|nil
function M.sync_session_target(session_id)
  if not state.follow_session or not session_id or session_id == "" then
    return
  end
  state.session_id = session_id
end

return M
