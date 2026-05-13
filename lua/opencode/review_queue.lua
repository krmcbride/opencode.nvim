---Queued review-comment workflow for opencode.nvim.
---
---The queue is process-local state. Quickfix is only a projection used for
---navigation and bqf previews; queue items are never read back from quickfix.
local M = {}
local input = require("opencode.input")
local review = require("opencode.review")

---@class opencode.review_queue.Selection
---@field path string
---@field start_line integer
---@field end_line integer

---@class opencode.review_queue.Item
---@field id integer
---@field order integer
---@field selection opencode.review_queue.Selection
---@field extmarks? opencode.review_queue.Extmarks
---@field message string
---@field display_name string

---@class opencode.review_queue.Extmarks
---@field buf integer
---@field start_id integer
---@field end_id integer

local qf_title = "opencode review queue"
local extmark_ns = vim.api.nvim_create_namespace("opencode_review_queue")

---@type opencode.review_queue.Item[]
local queue = {}
local next_id = 1
local sending = false

-- Range tracking -------------------------------------------------------------
-- Queue items preserve their original file/range, plus optional extmarks while
-- the source buffer is loaded. Consumers resolve through `resolved_selection()`
-- so edits above a queued range can shift quickfix and send locations without
-- making extmarks mandatory for unloaded buffers.

---@param selection opencode.ReviewSelection|opencode.review_queue.Selection
---@return opencode.review_queue.Selection
local function normalize_selection(selection)
  return {
    path = vim.fn.fnamemodify(selection.path, ":p"),
    start_line = selection.start_line,
    end_line = selection.end_line,
  }
end

---@param value integer
---@param min integer
---@param max integer
---@return integer
local function clamp(value, min, max)
  return math.max(min, math.min(value, max))
end

---@param path string
---@return string
local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

---@param selection opencode.ReviewSelection|opencode.review_queue.Selection
---@return integer|nil
local function loaded_selection_buffer(selection)
  local target = normalize_path(selection.path)
  if selection.buf and vim.api.nvim_buf_is_loaded(selection.buf) then
    local name = vim.api.nvim_buf_get_name(selection.buf)
    if name ~= "" and normalize_path(name) == target then
      return selection.buf
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and normalize_path(name) == target then
        return buf
      end
    end
  end

  return nil
end

---@param selection opencode.ReviewSelection|opencode.review_queue.Selection
---@return opencode.review_queue.Extmarks|nil
local function create_extmarks(selection)
  local buf = loaded_selection_buffer(selection)
  if not buf then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_row = clamp(selection.start_line, 1, line_count) - 1
  local end_row = clamp(selection.end_line, 1, line_count) - 1

  return {
    buf = buf,
    start_id = vim.api.nvim_buf_set_extmark(buf, extmark_ns, start_row, 0, { right_gravity = false }),
    end_id = vim.api.nvim_buf_set_extmark(buf, extmark_ns, end_row, 0, { right_gravity = true }),
  }
end

---@param item opencode.review_queue.Item
local function delete_extmarks(item)
  local extmarks = item.extmarks
  if not (extmarks and vim.api.nvim_buf_is_valid(extmarks.buf)) then
    return
  end

  pcall(vim.api.nvim_buf_del_extmark, extmarks.buf, extmark_ns, extmarks.start_id)
  pcall(vim.api.nvim_buf_del_extmark, extmarks.buf, extmark_ns, extmarks.end_id)
end

---@param item opencode.review_queue.Item
---@return opencode.review_queue.Selection
local function resolved_selection(item)
  local extmarks = item.extmarks
  if extmarks and vim.api.nvim_buf_is_loaded(extmarks.buf) then
    local ok_start, start_pos =
      pcall(vim.api.nvim_buf_get_extmark_by_id, extmarks.buf, extmark_ns, extmarks.start_id, {})
    local ok_end, end_pos = pcall(vim.api.nvim_buf_get_extmark_by_id, extmarks.buf, extmark_ns, extmarks.end_id, {})
    if ok_start and ok_end and start_pos[1] and end_pos[1] then
      local start_line = start_pos[1] + 1
      local end_line = end_pos[1] + 1
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end

      return {
        path = item.selection.path,
        start_line = start_line,
        end_line = end_line,
      }
    end
  end

  return {
    path = item.selection.path,
    start_line = item.selection.start_line,
    end_line = item.selection.end_line,
  }
end

---@param item opencode.review_queue.Item
---@return opencode.review_queue.Item
local function copy_item(item)
  local selection = resolved_selection(item)
  return {
    id = item.id,
    order = item.order,
    selection = {
      path = selection.path,
      start_line = selection.start_line,
      end_line = selection.end_line,
    },
    message = item.message,
    display_name = review.display_name(selection.path, selection.start_line, selection.end_line),
  }
end

-- Display and payload projection ---------------------------------------------
-- Quickfix rows and backend prompt parts are rebuilt from queue state. The queue
-- never reads quickfix back as source data.

---@param message string
---@return string
local function summary(message)
  local text = vim.trim(message):gsub("%s+", " ")
  if #text <= 96 then
    return text
  end

  return text:sub(1, 93) .. "..."
end

---@param selection opencode.review_queue.Selection
---@return string
local function text_display_name(selection)
  local rel = vim.fn.fnamemodify(selection.path, ":.")
  if selection.start_line == selection.end_line then
    return rel .. ":" .. tostring(selection.start_line)
  end

  return rel
    .. ":"
    .. tostring(selection.start_line)
    .. " (lines "
    .. tostring(selection.start_line)
    .. "-"
    .. tostring(selection.end_line)
    .. ")"
end

---@param selection opencode.review_queue.Selection
---@return boolean focused
local function focus_selection_window(selection)
  local target = vim.fn.fnamemodify(selection.path, ":p")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" and vim.fn.fnamemodify(name, ":p") == target then
      vim.api.nvim_set_current_win(win)
      local line_count = vim.api.nvim_buf_line_count(buf)
      local line = math.max(1, math.min(selection.end_line, line_count))
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      return true
    end
  end

  return false
end

---@param item opencode.review_queue.Item
---@return table
local function quickfix_item(item)
  local selection = resolved_selection(item)
  return {
    filename = selection.path,
    lnum = selection.start_line,
    end_lnum = selection.end_line,
    col = 1,
    text = summary(item.message),
    user_data = {
      opencode_review_queue_id = item.id,
    },
  }
end

---@param items opencode.review_queue.Item[]
---@return table[]
local function build_parts(items)
  local text = { "Review the following comments:" }

  for index, item in ipairs(items) do
    table.insert(
      text,
      ("Comment %d/%d for %s\n%s"):format(index, #items, text_display_name(item.selection), item.message)
    )
  end

  ---@type table[]
  local parts = {
    {
      type = "text",
      text = table.concat(text, "\n\n"),
    },
  }

  for _, item in ipairs(items) do
    table.insert(parts, {
      type = "file",
      mime = "text/plain",
      filename = item.display_name,
      url = review.file_url(item.selection.path, item.selection.start_line, item.selection.end_line),
    })
  end

  return parts
end

-- Queue state API -------------------------------------------------------------

---@param selection opencode.ReviewSelection|opencode.review_queue.Selection
---@param message string
---@return opencode.review_queue.Item|nil item
---@return string|nil err
function M.add(selection, message)
  local trimmed = vim.trim(message or "")
  if trimmed == "" then
    return nil, "Review message is required"
  end

  local normalized = normalize_selection(selection)
  local item = {
    id = next_id,
    order = next_id,
    selection = normalized,
    extmarks = create_extmarks(selection),
    message = trimmed,
    display_name = review.display_name(normalized.path, normalized.start_line, normalized.end_line),
  }
  next_id = next_id + 1

  table.insert(queue, item)
  return copy_item(item), nil
end

---@param id integer
---@param message string
---@return opencode.review_queue.Item|nil item
---@return string|nil err
function M.update(id, message)
  local trimmed = vim.trim(message or "")
  if trimmed == "" then
    return nil, "Review message is required"
  end

  for _, item in ipairs(queue) do
    if item.id == id then
      item.message = trimmed
      return copy_item(item), nil
    end
  end

  return nil, "Queued review comment not found"
end

---@return opencode.review_queue.Item[]
function M.items()
  ---@type opencode.review_queue.Item[]
  local result = {}
  for _, item in ipairs(queue) do
    table.insert(result, copy_item(item))
  end
  return result
end

---@return integer
function M.count()
  return #queue
end

function M.clear()
  for _, item in ipairs(queue) do
    delete_extmarks(item)
  end
  queue = {}
end

---@param id integer
---@return opencode.review_queue.Item|nil
function M.get(id)
  for _, item in ipairs(queue) do
    if item.id == id then
      return copy_item(item)
    end
  end
  return nil
end

---@param id integer
---@return boolean removed
function M.remove(id)
  for index, item in ipairs(queue) do
    if item.id == id then
      delete_extmarks(item)
      table.remove(queue, index)
      return true
    end
  end
  return false
end

-- Quickfix interaction --------------------------------------------------------
-- Quickfix rows carry stable queue ids in `user_data` when available. The
-- row-order fallback only applies when the projected row still matches the
-- current queue item, so edited quickfix lists do not mutate the wrong comment.

function M.refresh_quickfix()
  local qf_items = {}
  for _, item in ipairs(queue) do
    table.insert(qf_items, quickfix_item(item))
  end

  vim.fn.setqflist({}, "r", {
    title = qf_title,
    items = qf_items,
  })
end

function M.open_quickfix()
  M.refresh_quickfix()
  if #queue == 0 then
    vim.notify("Review queue is empty", vim.log.levels.WARN, { title = "opencode" })
    return
  end

  vim.cmd.copen()
  M.install_quickfix_mappings()
end

---@param selection opencode.ReviewSelection|opencode.review_queue.Selection
---@param message string
---@return boolean queued
function M.queue_selection(selection, message)
  local item, err = M.add(selection, message)
  if err or not item then
    vim.notify(err or "Review message is required", vim.log.levels.WARN, { title = "opencode" })
    return false
  end

  M.refresh_quickfix()
  vim.notify(("Queued review comment (%d total)"):format(M.count()), vim.log.levels.INFO, { title = "opencode" })
  return true
end

---@param item opencode.review_queue.Item
function M.prompt_for_item_edit(item)
  focus_selection_window(item.selection)

  input.review({
    prompt = "Review message: ",
    title = "Edit " .. item.display_name,
    default = item.message,
    action_label = "Save",
  }, function(value)
    if value == nil then
      return
    end

    local updated, err = M.update(item.id, value)
    if err or not updated then
      vim.notify(err or "Review message is required", vim.log.levels.WARN, { title = "opencode" })
      return
    end

    M.refresh_quickfix()
    M.install_quickfix_mappings()
    vim.notify("Updated queued review comment", vim.log.levels.INFO, { title = "opencode" })
  end)
end

---@return integer|nil
local function current_quickfix_item_id()
  local qf = vim.fn.getqflist({ title = 0, items = 0, idx = 0 })
  if qf.title ~= qf_title then
    return nil
  end

  local index = qf.idx
  if vim.bo.filetype == "qf" then
    index = vim.api.nvim_win_get_cursor(0)[1]
  end

  local qf_item = qf.items and qf.items[index] or nil
  local user_data = qf_item and qf_item.user_data or nil
  if type(user_data) == "table" and type(user_data.opencode_review_queue_id) == "number" then
    return user_data.opencode_review_queue_id
  end

  local queue_item = queue[index]
  local selection = queue_item and resolved_selection(queue_item) or nil
  if
    qf_item
    and queue_item
    and selection
    and qf_item.filename == selection.path
    and qf_item.lnum == selection.start_line
    and qf_item.text == summary(queue_item.message)
  then
    return queue_item.id
  end

  return nil
end

function M.edit_current_quickfix_item()
  local id = current_quickfix_item_id()
  if not id then
    vim.notify("No queued review comment under cursor", vim.log.levels.WARN, { title = "opencode" })
    return
  end

  local item = M.get(id)
  if not item then
    vim.notify("Queued review comment not found", vim.log.levels.WARN, { title = "opencode" })
    M.refresh_quickfix()
    return
  end

  M.prompt_for_item_edit(item)
end

function M.install_quickfix_mappings()
  local qf = vim.fn.getqflist({ title = 0, winid = 0 })
  if qf.title ~= qf_title or not qf.winid or qf.winid == 0 then
    return
  end

  local buf = vim.api.nvim_win_get_buf(qf.winid)
  vim.keymap.set("n", "e", function()
    M.edit_current_quickfix_item()
  end, { buffer = buf, desc = "Edit queued OpenCode review comment" })
end

-- Composer entrypoints --------------------------------------------------------

---@param selection opencode.ReviewSelection
function M.prompt_for_selection(selection)
  input.review({
    prompt = "Review message: ",
    title = review.review_title(selection),
    action_label = "Queue",
  }, function(value)
    if value == nil then
      return
    end

    M.queue_selection(selection, value)
  end)
end

function M.queue_review_selection()
  local selection, selection_err = review.current_selection_or_line()
  if selection_err or not selection then
    vim.notify(selection_err or "No file selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  M.prompt_for_selection(selection)
end

function M.queue_review_visual_selection()
  local selection, selection_err = review.visual_selection()
  if selection_err or not selection then
    vim.notify(selection_err or "No visual selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  M.prompt_for_selection(selection)
end

-- Batch send ------------------------------------------------------------------
-- Sending snapshots resolved queue items, blocks concurrent sends, and removes
-- only the sent ids after the backend confirms success. Comments added while a
-- send is in flight remain queued.

function M.send()
  if sending then
    vim.notify("Review queue send already in progress", vim.log.levels.WARN, { title = "opencode" })
    return false
  end

  local items = M.items()
  if #items == 0 then
    vim.notify("Review queue is empty", vim.log.levels.WARN, { title = "opencode" })
    return false
  end

  local sent_ids = {}
  for _, item in ipairs(items) do
    table.insert(sent_ids, item.id)
  end

  sending = true
  local started = review.send_parts(build_parts(items), {
    success_message = ("Sent %d queued review comment%s to active OpenCode session"):format(
      #items,
      #items == 1 and "" or "s"
    ),
    on_success = function()
      sending = false
      for _, id in ipairs(sent_ids) do
        M.remove(id)
      end
      M.refresh_quickfix()
    end,
    on_error = function()
      sending = false
    end,
  })
  if not started then
    sending = false
  end

  return started
end

return M
