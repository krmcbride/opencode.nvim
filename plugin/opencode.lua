-- Runtimepath plugin entrypoint.
--
-- Neovim sources `plugin/*.lua` automatically when the plugin is added to the
-- runtimepath. Keep this file focused on editor-side registration: autocmds,
-- user commands, and other startup hooks that should exist once the plugin is
-- loaded.

local augroup = vim.api.nvim_create_augroup("Opencode", { clear = true })

---Normalize a path to its absolute canonical form when possible.
---
---`fs_realpath()` resolves symlinks for existing paths. When that fails (for
---example, a file was deleted between the event and the reload), fall back to a
---normalized absolute path so buffer-name comparisons still work.
---@param path string|nil
---@return string|nil
local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

---Find loaded buffers whose resolved path matches the given path.
---@param path string|nil
---@return integer[]
local function matching_buffers(path)
  local target = normalize_path(path)
  if not target then
    return {}
  end

  ---@type integer[]
  local matches = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and normalize_path(name) == target then
        table.insert(matches, buf)
      end
    end
  end

  return matches
end

---Run `:checktime` for a specific buffer.
---
---OpenCode's SSE event tells us that a file changed, but that event alone does
---not reload any Neovim buffer. `autoread` only allows reloads when Neovim runs
---a file-change check; `:checktime` is the explicit "check now" step that makes
---Neovim re-stat the file and reload the buffer when it is safe to do so.
---
---When Neovim is currently in Terminal mode, use `:noautocmd checktime` to
---avoid unrelated scheduled autocmd work re-entering Normal mode while the
---embedded TUI owns the terminal.
---@param buf integer
local function checktime_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  local command = (mode:sub(1, 1) == "t" and "noautocmd checktime " or "checktime ") .. tostring(buf)
  pcall(function()
    vim.cmd(command)
  end)
end

-- Stop the embedded attach-mode terminal before Neovim teardown starts.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    pcall(require("opencode.terminal").stop)
  end,
  desc = "Stop opencode terminal on exit",
})

-- Close the SSE subscription when the opencode terminal job exits.
vim.api.nvim_create_autocmd("TermClose", {
  group = augroup,
  ---@param ev vim.api.keyset.create_autocmd.callback_args
  callback = function(ev)
    -- `opencode.terminal` marks its snacks buffer with this filetype.
    if vim.bo[ev.buf].filetype == "opencode_terminal" then
      require("opencode.client").sse_unsubscribe()
    end
  end,
  desc = "Clean up SSE connection when opencode terminal exits",
})

-- Re-enter Terminal mode when the opencode pane regains focus (e.g. closing a
-- float, ToggleTerm, or moving between splits).
--
-- snacks.nvim `auto_insert` only hooks BufEnter and calls `startinsert`
-- synchronously (see snacks.nvim lua/snacks/terminal.lua). We also hook
-- BufEnter and WinEnter, then `vim.schedule` + `startinsert` if the mode is
-- not already `t`. That covers WinEnter-only focus changes snacks does not
-- register, and deferred re-entry when an immediate `startinsert` does not
-- stick (overlays / focus-order quirks). If snacks already left us in `t`, we
-- no-op.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = augroup,
  ---@param ev vim.api.keyset.create_autocmd.callback_args
  callback = function(ev)
    if vim.bo[ev.buf].filetype ~= "opencode_terminal" then
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then
        return
      end
      if vim.api.nvim_get_current_buf() ~= ev.buf then
        return
      end
      if vim.api.nvim_get_mode().mode ~= "t" then
        vim.cmd.startinsert()
      end
    end)
  end,
  desc = "Restore Terminal mode when opencode terminal gains focus",
})

-- Reload matching buffers when the backend reports a file edit.
--
-- `OpencodeEvent:file.edited` and `OpencodeEvent:file.watcher.updated` only tell
-- us that something changed on disk. The actual buffer refresh still depends on
-- Neovim's normal external-file flow:
--
-- - `vim.o.autoread = true` permits reloading an unmodified buffer from disk
-- - `:checktime` performs the file-change check that notices the new mtime
--
-- Without `autoread`, Neovim may detect the change but will not transparently
-- refresh the buffer. Without `:checktime`, Neovim may not notice the change
-- until a later built-in checkpoint like focus or buffer switches.
--
-- Prefer a targeted `checktime {buf}` when the event payload names a file.
-- Fall back to plain `:checktime` when no matching loaded buffer is found.
vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = { "OpencodeEvent:file.edited", "OpencodeEvent:file.watcher.updated" },
  ---@param args vim.api.keyset.create_autocmd.callback_args
  callback = function(args)
    local opts = require("opencode.config").opts
    if opts.auto_reload ~= false then
      if not vim.o.autoread then
        vim.notify(
          "Set `vim.o.autoread = true` to enable opencode auto-reload",
          vim.log.levels.WARN,
          { title = "opencode" }
        )
      else
        vim.schedule(function()
          local event = args.data and args.data.event or nil
          local properties = type(event) == "table" and event.properties or nil
          local buffers = matching_buffers(type(properties) == "table" and properties.file or nil)

          if #buffers > 0 then
            for _, buf in ipairs(buffers) do
              checktime_buffer(buf)
            end
            return
          end

          vim.cmd("checktime")
        end)
      end
    end
  end,
  desc = "Reload buffers edited by opencode",
})

-- Re-scope the backend SSE subscription when the attached TUI changes cwd.
vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = "OpencodeSessionChanged",
  callback = function()
    require("opencode.client").ensure_subscribed()
  end,
  desc = "Keep opencode SSE subscription aligned with active session directory",
})

-- Minimal user-command surface for plugin-wide status and diagnostics.
---@param opts vim.api.keyset.create_user_command.command_args
vim.api.nvim_create_user_command("Opencode", function(opts)
  local cmd = opts.fargs[1]
  if cmd == "status" then
    require("opencode").status()
  else
    vim.notify("Unknown command: " .. (cmd or ""), vim.log.levels.ERROR, { title = "opencode" })
  end
end, {
  nargs = 1,
  complete = function()
    return { "status" }
  end,
  desc = "Opencode commands",
})
