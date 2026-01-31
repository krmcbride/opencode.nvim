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
  "krmcbride/opencode.nvim",
  dependencies = {
    { "folke/snacks.nvim", opts = { terminal = { enabled = true } } },
  },
  init = function()
    vim.g.opencode_opts = {
      terminal = {
        -- Use --continue to resume the last session on startup
        cmd = "opencode --port --continue",
      },
    }
    -- Required for auto-reload when opencode edits files
    vim.o.autoread = true
  end,
  keys = {
    { "<leader>ac", function() require("opencode").toggle({ focus = true }) end, mode = { "n", "t" }, desc = "Toggle opencode" },
    { "<leader>aa", function() require("opencode").prompt("@this ", { focus = true }) end, mode = { "n", "x" }, desc = "Add to prompt" },
    { "<leader>ab", function() require("opencode").prompt("@buffer", { focus = true }) end, desc = "Add buffer to prompt" },
    { "<leader>ad", function() require("opencode").prompt("@diagnostics", { focus = true }) end, desc = "Add diagnostics to prompt" },
  },
}
```

> **Note:** The trailing space in `@this ` dismisses opencode's file picker, preserving the line number in the reference.

## Configuration

All options with their defaults:

```lua
vim.g.opencode_opts = {
  port = nil,           -- Fixed port, or nil to auto-discover
  auto_reload = true,   -- Reload buffers when opencode edits files
  terminal = {
    cmd = "opencode --port",  -- Add --continue to resume last session
    snacks = {                -- Options passed to snacks.terminal
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
require("opencode").toggle()                 -- Toggle the opencode terminal
require("opencode").toggle({ focus = true }) -- Toggle and focus the terminal
require("opencode").start()                  -- Start opencode if not running
require("opencode").start({ focus = true })  -- Start and focus the terminal
require("opencode").status()                 -- Show terminal and SSE connection status
```

### Prompts

```lua
-- Add context to the prompt (build up context, then submit in TUI)
require("opencode").prompt("@this ")        -- Current line or selection
require("opencode").prompt("@buffer")       -- Current file
require("opencode").prompt("@diagnostics")  -- LSP diagnostics

-- Focus the terminal after adding context
require("opencode").prompt("@this ", { focus = true })

-- Or submit immediately
require("opencode").prompt("Fix @diagnostics", { submit = true })
require("opencode").prompt("Explain this", { clear = true, submit = true })
```

**Prompt Options:**

| Option | Type | Description |
|:-------|:-----|:------------|
| `clear` | boolean | Clear the TUI input before appending |
| `submit` | boolean | Submit the TUI input after appending |
| `focus` | boolean | Focus the terminal window after sending |

**Context Placeholders:**

| Placeholder | Expands To | Description |
|:------------|:-----------|:------------|
| `@this` | `@file.lua#L21` or `#L21-30` | Current line, or selection in visual mode |
| `@buffer` | `@file.lua` | Current buffer path |
| `@diagnostics` | (formatted list) | LSP diagnostics for current buffer |

> **Tip:** A trailing space (e.g., `@this `) dismisses opencode's file picker popup, which otherwise clears the line number from the reference.

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
