---opencode.nvim public API.
---
---This is the module entrypoint loaded by `require("opencode")`.
---
---Keep this file focused on the user-facing Lua API: setup, terminal control,
---prompt injection, review helpers, and status/command helpers. Editor-side
---autoload hooks live in `plugin/opencode.lua`.
local M = {}

---Apply user configuration to the plugin.
---@param opts? opencode.Opts
---@return opencode.Opts
function M.setup(opts)
  return require("opencode.config").setup(opts)
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
    local terminal = require("opencode.terminal").get()
    if not (terminal and terminal.win and vim.api.nvim_win_is_valid(terminal.win)) then
      return
    end

    -- Focusing the window alone leaves terminal buffers in Normal mode; the TUI
    -- expects Terminal mode so keystrokes go to the PTY instead of acting on the
    -- split itself.
    vim.api.nvim_set_current_win(terminal.win)
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t" then
      vim.cmd.startinsert()
    end

    if opts.cursor_end then
      -- Give the injected prompt time to show in the TUI before moving the cursor.
      vim.defer_fn(function()
        if not vim.api.nvim_win_is_valid(terminal.win) then
          return
        end
        if vim.api.nvim_get_current_win() ~= terminal.win then
          return
        end
        local buf = vim.api.nvim_win_get_buf(terminal.win)
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
  require("opencode.terminal").toggle()
  -- The terminal may have created or focused a session that should own the SSE subscription.
  require("opencode.client").ensure_subscribed()
  if opts.focus then
    focus_terminal()
  end
end

---Start the opencode terminal.
---@param opts? opencode.ToggleOpts
M.start = function(opts)
  opts = opts or {}
  require("opencode.terminal").start()
  -- Starting the TUI is the earliest point where attach-mode session state can exist.
  require("opencode.client").ensure_subscribed()
  if opts.focus then
    focus_terminal()
  end
end

---Attach the embedded TUI directly to a specific session id.
---@param session_id string
function M.attach_session(session_id)
  local ok, err = require("opencode.terminal").attach_session(session_id)
  if not ok then
    vim.notify(err or "Failed to attach OpenCode session", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  -- Re-scope SSE to the attached session's directory once the target changes.
  require("opencode.client").ensure_subscribed()
  focus_terminal()
end

---Prompt for a session id and attach the embedded TUI to that session.
function M.attach_session_prompt()
  require("opencode.input").simple({
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
---@param prompt string The prompt text (supports @this, @buffer, @diagnostics)
---@param opts? opencode.PromptOpts
function M.prompt(prompt, opts)
  opts = opts or {}
  local context = opts.context or require("opencode.context").new()
  local expanded = context:expand(prompt)
  local text = (opts.clear and "\005\021" or "") .. expanded .. (opts.submit and "\r" or "")

  require("opencode.terminal").send(text, function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      context:clear()
      return
    end

    -- Prompt activity can create or move the active session; re-check SSE after
    -- the PTY write succeeds so follow-up events arrive in the right scope.
    require("opencode.client").ensure_subscribed(true)

    if opts.focus then
      focus_terminal({ cursor_end = not opts.submit })
    end

    context:clear()
  end)
end

---@class opencode.ReviewSelection
---@field path string
---@field start_line integer
---@field end_line integer

---Prompt for a review message and send a ranged file attachment to the active session.
---@param selection opencode.ReviewSelection
local function review_with_selection(selection)
  local filename = vim.fn.fnamemodify(selection.path, ":t")
  ---@type string
  local title
  if selection.start_line == selection.end_line then
    title = "Review " .. filename .. " line " .. tostring(selection.start_line)
  else
    title = "Review " .. filename .. " lines " .. tostring(selection.start_line) .. "-" .. tostring(selection.end_line)
  end

  require("opencode.input").review({
    prompt = "Review message: ",
    title = title,
  }, function(input)
    if input == nil then
      return
    end

    local message = vim.trim(input)
    if message == "" then
      vim.notify("Review message is required", vim.log.levels.WARN, { title = "opencode" })
      return
    end

    -- Direct review sends require a concrete attached session because they go to
    -- `/session/<id>/prompt_async`, not through the shared attach-mode terminal.
    local bridge = require("opencode.bridge").get_state()
    if bridge.route ~= "session" or not bridge.session_id then
      vim.notify(
        "No active OpenCode session selected in the embedded TUI",
        vim.log.levels.ERROR,
        { title = "opencode" }
      )
      return
    end

    require("opencode.server").get_url(function(url_err, url)
      if url_err or not url then
        vim.notify(url_err or "OpenCode backend unavailable", vim.log.levels.ERROR, { title = "opencode" })
        return
      end

      local range = require("opencode.range")
      ---@type table[]
      local parts = {
        {
          type = "text",
          text = message,
        },
        {
          type = "file",
          mime = "text/plain",
          filename = range.display_name(selection.path, selection.start_line, selection.end_line),
          url = range.file_url(selection.path, selection.start_line, selection.end_line),
        },
      }

      local function send(prompt_opts)
        require("opencode.client").prompt_async(url, bridge.session_id, parts, prompt_opts, function(err)
          if err then
            vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
            return
          end

          vim.notify("Sent review to active OpenCode session", vim.log.levels.INFO, { title = "opencode" })
          require("opencode.client").ensure_subscribed(true)
        end)
      end

      require("opencode.client").session_messages(
        url,
        bridge.session_id,
        { directory = bridge.cwd, limit = 100 },
        function(err, response)
          if err or type(response) ~= "table" then
            send({ directory = bridge.cwd })
            return
          end

          local last_user = nil
          for i = #response, 1, -1 do
            local item = response[i]
            if type(item) == "table" and type(item.info) == "table" and item.info.role == "user" then
              last_user = item.info
              break
            end
          end

          send({
            directory = bridge.cwd,
            agent = last_user and last_user.agent or nil,
            model = last_user and last_user.model or nil,
            variant = last_user and last_user.variant or nil,
          })
        end
      )
    end)
  end)
end

---Prompt for a review message and send the current line or active visual
---selection directly to the active session as a ranged file attachment.
function M.review_selection()
  local selection, selection_err = require("opencode.range").current_selection_or_line()
  if selection_err or not selection then
    vim.notify(selection_err or "No file selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  review_with_selection(selection)
end

---Prompt for a review message and send the persisted visual marks as a ranged
---file attachment. Prefer this for explicit visual-mode mappings.
function M.review_visual_selection()
  local selection, selection_err = require("opencode.range").visual_selection()
  if selection_err or not selection then
    vim.notify(selection_err or "No visual selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  review_with_selection(selection)
end

---Show current terminal, backend, bridge, and SSE status.
function M.status()
  local terminal = require("opencode.terminal").get()
  local sse = require("opencode.client").get_status()
  local bridge = require("opencode.bridge").get_state()

  ---@type string[]
  local lines = {}
  table.insert(lines, "Terminal: " .. (terminal and "running" or "not running"))
  if sse.connected then
    table.insert(lines, "SSE: connected to " .. sse.url)
    table.insert(lines, "SSE directory: " .. (sse.directory or "none"))
  else
    table.insert(lines, "SSE: not connected")
  end

  table.insert(lines, "Backend: " .. require("opencode.config").get_url())
  table.insert(lines, "Bridge: " .. (bridge.url or "not started"))
  table.insert(lines, "Route: " .. bridge.route)
  table.insert(lines, "Session: " .. (bridge.session_id or "none"))

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "opencode" })
end

---Expose Context class for advanced usage.
M.Context = require("opencode.context")

return M
