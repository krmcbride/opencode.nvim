---Terminal management for opencode via snacks.nvim.
---
---Provides toggle/start/stop for the opencode TUI running in a snacks terminal.
---
---Shutdown uses the API: POST /tui/publish with "app.exit" command, which
---triggers opencode's clean exit path with process.exit(0) - the same code
---path as pressing Ctrl+C in the TUI.
local M = {}

-- Track the port for API calls
local tracked_port = nil

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

local function get_opts()
  local config = require("opencode.config").opts.terminal or {}
  local cmd = config.cmd or "opencode --port"
  local snacks_opts = vim.deepcopy(config.snacks or {})

  -- Environment variables for opencode are configured via terminal.env.
  snacks_opts.env = normalize_env(config.env)

  return cmd, snacks_opts
end

---Get the existing terminal window (if any).
---@return snacks.win|nil
function M.get()
  local cmd, snacks_opts = get_opts()
  local opts = vim.tbl_deep_extend("force", snacks_opts, { create = false })
  return require("snacks.terminal").get(cmd, opts)
end

---Try to discover and cache the server port.
---@return number|nil
local function get_port()
  if tracked_port then
    return tracked_port
  end
  -- Try to discover port from SSE connection state first (already connected)
  local client_status = require("opencode.client").get_status()
  if client_status.port then
    tracked_port = client_status.port
    return tracked_port
  end
  return nil
end

---Toggle the opencode terminal.
function M.toggle()
  local cmd, snacks_opts = get_opts()
  require("snacks.terminal").toggle(cmd, snacks_opts)
end

---Start the opencode terminal if not already running.
function M.start()
  if not M.get() then
    local cmd, snacks_opts = get_opts()
    require("snacks.terminal").open(cmd, snacks_opts)
  end
end

---Stop the opencode terminal.
function M.stop()
  local port = get_port()
  local win = M.get()

  if port then
    require("opencode.client").exit(port)
    tracked_port = nil
  end

  if win then
    win:close()
  end
end

return M
