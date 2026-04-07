---Input helpers for opencode.nvim.
local M = {}

---@param opts { prompt?: string, default?: string, title?: string }
---@param on_confirm fun(value?: string)
function M.review(opts, on_confirm)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.win then
    local width = math.max(48, math.min(72, vim.o.columns - 8))
    local done = false
    local win

    local function finish(value)
      if done then
        return
      end
      done = true
      if win and win:valid() then
        win:close()
      end
      vim.schedule(function()
        on_confirm(value)
      end)
    end

    win = snacks.win({
      enter = true,
      show = false,
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      min_width = 48,
      max_width = 72,
      height = 5,
      min_height = 4,
      max_height = 8,
      border = "rounded",
      title = opts.title or opts.prompt,
      title_pos = "left",
      footer_keys = { "<cr>", "<s-cr>", "<c-j>", "<esc>" },
      bo = {
        buftype = "nofile",
        bufhidden = "wipe",
        filetype = "markdown",
        modifiable = true,
      },
      wo = {
        wrap = true,
        linebreak = true,
        breakindent = true,
        spell = false,
      },
      keys = {
        submit = {
          "<cr>",
          function(self)
            finish(vim.trim(self:text()))
          end,
          desc = "Submit",
          mode = { "n", "i" },
        },
        newline = {
          "<c-j>",
          "<cr>",
          desc = "New line",
          mode = "i",
        },
        newline_shift = {
          "<s-cr>",
          "<cr>",
          desc = "New line",
          mode = "i",
        },
        cancel = {
          "<esc>",
          function()
            finish(nil)
          end,
          desc = "Cancel",
          mode = { "n", "i" },
        },
      },
      on_win = function()
        vim.schedule(function()
          vim.cmd.startinsert()
        end)
      end,
      on_close = function()
        if not done then
          done = true
          vim.schedule(function()
            on_confirm(nil)
          end)
        end
      end,
    })

    win:show()
    if opts.default and opts.default ~= "" then
      local lines = vim.split(opts.default, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, lines)
      local last = lines[#lines] or ""
      vim.api.nvim_win_set_cursor(win.win, { #lines, #last })
    end
    return
  end

  vim.ui.input(opts, on_confirm)
end

return M
