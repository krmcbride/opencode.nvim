---Input helpers for opencode.nvim.
local M = {}

---@param opts { prompt?: string, default?: string, completion?: string }
---@param on_confirm fun(value?: string)
function M.simple(opts, on_confirm)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.input then
    snacks.input(opts, on_confirm)
    return
  end

  vim.ui.input(opts, on_confirm)
end

---@param opts { prompt?: string, default?: string, title?: string }
---@param on_confirm fun(value?: string)
function M.review(opts, on_confirm)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.win then
    local width = math.max(48, math.min(72, vim.o.columns - 8))
    local done = false
    local win
    local parent_win = vim.api.nvim_get_current_win()
    local parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
    local augroup = vim.api.nvim_create_augroup("opencode_review_input_" .. tostring(vim.uv.hrtime()), { clear = true })

    local function set_footer(mode)
      if not win then
        return
      end

      if mode == "i" then
        win.opts.footer = {
          { " ", "SnacksFooter" },
          { " Ctrl-S ", "SnacksFooterKey" },
          { " Submit ", "SnacksFooterDesc" },
          { " ", "SnacksFooter" },
          { " Ctrl-C ", "SnacksFooterKey" },
          { " Cancel ", "SnacksFooterDesc" },
          { " ", "SnacksFooter" },
        }
      else
        win.opts.footer = {
          { " ", "SnacksFooter" },
          { " Ctrl-S ", "SnacksFooterKey" },
          { " Submit ", "SnacksFooterDesc" },
          { " ", "SnacksFooter" },
          { " q ", "SnacksFooterKey" },
          { " Cancel ", "SnacksFooterDesc" },
          { " ", "SnacksFooter" },
        }
      end

      if win:valid() then
        vim.api.nvim_win_set_config(win.win, {
          footer = win.opts.footer,
          footer_pos = win.opts.footer_pos or "center",
        })
      end
    end

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
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
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
      relative = "win",
      win = parent_win,
      bufpos = { parent_cursor[1] - 1, parent_cursor[2] },
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
          mode = { "n", "i" },
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
        set_footer("i")
        vim.api.nvim_create_autocmd("InsertEnter", {
          group = augroup,
          buffer = win.buf,
          callback = function()
            set_footer("i")
          end,
        })
        vim.api.nvim_create_autocmd("InsertLeave", {
          group = augroup,
          buffer = win.buf,
          callback = function()
            set_footer("n")
          end,
        })
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
