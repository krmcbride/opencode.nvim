---opencode.nvim public API.
---
---Main entry point for the plugin. Provides functions to control the terminal,
---send prompts with context expansion, and execute TUI commands.
local M = {}

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
local function send_terminal_ctrl_e(buf)
  local job_id = vim.b[buf] and vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, "\005")
  end
end

---Focus the opencode terminal and optionally move the TUI cursor to EOL.
---
---@param opts? { cursor_end?: boolean } When true, defer briefly so the TUI can
---   apply appended text, then send Ctrl-E (see block comment on `send_terminal_ctrl_e`).
local function focus_terminal(opts)
  opts = opts or {}
  vim.schedule(function()
    local terminal = require("opencode.terminal").get()
    if not (terminal and terminal.win and vim.api.nvim_win_is_valid(terminal.win)) then
      return
    end

    -- Terminal buffers default to Normal mode when focused; the TUI needs Terminal mode.
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
  require("opencode.client").ensure_subscribed()
  if opts.focus then
    focus_terminal()
  end
end

---@class opencode.PromptOpts
---@field clear? boolean Clear the TUI input before appending
---@field submit? boolean Submit the TUI input after appending
---@field context? opencode.Context The context (defaults to current state)
---@field focus? boolean After append: focus the terminal, enter Terminal mode, move cursor to EOL (so `@` refs from Neovim land like a native TUI completion)

---Send a prompt to opencode with context expansion.
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

    require("opencode.client").ensure_subscribed(true)

    if opts.focus then
      focus_terminal({ cursor_end = not opts.submit })
    end

    context:clear()
  end)
end

---@alias opencode.Command
---| 'session.list'
---| 'session.new'
---| 'session.share'
---| 'session.interrupt'
---| 'session.compact'
---| 'session.page.up'
---| 'session.page.down'
---| 'session.half.page.up'
---| 'session.half.page.down'
---| 'session.first'
---| 'session.last'
---| 'session.undo'
---| 'session.redo'
---| 'prompt.submit'
---| 'prompt.clear'
---| 'agent.cycle'

---Execute a TUI command.
---@param command opencode.Command|string
function M.command(command)
  require("opencode.terminal").command(command, function(err, handled)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      return
    end

    if handled then
      return
    end

    require("opencode.server").get_url(function(url_err, url)
      if url_err or not url then
        if url_err then
          vim.notify(url_err, vim.log.levels.ERROR, { title = "opencode" })
        end
        return
      end

      vim.notify(
        "Broadcasting TUI command through shared backend: " .. command,
        vim.log.levels.WARN,
        { title = "opencode" }
      )
      require("opencode.client").execute_command(url, command)
    end)
  end)
end

---Show current status (terminal and SSE connection).
function M.status()
  local terminal = require("opencode.terminal").get()
  local sse = require("opencode.client").get_status()
  local bridge = require("opencode.bridge").get_state()

  local lines = {}
  table.insert(lines, "Terminal: " .. (terminal and "running" or "not running"))
  if sse.connected then
    table.insert(lines, "SSE: connected to " .. sse.url)
  else
    table.insert(lines, "SSE: not connected")
  end

  table.insert(lines, "Backend: " .. require("opencode.config").get_url())
  table.insert(lines, "Bridge: " .. (bridge.url or "not started"))
  table.insert(lines, "Route: " .. bridge.route)
  table.insert(lines, "Session: " .. (bridge.session_id or "none"))
  table.insert(lines, "Bridge requests: " .. tostring(bridge.request_count or 0))
  if bridge.last_request_line then
    table.insert(lines, "Last request: " .. bridge.last_request_line)
  end
  if bridge.last_error then
    table.insert(lines, "Bridge error: " .. bridge.last_error)
  end
  if bridge.last_body then
    local preview = bridge.last_body:gsub("\n", "\\n")
    if #preview > 160 then
      preview = preview:sub(1, 160) .. "..."
    end
    table.insert(lines, "Bridge body: " .. preview)
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "opencode" })
end

---Expose Context class for advanced usage.
M.Context = require("opencode.context")

return M
