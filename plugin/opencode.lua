-- Runtimepath plugin entrypoint.
--
-- Neovim sources `plugin/*.lua` automatically when the plugin is added to the
-- runtimepath. Keep this file focused on editor-side registration: autocmds,
-- user commands, and other startup hooks that should exist once the plugin is
-- loaded.

local client = require("opencode.client")
local opencode = require("opencode")
local review_queue = require("opencode.review_queue")
local terminal = require("opencode.terminal")
local reload = require("opencode.reload")

local augroup = vim.api.nvim_create_augroup("Opencode", { clear = true })

-- Stop the embedded attach-mode terminal before Neovim teardown starts.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    pcall(terminal.stop)
  end,
  desc = "Stop opencode terminal on exit",
})

-- Close the SSE subscription when the opencode terminal job exits.
vim.api.nvim_create_autocmd("TermClose", {
  group = augroup,
  ---@param ev vim.api.keyset.create_autocmd.callback_args
  callback = function(ev)
    if not terminal.owns_buf(ev.buf) then
      return
    end

    client.sse_unsubscribe()
    terminal.forget_buf(ev.buf)
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
    if not terminal.owns_buf(ev.buf) then
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

-- V2 does not emit every file edit yet. Execution boundaries and reconnects
-- also check project buffers; modified buffers always remain untouched.
vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = {
    "OpencodeEvent:filesystem.changed",
    "OpencodeEvent:session.tool.success",
    "OpencodeEvent:session.tool.failed",
    "OpencodeEvent:session.shell.ended",
    "OpencodeEvent:session.execution.succeeded",
    "OpencodeEvent:session.execution.failed",
    "OpencodeEvent:session.execution.interrupted",
    "OpencodeEvent:session.revert.committed",
  },
  callback = function(ev)
    local data = ev.data
    local event = data.event
    local file = event.type == "filesystem.changed" and event.data.file or nil
    if type(file) ~= "string" then
      file = nil
    end
    reload.request({ file = file, directory = data.directory })
  end,
  desc = "Check buffers after OpenCode file changes or execution settles",
})

vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = "OpencodeResync",
  callback = function(ev)
    reload.request({ directory = ev.data.cwd })
  end,
  desc = "Check disk state after OpenCode reconnects",
})

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
  group = augroup,
  callback = function()
    if client.is_connected() then
      reload.request({ directory = client.get_status().directory })
    end
  end,
  desc = "Check OpenCode project buffers when returning to the editor",
})

-- The stream stays global; each event uses the current TUI location.
vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = "OpencodeSessionChanged",
  callback = function()
    client.ensure_subscribed()
    if client.is_connected() then
      client.resync()
    end
  end,
  desc = "Keep opencode SSE subscription aligned with active session directory",
})

-- Repaint queued review gutter marks when matching buffers are loaded or shown.
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "BufEnter" }, {
  group = augroup,
  ---@param ev vim.api.keyset.create_autocmd.callback_args
  callback = function(ev)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        review_queue.refresh_signs(ev.buf)
      end
    end)
  end,
  desc = "Refresh opencode review queue signs",
})

-- Minimal user-command surface for plugin-wide status and diagnostics.
local commands = {
  status = function()
    opencode.status()
  end,
  ["review-queue-open"] = function()
    opencode.open_review_queue()
  end,
  ["review-queue-edit"] = function()
    opencode.edit_review_queue_comment()
  end,
  ["review-queue-delete"] = function()
    opencode.delete_review_queue_comment()
  end,
  ["review-queue-send"] = function()
    opencode.send_review_queue()
  end,
  ["review-queue-clear"] = function()
    opencode.clear_review_queue()
  end,
}
local command_names = vim.tbl_keys(commands)
table.sort(command_names)

---@param opts vim.api.keyset.create_user_command.command_args
vim.api.nvim_create_user_command("Opencode", function(opts)
  local cmd = opts.fargs[1]
  local handler = commands[cmd]
  if handler then
    handler()
  else
    vim.notify("Unknown command: " .. (cmd or ""), vim.log.levels.ERROR, { title = "opencode" })
  end
end, {
  nargs = 1,
  complete = function()
    return command_names
  end,
  desc = "Opencode commands",
})
