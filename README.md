# opencode.nvim

A simple Neovim plugin for [opencode](https://github.com/anomalyco/opencode) integration via [snacks.nvim](https://github.com/folke/snacks.nvim) terminal.

## Features

- Launch a local `opencode attach` TUI against a configured backend server
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
      server = {
        url = "http://127.0.0.1:4096",
        username = "opencode",
        password_env = "OPENCODE_SERVER_PASSWORD",
      },
      terminal = {
        width = vim.g.is_laptop and 0.54 or 0.43,
        env = {
          -- Example feature flags
          OPENCODE_EXPERIMENT_A = 1,
          OPENCODE_EXPERIMENT_B = "enabled",
        },
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
  server = {
    url = "http://127.0.0.1:4096",      -- Backend server URL
    username = "opencode",              -- Basic auth username
    password = nil,                      -- Optional inline password
    password_env = "OPENCODE_SERVER_PASSWORD", -- Or read password from env
  },
  auto_reload = true,
  terminal = {
    cmd = nil,                -- Optional custom attach command
    dir = ".",               -- Directory passed to `opencode attach`
    continue = true,          -- Add `--continue` when launching the TUI
    keys = {                  -- Defaults for local attach-mode key sequences
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
```

> **Environment variables:** Set OpenCode feature flags in `vim.g.opencode_opts.terminal.env`.
> **Auth note:** generated attach mode currently assumes the backend username is `opencode`.
> **Width:** Set terminal width with `vim.g.opencode_opts.terminal.width`.
> Other terminal behavior uses plugin defaults.

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

| Option   | Type    | Description                                                                                             |
| :------- | :------ | :------------------------------------------------------------------------------------------------------ |
| `clear`  | boolean | Clear the TUI input before appending                                                                    |
| `submit` | boolean | Submit the TUI input after appending                                                                    |
| `focus`  | boolean | Focus the terminal after append; also enters Terminal mode and moves the cursor to EOL (see note below) |

> **`focus` behavior:** OpenCode’s `@` picker expects the cursor at the end of an `@path` fragment. With `focus = true`, the plugin focuses the snacks terminal, switches to Terminal mode, then jumps to the end of the prompt so appended refs match that expectation.

**Context Placeholders:**

| Placeholder    | Expands To                                                           | Description                                                                                                |
| :------------- | :------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------- |
| `@this`        | `@file.lua#21`, `@file.lua#21-30`, or `columns 8-15 in @file.lua#21` | Current line, line range, or single-line char selection (columns as text; `@…#` last for TUI autocomplete) |
| `@buffer`      | `@file.lua`                                                          | Current buffer path                                                                                        |
| `@diagnostics` | (formatted list)                                                     | LSP diagnostics for current buffer                                                                         |

> **Tip:** A trailing space (e.g., `@this `) dismisses opencode's file picker popup, which otherwise clears the line number from the reference.

### Commands

```lua
require("opencode").command("session.new")
require("opencode").command("session.list")
require("opencode").command("session.interrupt")
```

> **Attach mode note:** local prompt injection and a small set of common commands are scoped to the embedded terminal. Unsupported commands still fall back to OpenCode's shared `/tui/publish` backend event bus.

**Available Commands:**

| Command                     | Description                      |
| --------------------------- | -------------------------------- |
| `session.list`              | List sessions                    |
| `session.new`               | Start new session                |
| `session.share`             | Share current session            |
| `session.interrupt`         | Interrupt current session        |
| `session.compact`           | Compact session (reduce context) |
| `session.page.up/down`      | Scroll messages                  |
| `session.half.page.up/down` | Scroll half page                 |
| `session.first/last`        | Jump to first/last message       |
| `session.undo/redo`         | Undo/redo last action            |
| `prompt.submit`             | Submit the TUI input             |
| `prompt.clear`              | Clear the TUI input              |
| `agent.cycle`               | Cycle the selected agent         |

## User Commands

| Command            | Description                             |
| ------------------ | --------------------------------------- |
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
