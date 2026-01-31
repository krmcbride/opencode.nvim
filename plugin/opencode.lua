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
    -- Check if this is our terminal (filetype set in config.lua defaults)
    if vim.bo[ev.buf].filetype == "opencode_terminal" then
      require("opencode.client").sse_unsubscribe()
    end
  end,
  desc = "Clean up SSE connection when opencode terminal exits",
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
