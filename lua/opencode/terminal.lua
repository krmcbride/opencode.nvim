---Terminal management for opencode via snacks.nvim.
---
---Provides toggle/start/stop for a local opencode TUI client running in a
---snacks terminal. Backend config lives in `opencode.config`, bridge transport
---lives in `opencode.bridge`, and attached-session coordination lives in
---`opencode.session`.
local M = {}
local bridge = require("opencode.bridge")
local config = require("opencode.config")
local TERMINAL_FILETYPE = require("opencode.constants").TERMINAL_FILETYPE
local session = require("opencode.session")

---@class opencode.TerminalTarget
---@field session_id? string|nil Explicit session id to attach to. When absent, the generated command follows the default attach behavior.

---snacks.nvim terminal handles are `snacks.win` instances. Reuse the upstream
---type directly so LuaLS agrees with `snacks.terminal.get()` / `.open()`.
---@alias opencode.TerminalHandle snacks.win

local state = {
  ---@type opencode.TerminalHandle|nil
  terminal = nil,
}

---@type table<integer, boolean>
local expected_exit = {}

---Check whether a terminal window is visible in the current tabpage.
---@param terminal opencode.TerminalHandle|nil
---@return boolean
local function on_current_tab(terminal)
  return terminal ~= nil
    and terminal.win_valid
    and terminal:win_valid()
    and vim.api.nvim_win_get_tabpage(terminal.win) == vim.api.nvim_get_current_tabpage()
end

---Check whether a terminal window is currently visible in some other tabpage.
---@param terminal opencode.TerminalHandle|nil
---@return boolean
local function on_other_tab(terminal)
  return terminal ~= nil
    and terminal.win_valid
    and terminal:win_valid()
    and vim.api.nvim_win_get_tabpage(terminal.win) ~= vim.api.nvim_get_current_tabpage()
end

---Resize an existing terminal PTY to match its visible window.
---
---When snacks hides and re-shows an existing terminal buffer, the PTY can keep a
---stale viewport until it receives an explicit resize.
---@param terminal opencode.TerminalHandle|nil
local function sync_size(terminal)
  if not (terminal and terminal.buf_valid and terminal:buf_valid()) then
    return
  end

  vim.schedule(function()
    if not (terminal.win_valid and terminal:win_valid()) then
      return
    end

    local job = vim.b[terminal.buf] and vim.b[terminal.buf].terminal_job_id
    if not (job and job > 0) then
      return
    end

    local width = vim.api.nvim_win_get_width(terminal.win)
    local height = vim.api.nvim_win_get_height(terminal.win)
    if width > 0 and height > 0 then
      pcall(vim.fn.jobresize, job, width, height)
    end
  end)
end

---Run a few staggered PTY resizes while the split settles.
---@param terminal opencode.TerminalHandle|nil
local function resync_size(terminal)
  sync_size(terminal)
  vim.defer_fn(function()
    sync_size(terminal)
  end, 40)
  vim.defer_fn(function()
    sync_size(terminal)
  end, 120)
end

---Return the attach target the local terminal should use right now.
---
---The terminal does not own attach-session coordination itself; it reads the
---current target from `opencode.session`.
---@return opencode.TerminalTarget
local function current_target()
  return { session_id = session.get_target_session_id() }
end

---Pick the best session target for a fresh attach process.
---
---Cross-tab renderer reuse appears unreliable. When we need a fresh process,
---prefer the explicit attach target, otherwise fall back to the currently active
---session reported by the bridge so reopening stays on the same conversation.
---@return opencode.TerminalTarget
local function restart_target()
  local target = current_target()
  if target.session_id and target.session_id ~= "" then
    return target
  end

  local active = session.get_state()
  if active.route == "session" and active.session_id and active.session_id ~= "" then
    return { session_id = active.session_id }
  end

  return target
end

---Install opencode-specific exit handling for an embedded terminal buffer.
---@param terminal opencode.TerminalHandle
local function attach_close_handler(terminal)
  local buf = terminal.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  expected_exit[buf] = nil
  terminal:on("TermClose", function()
    local status = type(vim.v.event) == "table" and tonumber(vim.v.event.status) or 0
    local expected = expected_exit[buf] == true
    expected_exit[buf] = nil

    if state.terminal == terminal then
      state.terminal = nil
    end

    if expected or status == 0 then
      vim.schedule(function()
        if terminal.buf_valid and terminal:buf_valid() then
          terminal:close()
        end
        vim.cmd.checktime()
      end)
      return
    end

    vim.notify("Terminal exited with code " .. tostring(status) .. ".\nCheck for any errors.", vim.log.levels.ERROR, {
      title = "opencode",
    })
  end, { buf = true })
end

---Default snacks.nvim terminal options for the embedded opencode TUI.
---
---Per-launch values like width and environment are merged in later.
local DEFAULT_SNACKS_OPTS = {
  auto_close = false,
  start_insert = true,
  auto_insert = true,
  win = {
    position = "right",
    enter = false,
    wo = { winbar = "" },
    bo = { filetype = TERMINAL_FILETYPE },
  },
}

---Normalize an env map for `jobstart`/`termopen` consumption.
---
---Terminal config may provide string, number, or boolean values. The child
---process environment must be string-keyed and string-valued.
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

---Shell-quote a single argument for the generated `opencode attach` command.
---
---This is only used for the generated command path. A custom `terminal.cmd`
---bypasses this helper entirely.
---@param text string
---@return string
local function quote(text)
  return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---Build the environment for the embedded attach-mode process.
---
---This merges three sources:
---1. user-provided `terminal.env` for the child `opencode attach` process
---2. backend auth env inherited from Neovim config
---3. bridge env so the TUI can report active-session state back to Neovim
---
---This is not a general backend-daemon configuration surface. Server-side
---feature flags still need to be configured on the backend process itself.
---@return table<string, string>|nil
local function get_env()
  local terminal = config.opts.terminal or {}
  local env = vim.deepcopy(terminal.env or {})
  local auth = config.get_auth()
  local bridge_env = bridge.ensure()

  if auth then
    env.OPENCODE_SERVER_USERNAME = auth.username
    env.OPENCODE_SERVER_PASSWORD = auth.password
  end

  for key, value in pairs(bridge_env) do
    env[key] = value
  end

  return normalize_env(env)
end

---Build the command used to launch the embedded terminal.
---
---If `terminal.cmd` is configured, use it verbatim as the escape hatch. The
---generated path builds `opencode attach ...` from structured config.
---@param target? opencode.TerminalTarget
---@return string
local function get_cmd(target)
  local terminal = config.opts.terminal or {}
  target = target or current_target()
  if terminal.cmd then
    return terminal.cmd
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

---Build snacks.nvim options for the requested terminal target.
---@param target? opencode.TerminalTarget
---@return string, table
local function get_opts(target)
  local terminal = config.opts.terminal or {}
  ---@type table
  local snacks_opts = vim.deepcopy(DEFAULT_SNACKS_OPTS)

  snacks_opts.win.width = terminal.width
  snacks_opts.env = get_env()

  return get_cmd(target), snacks_opts
end

---@param target? opencode.TerminalTarget
---@return opencode.TerminalHandle
local function open_terminal(target)
  local cmd, snacks_opts = get_opts(target or current_target())
  state.terminal = require("snacks.terminal").open(cmd, snacks_opts)
  attach_close_handler(state.terminal)
  resync_size(state.terminal)
  return state.terminal
end

---@param target? opencode.TerminalTarget
---@return opencode.TerminalHandle
local function restart_terminal(target)
  M.stop()
  return open_terminal(target or restart_target())
end

---Ensure the primary terminal is visible when it already belongs to this tab.
---
---Cross-tab handoff is handled by restarting the attach process; this helper is
---only for the current tab's existing terminal window/buffer lifecycle.
---@param terminal opencode.TerminalHandle
---@return opencode.TerminalHandle
local function reveal(terminal)
  if on_current_tab(terminal) then
    resync_size(terminal)
    return terminal
  end

  if terminal.win_valid and terminal:win_valid() then
    terminal:hide()
  end

  terminal:show()
  resync_size(terminal)
  return terminal
end

---@return opencode.TerminalHandle|nil
---@param target? opencode.TerminalTarget
---@param create? boolean
function M.get(target, create)
  if target == nil and state.terminal and state.terminal.buf_valid and state.terminal:buf_valid() then
    return state.terminal
  end

  local cmd, snacks_opts = get_opts(target)
  ---@type table
  local opts = vim.tbl_deep_extend("force", snacks_opts, { create = false })
  if create ~= nil then
    opts.create = create
  end
  local terminal = require("snacks.terminal").get(cmd, opts)
  if target == nil and terminal and terminal.buf_valid and terminal:buf_valid() then
    state.terminal = terminal
  end
  return terminal
end

---Resolve the backing buffer for a terminal handle/target.
---@return integer|nil
---@param target? opencode.TerminalTarget
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

---Resolve the terminal job id for a handle/target.
---@return integer|nil
---@param target? opencode.TerminalTarget
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

---Wait briefly for the terminal PTY job to exist after opening snacks.nvim.
---
---`snacks.terminal.open()` returns before the job id is always available on the
---buffer, so prompt injection may need to poll for a short period.
---@param callback fun(err: string|nil, job: integer|nil)
---@param target? opencode.TerminalTarget
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

---Send raw text directly to the embedded terminal PTY.
---
---Starts the terminal first if needed, then waits for the job id before
---sending the text.
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

---Toggle the primary embedded opencode terminal.
function M.toggle()
  local terminal = M.get(nil, false)
  if terminal and terminal.buf_valid and terminal:buf_valid() then
    if on_current_tab(terminal) then
      terminal:hide()
    elseif on_other_tab(terminal) then
      restart_terminal(restart_target())
    else
      state.terminal = reveal(terminal)
    end
    return
  end

  open_terminal(current_target())
end

---Start the primary embedded opencode terminal if it is not already running.
function M.start()
  local terminal = M.get(nil, false)
  if terminal and terminal.buf_valid and terminal:buf_valid() then
    if on_other_tab(terminal) then
      restart_terminal(restart_target())
    else
      state.terminal = reveal(terminal)
    end
    return
  end

  if not terminal then
    open_terminal(current_target())
  end
end

---Resize the visible primary terminal to match its current window.
function M.sync_size()
  resync_size(M.get(nil, false))
end

---Return whether the primary embedded terminal buffer still exists.
---@return boolean
function M.is_open()
  local terminal = M.get(nil, false)
  return terminal ~= nil and terminal.buf_valid and terminal:buf_valid()
end

---Stop a terminal by target, or stop the primary cached terminal when omitted.
---@param target? opencode.TerminalTarget
function M.stop(target)
  local terminal = target == nil and state.terminal or M.get(target)
  local buf = target == nil and terminal and terminal.buf or get_buf(target)
  local job = get_job(target)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    expected_exit[buf] = true
  end

  if job then
    vim.fn.jobstop(job)
  elseif terminal then
    terminal:close()
  end

  if not job and buf then
    expected_exit[buf] = nil
  end

  if target == nil or state.terminal == terminal then
    state.terminal = nil
  end
end

return M
