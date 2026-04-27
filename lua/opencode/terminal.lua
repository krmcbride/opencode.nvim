---Terminal management for opencode via snacks.nvim.
---
---Provides start/stop for a local opencode TUI client running in a
---snacks terminal. Backend config lives in `opencode.config`, bridge transport
---lives in `opencode.bridge`, and attached-session coordination lives in
---`opencode.session`.
local M = {}
local bridge = require("opencode.bridge")
local config = require("opencode.config")
local editor_context = require("opencode.editor_context")
local TERMINAL_FILETYPE = require("opencode.constants").TERMINAL_FILETYPE
local session = require("opencode.session")
local snacks_terminal = require("snacks.terminal")

---@class opencode.TerminalTarget
---@field session_id? string|nil Explicit session id to attach to. When absent, the generated command follows the default attach behavior.

---snacks.nvim terminal handles are `snacks.win` instances. Reuse the upstream
---type directly so LuaLS agrees with `snacks.terminal.get()` / `.open()`.
---@alias opencode.TerminalHandle snacks.win

local state = {
  ---@type opencode.TerminalHandle|nil
  terminal = nil,
  ---@type table<integer, true>
  buffers = {},
  warned_claude_editor_port = false,
}

---@param terminal opencode.TerminalHandle|nil
local function remember_terminal_buf(terminal)
  if not terminal then
    return
  end

  local buf = terminal.buf
  if type(buf) == "number" and buf > 0 then
    state.buffers[buf] = true
  end
end

---Resolve the best-known buffer for a Snacks terminal handle.
---
---Neovim terminal process state lives on the backing buffer via buffer-local
---variables like `vim.b[buf].terminal_job_id`, but a Snacks handle may expose
---either the buffer directly or only a still-valid window pointing at it.
---This helper centralizes the "which buffer currently backs this terminal?"
---lookup so later PTY/job checks can be written against a single buffer id.
---@param terminal opencode.TerminalHandle|nil
---@return integer|nil
local function terminal_buf(terminal)
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

---Return whether a terminal handle still has a live PTY job.
---
---After `Ctrl-C`, Snacks may keep a terminal handle/buffer cached even though
---the underlying PTY exited. Treat missing job metadata as "still starting" so
---startup does not race and reopen a duplicate terminal.
---@param terminal opencode.TerminalHandle|nil
---@return boolean
local function terminal_running(terminal)
  local buf = terminal_buf(terminal)
  if not buf then
    return false
  end

  local job = vim.b[buf] and vim.b[buf].terminal_job_id
  if not job or job <= 0 then
    return true
  end

  -- `jobwait(..., 0)` polls without blocking; `-1` means the terminal job is still running.
  local ok, result = pcall(vim.fn.jobwait, { job }, 0)
  return ok and type(result) == "table" and result[1] == -1
end

---Close a stale terminal handle and clear the primary cache when needed.
---@param terminal opencode.TerminalHandle|nil
local function discard_terminal(terminal)
  if not terminal then
    return
  end

  if state.terminal == terminal then
    state.terminal = nil
  end

  pcall(function()
    terminal:close()
  end)
end

---Return the attach target the local terminal should use right now.
---
---The terminal does not own attach-session coordination itself; it reads the
---current target from `opencode.session`.
---@return opencode.TerminalTarget
local function current_target()
  return { session_id = session.get_target_session_id() }
end

---@param message string
local function notify_warn(message)
  vim.notify(message, vim.log.levels.WARN, { title = "opencode" })
end

---Normalize the raw token Neovim finds under the terminal cursor.
---
---Agent output often wraps file refs in punctuation, markdown quotes, or an
---OpenCode-style leading `@`. Strip those wrappers while preserving escaped
---spaces so the later parser and filesystem checks operate on a plain path-ish
---string.
---@param text string|nil
---@return string
local function clean_file_token(text)
  if type(text) ~= "string" then
    return ""
  end

  local token = vim.trim(text)
  token = token:gsub("^[`'\"(<%[]+", ""):gsub("[`'\">)%],;]+$", "")
  if token:sub(1, 1) == "@" then
    token = token:sub(2)
  end
  return (token:gsub("\\ ", " "))
end

---Split a terminal-output file reference into path and optional line number.
---
---Neovim's file motions expose slightly different text depending on the shape
---of the reference: for `path:12` `<cfile>` is usually just `path`, while for
---`@path#12` it can include the `#12` suffix. Parse both `<cfile>` and
---`<cWORD>` through the same normalizer so `gf` and `gF` can handle common
---agent/compiler formats without opening a line-suffixed path literally.
---@param text string|nil
---@return string file
---@return integer|nil line
local function split_file_reference(text)
  local token = clean_file_token(text)
  if token == "" then
    return "", nil
  end

  local patterns = {
    "^(.-)#(%d+)%-?%d*$",
    "^(.-):(%d+):%d+.*$",
    "^(.-):(%d+)%-?%d*$",
    "^(.-)%s+[Ll]ine%s+(%d+)$",
    "^(.-)%s*@%s*(%d+)$",
    "^(.-)%s*%(%s*(%d+)%s*%)$",
    "^(.-)%s+(%d+)$",
  }

  for _, pattern in ipairs(patterns) do
    local file, line = token:match(pattern)
    if file and file ~= "" then
      return clean_file_token(file), tonumber(line)
    end
  end

  return token, nil
end

---Return directories to try when resolving relative terminal references.
---
---OpenCode output is usually relative to the embedded TUI's cwd, not
---necessarily Neovim's current cwd. Prefer the bridged active cwd, then the
---configured terminal dir used to launch `opencode attach`, and only then fall
---back to Neovim's cwd/path behavior.
---@return string[]
local function reference_dirs()
  local dirs = {}
  local seen = {}

  ---@param dir string|nil
  local function add(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end

    local absolute = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(dir), ":p"))
    if seen[absolute] then
      return
    end

    seen[absolute] = true
    table.insert(dirs, absolute)
  end

  add(session.get_state().cwd)
  add((config.opts.terminal or {}).dir or ".")
  add(vim.fn.getcwd())

  return dirs
end

---Resolve a cleaned file reference to a real file path.
---
---Absolute paths and shell-expanded paths are accepted directly. Relative paths
---are checked against the OpenCode-oriented directory list before falling back
---to Neovim's `findfile()` search, which preserves familiar `gf` behavior when
---the explicit project-relative attempts do not find a match.
---@param file string
---@return string|nil
local function resolve_file(file)
  file = clean_file_token(file)
  if file == "" then
    return nil
  end

  local expanded = vim.fn.expand(file)
  if vim.uv.fs_stat(expanded) then
    return vim.fs.normalize(expanded)
  end

  for _, dir in ipairs(reference_dirs()) do
    local candidate = vim.fs.joinpath(dir, expanded)
    if vim.uv.fs_stat(candidate) then
      return vim.fs.normalize(candidate)
    end
  end

  local found = vim.fn.findfile(file, "**")
  if type(found) == "string" and found ~= "" then
    return found
  end

  return nil
end

---Find the normal editing window that should receive the opened file.
---
---The terminal window itself must not be used: temporarily replacing its buffer
---is what caused Snacks/OpenTUI rendering to shift after native `gf`. Prefer
---the previous normal-buffer window, then any non-floating normal-buffer window
---in the tab. If Neovim is still on a dashboard/home screen, there may not be a
---normal buffer yet, so fall back to the previous non-floating window and let
---`:edit` replace that startup buffer.
---@param exclude_win integer|nil
---@return integer|nil
local function find_edit_window(exclude_win)
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= 0 and previous ~= exclude_win and vim.api.nvim_win_is_valid(previous) then
    local previous_buf = vim.api.nvim_win_get_buf(previous)
    if vim.api.nvim_win_get_config(previous).zindex == nil and vim.bo[previous_buf].buftype == "" then
      return previous
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= exclude_win and vim.api.nvim_win_get_config(win).zindex == nil then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" then
        return win
      end
    end
  end

  if previous ~= 0 and previous ~= exclude_win and vim.api.nvim_win_is_valid(previous) then
    if vim.api.nvim_win_get_config(previous).zindex == nil then
      return previous
    end
  end

  return nil
end

---Open the file reference under the terminal cursor from a normal edit window.
---
---This is the embedded terminal's `gf`/`gF` implementation. It intentionally
---does not call Snacks' default terminal mapping, because that hides the pane,
---and it avoids native `gf` in the terminal window because Snacks' fixbuf swap
---path can disturb the terminal viewport. Instead it resolves the reference,
---switches to a regular edit window, opens the file there, and applies the line
---jump only for `gF`.
---@param terminal opencode.TerminalHandle
---@param with_line boolean
local function open_file_under_cursor(terminal, with_line)
  local file, line = split_file_reference(vim.fn.expand("<cfile>"))
  local target = resolve_file(file)
  if not target then
    file, line = split_file_reference(vim.fn.expand("<cWORD>"))
    target = resolve_file(file)
  end

  if not target then
    notify_warn("No file under cursor")
    return
  end

  if with_line and not line then
    local word_file, word_line = split_file_reference(vim.fn.expand("<cWORD>"))
    if clean_file_token(word_file) == clean_file_token(file) then
      line = word_line
    end
  end
  line = with_line and line or nil

  local win = find_edit_window(terminal.win)
  if not win then
    notify_warn("No edit window available")
    return
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(target))
  if line then
    local last = math.max(vim.api.nvim_buf_line_count(0), 1)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, last), 0 })
  end
  vim.cmd.stopinsert()
end

---Default snacks.nvim terminal options for the embedded opencode TUI.
---
---Per-launch values like width and environment are merged in later.
local DEFAULT_SNACKS_OPTS = {
  auto_close = true,
  start_insert = true,
  auto_insert = true,
  win = {
    position = "right",
    enter = false,
    -- Snacks' terminal style maps `gf` to hide the terminal before editing.
    -- Open from a regular edit window instead so the embedded TUI window and
    -- terminal viewport are not disturbed by a temporary buffer swap.
    keys = {
      gf = function(terminal)
        open_file_under_cursor(terminal, false)
      end,
      gF = function(terminal)
        open_file_under_cursor(terminal, true)
      end,
    },
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
---@param opts? { editor_context?: boolean }
---@return table<string, string>|nil
local function get_env(opts)
  opts = opts or {}
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

  if opts.editor_context ~= false and (config.opts.editor_context or {}).enabled ~= false then
    if env.OPENCODE_EDITOR_SSE_PORT == nil then
      env.OPENCODE_EDITOR_SSE_PORT = tostring(editor_context.ensure().port)
    end
    local claude_port = env.CLAUDE_CODE_SSE_PORT or vim.env.CLAUDE_CODE_SSE_PORT
    if claude_port and claude_port ~= "" and not state.warned_claude_editor_port then
      state.warned_claude_editor_port = true
      vim.schedule(function()
        vim.notify(
          "Ignoring CLAUDE_CODE_SSE_PORT for embedded OpenCode TUI; using OPENCODE_EDITOR_SSE_PORT instead",
          vim.log.levels.WARN,
          { title = "opencode" }
        )
      end)
    end
    env.CLAUDE_CODE_SSE_PORT = ""
  end

  return normalize_env(env)
end

---Build the command used to launch the embedded terminal.
---
---If `terminal.cmd` is configured, use it verbatim as the escape hatch. The
---generated path builds `opencode attach ...` from structured config.
---@param target? opencode.TerminalTarget
---@param launch_opts? opencode.TerminalLaunchOpts
---@return string
local function get_cmd(target, launch_opts)
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
  elseif launch_opts and launch_opts["continue"] ~= nil then
    if launch_opts["continue"] ~= false then
      table.insert(cmd, "--continue")
    end
  elseif terminal["continue"] ~= false then
    table.insert(cmd, "--continue")
  end
  return table.concat(cmd, " ")
end

---Build snacks.nvim options for the requested terminal target.
---@param target? opencode.TerminalTarget
---@param launch_opts? opencode.TerminalLaunchOpts
---@param opts? { editor_context?: boolean }
---@return string, table
local function get_opts(target, launch_opts, opts)
  local terminal = config.opts.terminal or {}
  ---@type table
  local snacks_opts = vim.deepcopy(DEFAULT_SNACKS_OPTS)

  snacks_opts.win.width = terminal.width
  snacks_opts.env = get_env(opts)

  return get_cmd(target, launch_opts), snacks_opts
end

---@return opencode.TerminalHandle|nil
---@param target? opencode.TerminalTarget
---@param create? boolean
function M.get(target, create)
  if target == nil and state.terminal then
    if terminal_running(state.terminal) then
      return state.terminal
    end

    discard_terminal(state.terminal)
  end

  local cmd, snacks_opts = get_opts(target, nil, { editor_context = false })
  ---@type table
  local opts = vim.tbl_deep_extend("force", snacks_opts, { create = false })
  if create ~= nil then
    opts.create = create
  end
  local terminal = snacks_terminal.get(cmd, opts)
  if terminal and terminal_running(terminal) then
    remember_terminal_buf(terminal)
    if target == nil then
      state.terminal = terminal
    end
    return terminal
  end

  if terminal then
    discard_terminal(terminal)
  end

  if target == nil then
    state.terminal = nil
  end

  return nil
end

---Return whether a buffer belongs to an opencode-managed terminal.
---@param buf integer|nil
---@return boolean
function M.owns_buf(buf)
  if type(buf) ~= "number" or buf <= 0 then
    return false
  end

  if state.buffers[buf] then
    return true
  end

  return false
end

---Forget a terminal buffer after its close lifecycle completes.
---@param buf integer|nil
function M.forget_buf(buf)
  if type(buf) == "number" and buf > 0 then
    state.buffers[buf] = nil

    if terminal_buf(state.terminal) == buf then
      state.terminal = nil
    end

    if not next(state.buffers) then
      editor_context.stop()
    end
  end
end

---Resolve the terminal job id for a handle/target.
---@return integer|nil
---@param target? opencode.TerminalTarget
local function get_job(target)
  local buf = terminal_buf(M.get(target))
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

---Start the primary embedded opencode terminal if it is not already running.
---@param launch_opts? opencode.TerminalLaunchOpts
---@return boolean started True when a new terminal was launched.
function M.start(launch_opts)
  if M.get(nil, false) then
    return false
  end

  local cmd, snacks_opts = get_opts(current_target(), launch_opts)
  state.terminal = snacks_terminal.open(cmd, snacks_opts)
  remember_terminal_buf(state.terminal)
  return true
end

---Stop a terminal by target, or stop the primary cached terminal when omitted.
---@param target? opencode.TerminalTarget
function M.stop(target)
  local terminal = target == nil and state.terminal or M.get(target)
  local job = get_job(target)

  if job then
    vim.fn.jobstop(job)
  end

  if terminal then
    terminal:close()
  end

  if target == nil or state.terminal == terminal then
    state.terminal = nil
    editor_context.stop()
  end
end

return M
