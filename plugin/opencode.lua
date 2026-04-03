-- opencode.nvim plugin autoload

local augroup = vim.api.nvim_create_augroup("Opencode", { clear = true })

-- Stop terminal on VimLeavePre (before Neovim starts cleanup)
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    pcall(require("opencode.terminal").stop)
  end,
  desc = "Stop opencode terminal on exit",
})

-- Clean up SSE connection when terminal exits
vim.api.nvim_create_autocmd("TermClose", {
  group = augroup,
  callback = function(ev)
    -- Check if this is our terminal (see `bo.filetype` in lua/opencode/terminal.lua)
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
  desc = "Enter insert mode when opencode terminal gains focus",
})

-- Auto-reload files edited by opencode
vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = "OpencodeEvent:file.edited",
  callback = function()
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
          vim.cmd("checktime")
        end)
      end
    end
  end,
  desc = "Reload buffers edited by opencode",
})

-- User commands
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
