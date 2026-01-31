---Configuration for opencode.nvim.
---
---Options are set via `vim.g.opencode_opts` before the plugin loads,
---then merged with defaults when this module is first required.
local M = {}

---@class opencode.Opts
---@field port? number Fixed port, or nil to auto-discover
---@field auto_reload? boolean Reload buffers on file.edited (default: true)
---@field terminal? opencode.TerminalConfig

---@class opencode.TerminalConfig
---@field cmd? string Command to run (default: "opencode --port")
---@field snacks? snacks.terminal.Opts Options passed to snacks.terminal

---@type opencode.Opts
vim.g.opencode_opts = vim.g.opencode_opts

---@type opencode.Opts
local defaults = {
  port = nil,
  auto_reload = true,
  terminal = {
    cmd = "opencode --port",
    snacks = {
      auto_close = true,
      win = {
        position = "right",
        width = 0.35,
        enter = false,
        wo = { winbar = "" },
        bo = { filetype = "opencode_terminal" },
      },
    },
  },
}

---@type opencode.Opts
M.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.g.opencode_opts or {})

-- Set --port in cmd if port is configured
local port = M.opts.port
if port and M.opts.terminal and M.opts.terminal.cmd then
  M.opts.terminal.cmd = M.opts.terminal.cmd:gsub("--port ?", "") .. " --port " .. tostring(port)
end

return M
