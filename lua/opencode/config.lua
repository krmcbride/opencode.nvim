---Configuration for opencode.nvim.
---
---Options are configured via `require("opencode").setup(opts)`.
local M = {}

---@class opencode.Opts
---@field server? opencode.ServerConfig
---@field auto_reload? boolean Reload buffers on file.edited (default: true)
---@field terminal? opencode.TerminalConfig

---@class opencode.ServerConfig
---@field url? string Backend URL for API and attach mode
---@field username? string Basic auth username
---@field password? string Basic auth password
---@field password_env? string Environment variable containing the password

---@class opencode.TerminalConfig
---@field cmd? string Command to run (defaults to generated `opencode attach ...` command)
---@field dir? string Directory argument passed to `opencode attach`
---@field continue? boolean Continue the last session on launch (default: true)
---@field keys? table<string, string> Local key sequences for attach-mode commands
---@field width? number Terminal window width passed to snacks.win.width
---@field env? table<string, string|number|boolean> Environment variables for the opencode process

---@type opencode.Opts
local defaults = {
  server = {
    url = "http://127.0.0.1:4096",
    username = "opencode",
    password = nil,
    password_env = "OPENCODE_SERVER_PASSWORD",
  },
  auto_reload = true,
  terminal = {
    cmd = nil,
    dir = ".",
    continue = true,
    keys = {
      ["prompt.clear"] = "\005\021",
      ["prompt.submit"] = "\r",
      ["session.interrupt"] = "\027",
      ["session.list"] = "\024l",
      ["session.new"] = "\024n",
      ["agent.cycle"] = "\t",
    },
    width = 0.35,
    env = nil,
  },
}

---@param ... opencode.Opts?
---@return opencode.Opts
local function merge_opts(...)
  local merged = vim.deepcopy(defaults)
  for i = 1, select("#", ...) do
    local opts = select(i, ...)
    if type(opts) == "table" and not vim.tbl_isempty(opts) then
      merged = vim.tbl_deep_extend("force", merged, opts)
    end
  end
  return merged
end

---@type opencode.Opts
M.opts = merge_opts()

---@param opts? opencode.Opts
---@return opencode.Opts
function M.setup(opts)
  M.opts = merge_opts(opts)
  return M.opts
end

---@param name string|nil
---@return string|nil
local function getenv(name)
  if not name then
    return nil
  end

  local value = vim.env[name]
  if value == nil or value == "" then
    return nil
  end

  return value
end

---@return string
function M.get_url()
  return assert(M.opts.server and M.opts.server.url, "opencode server URL is not configured")
end

---@return { username: string, password: string }|nil
function M.get_auth()
  local server = M.opts.server or {}
  local password = server.password or getenv(server.password_env)
  if not password then
    return nil
  end

  return {
    username = server.username or "opencode",
    password = password,
  }
end

return M
