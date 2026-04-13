# opencode.nvim

A Neovim plugin for running a local [opencode](https://github.com/anomalyco/opencode) attach-mode TUI inside a [snacks.nvim](https://github.com/folke/snacks.nvim) terminal, with Neovim-side session bridging and local integrations.

## Features

- Launch a local `opencode attach` TUI against a configured backend server
- Bridge the active attached TUI session back into Neovim
- Snacks terminal integration for toggling opencode
- Send prompts with context expansion (`@this`, `@buffer`, `@diagnostics`)
- Send direct review comments for the current line or visual range to the active session
- Auto-reload buffers when OpenCode edits files
- Expose `User` autocmds for notifications, statusline/tmux hooks, and other local integrations

## Setup

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "krmcbride/opencode.nvim",
  dependencies = {
    { "folke/snacks.nvim", opts = { terminal = { enabled = true } } },
  },
  opts = {
    server = {
      url = "http://127.0.0.1:4096",
    },
    terminal = {
      width = 0.43,
      env = {
        -- Extra environment for the child `opencode attach` process
        SOME_CHILD_PROCESS_FLAG = "1",
      },
    },
  },
  init = function()
    -- Required for auto-reload when opencode edits files
    vim.o.autoread = true
  end,
  keys = {
    { "<leader>ac", function() require("opencode").toggle({ focus = true }) end, mode = { "n", "t" }, desc = "Toggle opencode" },
    { "<leader>aa", function() require("opencode").prompt("@this", { focus = true }) end, mode = { "n", "x" }, desc = "Add to prompt" },
    { "<leader>ab", function() require("opencode").prompt("@buffer", { focus = true }) end, desc = "Add buffer to prompt" },
    { "<leader>ad", function() require("opencode").prompt("@diagnostics", { focus = true }) end, desc = "Add diagnostics to prompt" },
    { "<leader>as", function() require("opencode").attach_session_prompt() end, desc = "Attach session ID" },
    { "<leader>av", function() require("opencode").review_selection() end, mode = "n", desc = "Review line" },
    { "<leader>av", function() require("opencode").review_visual_selection() end, mode = "x", desc = "Review selection" },
  },
}
```

If you are not using `lazy.nvim`, call `require("opencode").setup({ ... })` yourself before using the plugin API.

## Configuration

All options with their defaults:

```lua
require("opencode").setup({
  server = {
    url = "http://127.0.0.1:4096", -- Backend server URL
  },
  auto_reload = true,          -- Reload matching buffers on OpenCode edit events
  terminal = {
    cmd = nil,                -- Optional custom attach command
    dir = ".",               -- Directory passed to `opencode attach`
    continue = true,          -- Add `--continue` when launching the TUI
    width = 0.35,
    env = nil,
  },
})
```

> **`terminal.env` note:** `opts.terminal.env` is only passed to the child `opencode attach` process. Backend/server feature flags usually need to be configured on the backend server process itself, not here.
> **Auto-reload note:** `auto_reload = true` still depends on Neovim `autoread`; set `vim.o.autoread = true` in your config. External non-OpenCode edits only surface through `OpencodeEvent:file.watcher.updated` when the backend server file watcher is enabled.
> **Auth note:** backend auth is read from Neovim's `OPENCODE_SERVER_PASSWORD` and optional `OPENCODE_SERVER_USERNAME` environment variables. If you source credentials from a file or secret manager, populate `vim.env` before calling `require("opencode").setup(...)`.
> **Width:** Set terminal width with `opts.terminal.width`.
> Other terminal behavior uses plugin defaults.

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

## API

### Terminal Control

```lua
require("opencode").toggle()                 -- Toggle the opencode terminal
require("opencode").toggle({ focus = true }) -- Toggle and focus the terminal
require("opencode").start()                  -- Start opencode if not running
require("opencode").start({ focus = true })  -- Start and focus the terminal
require("opencode").attach_session("ses_...") -- Attach directly to a specific session id
require("opencode").attach_session_prompt()   -- Prompt for a session id, then attach
require("opencode").status()                 -- Show terminal, backend, bridge, and SSE status
```

### Prompts

```lua
-- Add context to the prompt (build up context, then submit in TUI)
require("opencode").prompt("@this")         -- Current line or selection
require("opencode").prompt("@buffer")       -- Current file
require("opencode").prompt("@diagnostics")  -- LSP diagnostics

-- Focus the terminal after adding context
require("opencode").prompt("@this", { focus = true })

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

These placeholders are defined by `opencode.nvim`, not by OpenCode itself. The plugin expands them into plain prompt text and native OpenCode-style file references before sending the prompt to the attached TUI/backend.

They only work when prompt text flows through `opencode.nvim` APIs like `require("opencode").prompt(...)` or mappings built on top of those APIs. Typing `@this`, `@buffer`, or `@diagnostics` directly into the OpenCode TUI does not trigger any special expansion.

| Placeholder | Expands To | Description |
| :------------- | :------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------- |
| `@this` | `@file.lua#21`, `@file.lua#21-30`, or `columns 8-15 in @file.lua#21` | Current line, line range, or single-line char selection (columns as text; `@…#` last for TUI autocomplete) |
| `@buffer` | `@file.lua` | Current buffer path |
| `@diagnostics` | Prompt text with a formatted diagnostic list and trailing `@file` ref | LSP diagnostics for current buffer |

> **Tip:** `@this` expands to a native OpenCode file reference like `@file.lua#21` or `@file.lua#21-30`. With `focus = true`, `opencode.nvim` leaves the TUI cursor at end-of-line so the attached TUI can continue native `@` completion from that ref. Add a trailing space only if you explicitly want to dismiss the picker; the space is sent literally.

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

## User Commands

| Command | Description |
| ------------------ | --------------------------------------- |
| `:Opencode status` | Show terminal, backend, bridge, and SSE status |

`status` includes the backend URL, SSE directory, bridge URL, bridged TUI route, and active session so you can verify where events and direct reviews are going.

## Events

`opencode.nvim` exposes three useful integration surfaces:

- `OpencodeEvent:*` for backend SSE events in the currently subscribed backend directory
- `OpencodeActiveEvent:*` for local embedded-TUI events scoped to the currently attached session
- `OpencodeSessionChanged` for coarse route/session/cwd changes reported by the embedded TUI

That gives you enough surface to build your own notifications, tmux/workmux or window-status hooks, statusline components, per-session UI state, or any other local automation without hard-coding those integrations into the plugin.

Register these from your normal Neovim config with `vim.api.nvim_create_autocmd("User", ...)` after loading the plugin.

### `OpencodeEvent:*`

`OpencodeEvent:*` comes from the backend SSE stream. This is the right surface for backend file/edit lifecycle events and server connection state.

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

For `OpencodeEvent:*`, `args.data` includes:

- `event`: the backend SSE event object
- `url`: the backend base URL that produced the event

### `OpencodeActiveEvent:*`

When the bundled TUI bridge plugin is installed, `opencode.nvim` also forwards the active embedded session's local OpenCode events as autocmds.

This is the most useful surface for integrations that care about the embedded TUI the user is actually looking at, for example:

- desktop notifications when the active session goes idle or errors
- tmux/workmux or window-title status updates while the agent is busy or waiting on a question/permission prompt
- local UI reactions to `question.asked` / `permission.asked` without watching every backend event globally

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

`OpencodeActiveEvent:*` comes from the embedded TUI bridge plugin and is scoped to the currently attached session, which makes it suitable for local integrations like notifications, statusline widgets, or tmux/workmux hooks.

Currently forwarded event types:

- `session.status`
- `session.idle`
- `session.error`
- `permission.asked`
- `permission.replied`
- `question.asked`
- `question.replied`

For `OpencodeActiveEvent:*`, `args.data` includes:

- `event`: the forwarded OpenCode event object
- `route`: the local TUI route when the event was observed
- `session_id`: the local attached session id when available
- `instance_id`: the Neovim bridge instance id
- `cwd`: the TUI working directory snapshot

### `OpencodeSessionChanged`

`OpencodeSessionChanged` fires when the local bridge reports that the active embedded TUI route, session id, or cwd changed.

This is the right surface for integrations that want coarse session-aware state rather than every individual lifecycle event, for example:

- updating a statusline or winbar with the current attached session id
- mirroring the active OpenCode cwd into tmux/window metadata
- maintaining per-session caches keyed by `(instance_id, session_id)`

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "OpencodeSessionChanged",
  callback = function(args)
    local data = args.data
    vim.notify(("route=%s session=%s cwd=%s"):format(data.route, data.session_id or "none", data.cwd or "none"))
  end,
})
```

For `OpencodeSessionChanged`, `args.data` includes:

- `route`: the local TUI route when the event was observed
- `session_id`: the active embedded OpenCode session id when available
- `instance_id`: the Neovim bridge instance id
- `cwd`: the TUI working directory snapshot

## Acknowledgments

- Inspired by [NickvanDyke/opencode.nvim](https://github.com/NickvanDyke/opencode.nvim)
