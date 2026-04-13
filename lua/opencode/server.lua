---Backend resolution for opencode.nvim.
---
---This plugin targets a configured opencode server and launches local TUI
---clients with `opencode attach`.
local M = {}

---Resolve and validate the configured server URL.
---@param callback fun(err: string|nil, url: string|nil)
function M.get_url(callback)
  local url = require("opencode.config").get_url()
  local ok, result = pcall(require("opencode.client").get_path, url)
  if ok and result then
    callback(nil, url)
    return
  end

  callback("No `opencode` responding at configured URL: " .. url, nil)
end

return M
