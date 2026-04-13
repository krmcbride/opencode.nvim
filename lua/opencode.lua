---opencode.nvim public API.
---
---This is the module entrypoint loaded by `require("opencode")`.
---
---Keep this file focused on the user-facing Lua API: setup, terminal control,
---prompt injection, and status helpers. Higher-level review workflow lives in
---`opencode.review`. Editor-side autoload hooks live in `plugin/opencode.lua`.
local M = {}
local bridge = require("opencode.bridge")
local client = require("opencode.client")
local config = require("opencode.config")
local context = require("opencode.context")
local input = require("opencode.input")
local review = require("opencode.review")
local session = require("opencode.session")
local terminal = require("opencode.terminal")

---Apply user configuration to the plugin.
---@param opts? opencode.Opts
---@return opencode.Opts
function M.setup(opts)
  return config.setup(opts)
end

---Move the TUI input cursor to end-of-line by sending Ctrl-E on the PTY.
---
---OpenCode's `@` file picker opens when the cursor is at the end of an `@path`
---fragment. Neovim config often injects that text into the local terminal; we then need
---the cursor *on* the end of the fragment (not Normal mode over the split, and
---not after a translated `<End>`), so the TUI can treat it like a native `@`
---completion.
---
---We send raw Ctrl-E (byte `\005`) via `nvim_chan_send` instead of `feedkeys`
---with `<End>`: terminal key translation produced stray characters in practice;
---Ctrl-E matches common readline end-of-line behavior.
---@param buf integer
local function send_terminal_ctrl_e(buf)
  local job_id = vim.b[buf] and vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, "\005")
  end
end

---@class opencode.FocusTerminalOpts
---@field cursor_end? boolean After focusing the terminal, defer briefly and move the TUI cursor to end-of-line.

---Focus the opencode terminal and optionally move the TUI cursor to EOL.
---
---@param opts? opencode.FocusTerminalOpts When `cursor_end` is true, defer
---   briefly so the TUI can apply appended text, then send Ctrl-E (see block
---   comment on `send_terminal_ctrl_e`).
local function focus_terminal(opts)
  opts = opts or {}
  vim.schedule(function()
    local current = terminal.get()
    if not (current and current.win and vim.api.nvim_win_is_valid(current.win)) then
      return
    end

    -- Focusing the window alone leaves terminal buffers in Normal mode; the TUI
    -- expects Terminal mode so keystrokes go to the PTY instead of acting on the
    -- split itself.
    vim.api.nvim_set_current_win(current.win)
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t" then
      vim.cmd.startinsert()
    end

    if opts.cursor_end then
      -- Give the injected prompt time to show in the TUI before moving the cursor.
      vim.defer_fn(function()
        if not vim.api.nvim_win_is_valid(current.win) then
          return
        end
        if vim.api.nvim_get_current_win() ~= current.win then
          return
        end
        local buf = vim.api.nvim_win_get_buf(current.win)
        if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t" then
          vim.cmd.startinsert()
        end
        send_terminal_ctrl_e(buf)
      end, 25)
    end
  end)
end

---@class opencode.ToggleOpts
---@field focus? boolean After open: focus the window and enter Terminal mode (not Normal over the split)

---Toggle the opencode terminal.
---@param opts? opencode.ToggleOpts
M.toggle = function(opts)
  opts = opts or {}
  terminal.toggle()
  -- The terminal may have created or focused a session that should own the SSE subscription.
  client.ensure_subscribed()
  if opts.focus then
    focus_terminal()
  end
end

---Start the opencode terminal.
---@param opts? opencode.ToggleOpts
M.start = function(opts)
  opts = opts or {}
  terminal.start()
  -- Starting the TUI is the earliest point where attach-mode session state can exist.
  client.ensure_subscribed()
  if opts.focus then
    focus_terminal()
  end
end

---Attach the embedded TUI directly to a specific session id.
---@param session_id string
function M.attach_session(session_id)
  local trimmed = vim.trim(session_id)
  if trimmed == "" then
    vim.notify("Session ID is required", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  local current = session.get_target_session_id()
  if current ~= trimmed then
    terminal.stop()
  end

  session.set_target_session_id(trimmed)
  session.set_follow_active_session(true)
  terminal.start()

  -- Re-scope SSE to the attached session's directory once the target changes.
  client.ensure_subscribed()
  focus_terminal()
end

---Prompt for a session id and attach the embedded TUI to that session.
function M.attach_session_prompt()
  input.simple({
    prompt = "OpenCode session ID: ",
  }, function(value)
    if value == nil then
      return
    end

    local session_id = vim.trim(value)
    if session_id == "" then
      vim.notify("Session ID is required", vim.log.levels.WARN, { title = "opencode" })
      return
    end

    M.attach_session(session_id)
  end)
end

---@class opencode.PromptOpts
---@field clear? boolean Clear the TUI input before appending
---@field submit? boolean Submit the TUI input after appending
---@field context? opencode.Context The context (defaults to current state)
---@field focus? boolean After append: focus the terminal, enter Terminal mode,
---move cursor to EOL (so `@` refs from Neovim land like a native TUI completion)

---Send a prompt to opencode with context expansion.
---
---This writes into the embedded terminal's PTY rather than calling the backend
---HTTP prompt APIs directly, so the attach-mode TUI remains the source of truth
---for interactive prompt entry.
---
---Plugin-defined shorthands like `@this`, `@buffer`, and `@diagnostics` are
---expanded here before the text is sent. Typing those strings directly into the
---OpenCode TUI does not trigger any plugin-side expansion.
---@param prompt string The prompt text (supports @this, @buffer, @diagnostics)
---@param opts? opencode.PromptOpts
function M.prompt(prompt, opts)
  opts = opts or {}
  local current_context = opts.context or context.new()
  local expanded = current_context:expand(prompt)
  local text = (opts.clear and "\005\021" or "") .. expanded .. (opts.submit and "\r" or "")

  terminal.send(text, function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      current_context:clear()
      return
    end

    -- Prompt activity can create or move the active session; re-check SSE after
    -- the PTY write succeeds so follow-up events arrive in the right scope.
    client.ensure_subscribed(true)

    if opts.focus then
      focus_terminal({ cursor_end = not opts.submit })
    end

    current_context:clear()
  end)
end

---Prompt for a review message and send the current line or active visual
---selection directly to the active session as a ranged file attachment.
function M.review_selection()
  review.review_selection()
end

---Prompt for a review message and send the persisted visual marks as a ranged
---file attachment. Prefer this for explicit visual-mode mappings.
function M.review_visual_selection()
  review.review_visual_selection()
end

---Show current terminal, backend, bridge, and SSE status.
function M.status()
  local current_terminal = terminal.get()
  local sse = client.get_status()
  local current_session = session.get_state()
  local bridge_url = bridge.get_url()

  ---@type string[]
  local lines = {}
  table.insert(lines, "Terminal: " .. (current_terminal and "running" or "not running"))
  if sse.connected then
    table.insert(lines, "SSE: connected to " .. sse.url)
    table.insert(lines, "SSE directory: " .. (sse.directory or "none"))
  else
    table.insert(lines, "SSE: not connected")
  end

  table.insert(lines, "Backend: " .. config.get_url())
  table.insert(lines, "Bridge: " .. (bridge_url or "not started"))
  table.insert(lines, "Route: " .. current_session.route)
  table.insert(lines, "Session: " .. (current_session.session_id or "none"))

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "opencode" })
end

---Expose Context class for advanced usage.
M.Context = context

return M
