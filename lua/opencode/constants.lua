---Shared constants for opencode.nvim.
---
---These values are consumed across multiple modules and must stay consistent
---for the plugin's internal wiring to keep working.
local M = {}

---Filetype assigned to the embedded snacks terminal buffer.
---Autocmds and other terminal-specific behavior key off this value.
M.TERMINAL_FILETYPE = "opencode_terminal"

---Local bridge HTTP path used by the bundled OpenCode TUI plugin.
M.BRIDGE_PATH = "/opencode/session"

---Environment variables passed to the embedded TUI so it can publish session
---state back to this Neovim instance. Keep these aligned with
---`opencode-plugin/tui.ts`.
M.BRIDGE_ENV = {
  URL = "OPENCODE_NVIM_BRIDGE_URL",
  TOKEN = "OPENCODE_NVIM_BRIDGE_TOKEN",
  INSTANCE_ID = "OPENCODE_NVIM_INSTANCE_ID",
}

return M
