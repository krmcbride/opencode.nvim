# opencode.nvim

A simple Neovim plugin for [opencode](https://github.com/anomalyco/opencode) integration via [snacks.nvim](https://github.com/folke/snacks.nvim) terminal.

## Features

- Auto-discover running `opencode` processes in Neovim's CWD
- Snacks terminal integration for toggling opencode
- Send prompts with context expansion (`@this`, `@buffer`, `@diagnostics`)
- Execute TUI commands (session management, scrolling, etc.)
- Auto-reload buffers when opencode edits files

## Setup

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-username/opencode.nvim",
  dependencies = {
    { "folke/snacks.nvim", opts = { terminal = { enabled = true } } },
  },
  -- Set options before plugin loads
  init = function()
    ---@type opencode.Opts
    vim.g.opencode_opts = {
      -- port = nil,        -- nil = auto-discover, number = fixed port
      -- auto_reload = true,
      -- terminal = {
      --   cmd = "opencode --port",
      --   snacks = { ... },
      -- },
    }
    -- Required for auto-reload
    vim.o.autoread = true
  end,
  -- Lazy-load on keymap
  keys = {
    { "<C-.>", function() require("opencode").toggle() end, mode = { "n", "t" }, desc = "Toggle opencode" },
    { "<leader>oa", function() require("opencode").prompt("@this ") end, mode = { "n", "x" }, desc = "Add to prompt" },
    { "<leader>od", function() require("opencode").prompt("Fix @diagnostics", { submit = true }) end, desc = "Fix diagnostics" },
    { "<leader>on", function() require("opencode").command("session.new") end, desc = "New session" },
    { "<leader>ol", function() require("opencode").command("session.list") end, desc = "List sessions" },
  },
}
```

## Configuration

```lua
---@type opencode.Opts
vim.g.opencode_opts = {
  port = nil,           -- Fixed port, or nil to auto-discover
  auto_reload = true,   -- Reload buffers on file.edited events
  terminal = {
    cmd = "opencode --port",
    snacks = {
      auto_close = true,
      win = {
        position = "right",
        width = 0.35,
        enter = false,
      },
    },
  },
}
```

## API

### Terminal Control

```lua
require("opencode").toggle()  -- Toggle the opencode terminal
require("opencode").start()   -- Start opencode if not running
require("opencode").status()  -- Show terminal and SSE connection status
```

### Prompts

```lua
-- Send a prompt with context expansion
require("opencode").prompt("Explain @this", { submit = true })
require("opencode").prompt("Fix @diagnostics", { clear = true, submit = true })
```

**Context Placeholders:**

| Placeholder | Example Output | Description |
|:----------------|:----------------------------|:-----------------------------------|
| `@this` | `@file.lua#L21` or `#L21-30`| Selection range, or current line |
| `@buffer` | `@file.lua` | Current buffer path |
| `@diagnostics` | (formatted list) | LSP diagnostics for current buffer |

### Commands

```lua
require("opencode").command("session.new")
require("opencode").command("session.list")
require("opencode").command("session.interrupt")
```

**Available Commands:**

| Command | Description |
| ------------------------ | ---------------------------------- |
| `session.list` | List sessions |
| `session.new` | Start new session |
| `session.share` | Share current session |
| `session.interrupt` | Interrupt current session |
| `session.compact` | Compact session (reduce context) |
| `session.page.up/down` | Scroll messages |
| `session.half.page.up/down` | Scroll half page |
| `session.first/last` | Jump to first/last message |
| `session.undo/redo` | Undo/redo last action |
| `prompt.submit` | Submit the TUI input |
| `prompt.clear` | Clear the TUI input |
| `agent.cycle` | Cycle the selected agent |

## User Commands

| Command | Description |
|---------|-------------|
| `:Opencode status` | Show terminal and SSE connection status |

## Events

opencode.nvim forwards SSE events as autocmds:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "OpencodeEvent:*",
  callback = function(args)
    local event = args.data.event
    if event.type == "session.idle" then
      vim.notify("opencode finished responding")
    end
  end,
})
```

## Acknowledgments

- Inspired by [NickvanDyke/opencode.nvim](https://github.com/NickvanDyke/opencode.nvim)
