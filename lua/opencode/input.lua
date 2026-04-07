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
    local parent_win = vim.api.nvim_get_current_win()

    local function restore_parent()
      vim.schedule(function()
        pcall(vim.cmd.stopinsert)
        if vim.api.nvim_win_is_valid(parent_win) then
          vim.api.nvim_set_current_win(parent_win)
        end
      end)
    end

    local function finish(value)
      if done then
        return
      end
      done = true
      if win and win:valid() then
        win:close()
      end
      restore_parent()
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
      footer_keys = { "<c-s>", "q", "<c-c>" },
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
        q = false,
        submit = {
          "<c-s>",
          function(self)
            finish(vim.trim(self:text()))
          end,
          desc = "Submit",
          mode = "i",
        },
        cancel = {
          "q",
          function()
            finish(nil)
          end,
          desc = "Cancel",
          mode = "n",
        },
        cancel_ctrl = {
          "<c-c>",
          function()
            finish(nil)
          end,
          desc = "Cancel",
          mode = "i",
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
          restore_parent()
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
