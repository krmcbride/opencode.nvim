---Input UI helpers for opencode.nvim.
---
---This module is a small adapter layer around Snacks-based input UIs.
---`opencode.nvim` already depends on Snacks for its embedded terminal/window
---behavior, so input helpers also treat Snacks as a required dependency.
---
---It currently exposes two input experiences:
---1. `simple()` for single-line prompts
---2. `review()` for the richer review-message composer
local M = {}
local Snacks = require("snacks")

---@alias opencode.input.ConfirmCallback fun(value?: string, action?: string)

---@class opencode.input.SimpleOpts
---@field prompt? string
---@field default? string
---@field completion? string

---@class opencode.input.ReviewOpts
---@field prompt? string
---@field default? string
---@field title? string
---@field action_label? string
---@field actions? opencode.input.ReviewAction[]

---@class opencode.input.ReviewAction
---@field name string
---@field key string
---@field key_label string
---@field label string
---@field mode? string|string[]

---Show a simple single-line input prompt.
---
---Uses `snacks.input()`.
---@param opts opencode.input.SimpleOpts
---@param on_confirm opencode.input.ConfirmCallback
function M.simple(opts, on_confirm)
  Snacks.input(opts, on_confirm)
end

---Show the review-message composer.
---
---When Snacks is available, this opens a small cursor-anchored multiline editor
---float using `snacks.win`, with explicit submit/cancel key bindings and focus
---restoration back to the originating window.
---
---@param opts opencode.input.ReviewOpts
---@param on_confirm opencode.input.ConfirmCallback
function M.review(opts, on_confirm)
  local width = math.max(48, math.min(72, vim.o.columns - 8))
  local raw_actions = opts.actions
    or {
      {
        name = "submit",
        key = "<c-s>",
        key_label = "Ctrl-S",
        label = opts.action_label or "Submit",
        mode = { "n", "i" },
      },
    }
  local actions = {}
  for index, action in ipairs(raw_actions) do
    assert(
      type(action.name) == "string" and action.name ~= "",
      "review action " .. tostring(index) .. " requires a name"
    )
    assert(type(action.key) == "string" and action.key ~= "", "review action " .. tostring(index) .. " requires a key")
    table.insert(actions, {
      name = action.name,
      key = action.key,
      key_label = action.key_label or action.key,
      label = action.label or action.name,
      mode = action.mode or { "n", "i" },
    })
  end
  local done = false
  ---@type snacks.win|nil
  local win
  ---Anchor the review composer to the window/cursor that requested it.
  local parent_win = vim.api.nvim_get_current_win()
  local parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
  local augroup = vim.api.nvim_create_augroup("opencode_review_input_" .. tostring(vim.uv.hrtime()), { clear = true })

  ---@param mode "i"|"n"
  local function set_footer(mode)
    if not win then
      return
    end

    local footer = {
      { " ", "SnacksFooter" },
    }
    for _, action in ipairs(actions) do
      table.insert(footer, { " " .. action.key_label .. " ", "SnacksFooterKey" })
      table.insert(footer, { " " .. action.label .. " ", "SnacksFooterDesc" })
      table.insert(footer, { " ", "SnacksFooter" })
    end
    if mode == "i" then
      table.insert(footer, { " Ctrl-C ", "SnacksFooterKey" })
    else
      table.insert(footer, { " q ", "SnacksFooterKey" })
    end
    table.insert(footer, { " Cancel ", "SnacksFooterDesc" })
    table.insert(footer, { " ", "SnacksFooter" })

    win.opts.footer = footer

    if win:valid() then
      vim.api.nvim_win_set_config(win.win, {
        footer = win.opts.footer,
        footer_pos = win.opts.footer_pos or "center",
      })
    end
  end

  ---Restore focus to the originating window once the review composer closes.
  local function restore_parent()
    vim.schedule(function()
      pcall(vim.cmd.stopinsert)
      if vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
      end
    end)
  end

  ---Close the composer exactly once and report the final value.
  ---@param value string|nil
  ---@param action string|nil
  local function finish(value, action)
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
      on_confirm(value, action)
    end)
  end

  local keys = {
    q = false,
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
  }

  for index, action in ipairs(actions) do
    local current_action = action
    keys["action_" .. tostring(index)] = {
      current_action.key,
      function(self)
        finish(vim.trim(self:text()), current_action.name)
      end,
      desc = current_action.label,
      mode = current_action.mode or { "n", "i" },
    }
  end

  win = Snacks.win({
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
    keys = keys,
    on_win = function()
      local current = win
      if not current or not current.buf then
        return
      end

      set_footer("i")
      vim.api.nvim_create_autocmd("InsertEnter", {
        group = augroup,
        buffer = current.buf,
        callback = function()
          set_footer("i")
        end,
      })
      vim.api.nvim_create_autocmd("InsertLeave", {
        group = augroup,
        buffer = current.buf,
        callback = function()
          set_footer("n")
        end,
      })
      vim.schedule(function()
        if opts.default and opts.default ~= "" then
          -- Prefilled edits should resume after the final character, not before it.
          vim.cmd("startinsert!")
        else
          vim.cmd.startinsert()
        end
      end)
    end,
    on_close = function()
      if not done then
        done = true
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        restore_parent()
        vim.schedule(function()
          on_confirm(nil)
        end)
      end
    end,
  })

  win:show()
  if opts.default and opts.default ~= "" then
    -- `snacks.win:text()` is multiline, so seed the buffer line-by-line.
    local lines = vim.split(opts.default, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, lines)
    local last = lines[#lines] or ""
    vim.api.nvim_win_set_cursor(win.win, { #lines, #last })
  end
end

return M
