---Configuration for opencode.nvim.
---
---Options are configured via `require("opencode").setup(opts)`.
local M = {}

---@class opencode.Opts
---@field server? opencode.ServerConfig
---@field auto_reload? boolean Reload buffers on file.edited (default: true)
---@field terminal? opencode.TerminalConfig
---@field editor_context? opencode.EditorContextConfig

---@class opencode.ServerConfig
---@field url? string Backend URL for API and attach mode

---@class opencode.TerminalConfig
---@field cmd? string Command to run (defaults to generated `opencode attach ...` command)
---@field dir? string Directory argument passed to `opencode attach`
---@field continue? boolean Default `--continue` behavior for terminal launches (default: true)
---@field width? number Terminal window width passed to snacks.win.width
---@field env? table<string, string|number|boolean> Environment variables for the opencode process

---@class opencode.EditorContextConfig
---@field enabled? boolean Enable native OpenCode editor context over WebSocket (default: true)

---@type opencode.Opts
local defaults = {
  server = {
    url = "http://127.0.0.1:4096",
  },
  auto_reload = true,
  editor_context = {
    enabled = true,
  },
  terminal = {
    cmd = nil,
    dir = ".",
    continue = true,
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

---@return string
function M.get_url()
  return assert(M.opts.server and M.opts.server.url, "opencode server URL is not configured")
end

---Read backend auth from the standard OpenCode environment variables visible
---to the Neovim process.
---
---`OPENCODE_SERVER_USERNAME` defaults to `opencode` upstream when omitted.
---@return { username: string, password: string }|nil
function M.get_auth()
  local password = vim.env.OPENCODE_SERVER_PASSWORD
  if password == "" then
    password = nil
  end
  if not password then
    return nil
  end

  return {
    username = vim.env.OPENCODE_SERVER_USERNAME or "opencode",
    password = password,
  }
end

return M
