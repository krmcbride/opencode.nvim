---opencode.nvim public API.
---
---Main entry point for the plugin. Provides functions to control the terminal,
---send prompts with context expansion, and execute TUI commands.
local M = {}

---Focus the opencode terminal window if it exists.
local function focus_terminal()
  vim.schedule(function()
    local win = require("opencode.terminal").get()
    if win and win.win and vim.api.nvim_win_is_valid(win.win) then
      vim.api.nvim_set_current_win(win.win)
    end
  end)
end

---@class opencode.ToggleOpts
---@field focus? boolean Focus the terminal window after opening

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
---@field clear? boolean Clear the TUI input before
---@field submit? boolean Submit the TUI input after
---@field context? opencode.Context The context (defaults to current state)
---@field focus? boolean Focus the terminal window after sending prompt

---Send a prompt to opencode with context expansion.
---@param prompt string The prompt text (supports @this, @buffer, @diagnostics)
---@param opts? opencode.PromptOpts
function M.prompt(prompt, opts)
  opts = opts or {}
  local context = opts.context or require("opencode.context").new()
  local expanded = context:expand(prompt)

  require("opencode.server").get_port(function(err, port)
    if err or not port then
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      end
      context:clear()
      return
    end

    local function do_append()
      require("opencode.client").append_prompt(port, expanded, function()
        -- Subscribe to SSE for file reload events
        require("opencode.client").ensure_subscribed()

        if opts.submit then
          require("opencode.client").execute_command(port, "prompt.submit")
        end

        if opts.focus then
          focus_terminal()
        end

        context:clear()
      end)
    end

    if opts.clear then
      require("opencode.client").execute_command(port, "prompt.clear", do_append)
    else
      do_append()
    end
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
  require("opencode.server").get_port(function(err, port)
    if err or not port then
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      end
      return
    end
    require("opencode.client").execute_command(port, command)
  end)
end

---Show current status (terminal and SSE connection).
function M.status()
  local terminal = require("opencode.terminal").get()
  local sse = require("opencode.client").get_status()

  local lines = {}
  table.insert(lines, "Terminal: " .. (terminal and "running" or "not running"))
  if sse.connected then
    table.insert(lines, "SSE: connected on port " .. sse.port)
  else
    table.insert(lines, "SSE: not connected")
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "opencode" })
end

---Expose Context class for advanced usage.
M.Context = require("opencode.context")

return M
