# opencode.nvim

A simple Neovim plugin for [opencode](https://github.com/anomalyco/opencode) integration via [snacks.nvim](https://github.com/folke/snacks.nvim) terminal.

## Features

- Launch a local `opencode attach` TUI against a configured backend server
- Bridge the active attached TUI session back into Neovim
- Snacks terminal integration for toggling opencode
- Send prompts with context expansion (`@this`, `@buffer`, `@diagnostics`)
- Send direct review comments for the current line or visual range to the active session
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
        width = 0.43,
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
    { "<leader>as", function() require("opencode").attach_session_prompt() end, desc = "Attach session ID" },
    { "<leader>av", function() require("opencode").review_selection() end, mode = "n", desc = "Review line" },
    { "<leader>av", function() require("opencode").review_visual_selection() end, mode = "x", desc = "Review selection" },
  },
}
```

> **Note:** The trailing space in `@this ` dismisses opencode's file picker, preserving the line number in the reference.

### OpenCode TUI Plugin

To track the active attached TUI session, OpenCode also needs the bundled TUI bridge plugin.
Add it to your OpenCode `tui.json` plugin list, not `opencode.json`:

```json
{
  "plugin": [
    "file:///path/to/opencode.nvim/opencode-plugin"
  ]
}
```

The bridge plugin is inert unless `opencode.nvim` launches the TUI with its bridge environment variables.

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
require("opencode").attach_session("ses_...") -- Attach directly to a specific session id
require("opencode").attach_session_prompt()   -- Prompt for a session id, then attach
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
| :------- | :------ | :------------------------------------------------------------------------------------------------------ |
| `clear` | boolean | Clear the TUI input before appending |
| `submit` | boolean | Submit the TUI input after appending |
| `focus` | boolean | Focus the terminal after append; also enters Terminal mode and moves the cursor to EOL (see note below) |

> **`focus` behavior:** OpenCode’s `@` picker expects the cursor at the end of an `@path` fragment. With `focus = true`, the plugin focuses the snacks terminal, switches to Terminal mode, then jumps to the end of the prompt so appended refs match that expectation.

**Context Placeholders:**

| Placeholder | Expands To | Description |
| :------------- | :------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------- |
| `@this` | `@file.lua#21`, `@file.lua#21-30`, or `columns 8-15 in @file.lua#21` | Current line, line range, or single-line char selection (columns as text; `@…#` last for TUI autocomplete) |
| `@buffer` | `@file.lua` | Current buffer path |
| `@diagnostics` | (formatted list) | LSP diagnostics for current buffer |

> **Tip:** A trailing space (e.g., `@this `) dismisses opencode's file picker popup, which otherwise clears the line number from the reference.

### Reviews

```lua
-- Review the current line in the active attached TUI session.
require("opencode").review_selection()

-- Review the current visual range in the active attached TUI session.
require("opencode").review_visual_selection()
```

Reviews are sent directly through `POST /session/<sessionID>/prompt_async` using:

- one text part for your comment
- one ranged file attachment using `file://...?...start=&end=`

The review popup is a small cursor-anchored editor float:

- `Ctrl-S` submits in normal or insert mode
- `Ctrl-C` cancels in insert mode
- `q` cancels in normal mode
- `Enter` inserts a newline

Direct review sends reuse the last persisted user message's `agent`, `model`, and `variant` when available, so they generally match the active session's existing model choice without requiring OpenCode core changes.

### Commands

```lua
require("opencode").command("session.new")
require("opencode").command("session.list")
require("opencode").command("session.interrupt")
```

> **Attach mode note:** local prompt injection and a small set of common commands are scoped to the embedded terminal. Unsupported commands still fall back to OpenCode's shared `/tui/publish` backend event bus.

**Available Commands:**

| Command | Description |
| --------------------------- | -------------------------------- |
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
| ------------------ | --------------------------------------- |
| `:Opencode status` | Show terminal and SSE connection status |

`status` includes the bridged TUI route and active session so you can verify where direct reviews will be sent.

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

When the bundled TUI bridge plugin is installed, `opencode.nvim` also forwards the
active embedded session's local OpenCode events as autocmds:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "OpencodeActiveEvent:*",
  callback = function(args)
    local event = args.data.event
    if event.type == "session.idle" then
      vim.notify("active embedded OpenCode session is idle")
    end
  end,
})
```

`OpencodeEvent:*` comes from the server SSE stream.
`OpencodeActiveEvent:*` comes from the embedded TUI bridge plugin and is scoped to the currently attached session, which makes it suitable for local integrations like statusline or tmux hooks.

For `OpencodeActiveEvent:*`, `args.data` includes:
- `event`: the forwarded OpenCode event object
- `route`: the local TUI route when the event was observed
- `session_id`: the local attached session id when available
- `instance_id`: the Neovim bridge instance id
- `cwd`: the TUI working directory snapshot

## Acknowledgments

- Inspired by [NickvanDyke/opencode.nvim](https://github.com/NickvanDyke/opencode.nvim)
