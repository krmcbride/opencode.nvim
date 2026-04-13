---Direct review workflow for opencode.nvim.
---
---This module owns the higher-level direct-review path:
---1. collect a file/line selection
---2. prompt for a review message
---3. validate that the embedded TUI currently has an active OpenCode session
---4. send a ranged file attachment directly to that backend session
---
---It now also owns the lower-level selection/range helpers and attachment
---formatting for that workflow, so review-specific selection logic is kept in
---one place instead of split across multiple modules.
---
---This is distinct from `require("opencode").prompt(...)`, which injects text
---into the local terminal PTY. Review sends bypass PTY prompt injection and go
---straight to the backend session API for the currently active attached TUI
---session.
local M = {}
local client = require("opencode.client")
local input = require("opencode.input")
local session = require("opencode.session")

---@class opencode.ReviewSelection
---@field buf integer
---@field path string
---@field start_line integer
---@field end_line integer

---@class opencode.ActiveReviewSession: opencode.SessionState
---@field route "session"
---@field session_id string

---@class opencode.RecentUserInfo
---@field role string
---@field agent? string
---@field model? opencode.ModelRef
---@field variant? string

---@class opencode.review.LineRange
---@field start_line integer
---@field end_line integer

-- Selection/range helpers.

---Whether a buffer is a normal named file buffer suitable for direct review sends.
---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

---@param start_line integer
---@param end_line integer
---@return opencode.review.LineRange
local function ordered_line_range(start_line, end_line)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return {
    start_line = start_line,
    end_line = end_line,
  }
end

---Read the active visual selection as a line range from the current editor state.
---@return opencode.review.LineRange|nil
local function get_active_visual_line_range()
  local mode = vim.fn.mode(1)
  if not mode:match("^[vV\22]") then
    return nil
  end

  local start_pos = vim.fn.getpos("v")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local start_line = start_pos[2]
  local end_line = cursor[1]

  if start_line == 0 or end_line == 0 then
    return nil
  end

  return ordered_line_range(start_line, end_line)
end

---Read the persisted `<` / `>` marks as a line range.
---@param buf integer
---@return opencode.review.LineRange|nil
local function get_mark_line_range(buf)
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")
  local start_line = start_pos[1]
  local end_line = end_pos[1]

  if start_line == 0 or end_line == 0 then
    return nil
  end

  return ordered_line_range(start_line, end_line)
end

---Return the current visual selection if active, otherwise the current line.
---@return opencode.ReviewSelection|nil, string|nil
local function current_selection_or_line()
  local buf = vim.api.nvim_get_current_buf()
  if not is_file_buffer(buf) then
    return nil, "Current buffer is not a file"
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local visual = get_active_visual_line_range()
  if visual then
    return {
      buf = buf,
      path = path,
      start_line = visual.start_line,
      end_line = visual.end_line,
    },
      nil
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  return {
    buf = buf,
    path = path,
    start_line = line,
    end_line = line,
  }, nil
end

---Return the current or last visual selection only.
---@return opencode.ReviewSelection|nil, string|nil
local function visual_selection()
  local buf = vim.api.nvim_get_current_buf()
  if not is_file_buffer(buf) then
    return nil, "Current buffer is not a file"
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local current_range = get_active_visual_line_range() or get_mark_line_range(buf)
  if not current_range then
    return nil, "No visual selection marks available"
  end

  return {
    buf = buf,
    path = path,
    start_line = current_range.start_line,
    end_line = current_range.end_line,
  },
    nil
end

---Build the ranged file URL used for direct review attachments.
---@param path string
---@param start_line integer
---@param end_line integer
---@return string
local function file_url(path, start_line, end_line)
  return vim.uri_from_fname(path) .. "?start=" .. tostring(start_line) .. "&end=" .. tostring(end_line)
end

---Build the display name shown for a ranged file attachment.
---@param path string
---@param start_line integer
---@param end_line integer
---@return string
local function display_name(path, start_line, end_line)
  local rel = vim.fn.fnamemodify(path, ":.")
  if start_line == end_line then
    return rel .. "#" .. tostring(start_line)
  end
  return rel .. "#" .. tostring(start_line) .. "-" .. tostring(end_line)
end

---Build the review prompt title shown in the composer.
---@param selection opencode.ReviewSelection
---@return string
local function review_title(selection)
  local filename = vim.fn.fnamemodify(selection.path, ":t")
  if selection.start_line == selection.end_line then
    return "Review " .. filename .. " line " .. tostring(selection.start_line)
  end

  return "Review " .. filename .. " lines " .. tostring(selection.start_line) .. "-" .. tostring(selection.end_line)
end

---Return the currently active OpenCode session from the embedded TUI.
---
---Direct review sends require a concrete session id because they target the
---backend session API directly, not the terminal PTY.
---@return opencode.ActiveReviewSession|nil
local function active_session()
  local current = session.get_state()
  if current.route ~= "session" or not current.session_id then
    vim.notify("No active OpenCode session selected in the embedded TUI", vim.log.levels.ERROR, { title = "opencode" })
    return nil
  end

  return current --[[@as opencode.ActiveReviewSession]]
end

-- Payload construction and send helpers.

---Build the multipart payload for a direct review send.
---@param selection opencode.ReviewSelection
---@param message string
---@return table[]
local function review_parts(selection, message)
  return {
    {
      type = "text",
      text = message,
    },
    {
      type = "file",
      mime = "text/plain",
      filename = display_name(selection.path, selection.start_line, selection.end_line),
      url = file_url(selection.path, selection.start_line, selection.end_line),
    },
  }
end

---Return the most recent user message metadata from a session message list.
---
---When present, the direct review send reuses the last user-facing agent/model/
---variant so the review goes to the same target the user was already using.
---@param response table
---@return opencode.RecentUserInfo|nil
local function last_user_info(response)
  for i = #response, 1, -1 do
    local item = response[i]
    if type(item) == "table" and type(item.info) == "table" and item.info.role == "user" then
      return item.info
    end
  end

  return nil
end

---Send the prepared review payload to the active backend session.
---@param current opencode.ActiveReviewSession
---@param parts table[]
---@param prompt_opts? opencode.PromptAsyncOpts
local function send_review(current, parts, prompt_opts)
  client.prompt_async(current.session_id, parts, prompt_opts, function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
      return
    end

    vim.notify("Sent review to active OpenCode session", vim.log.levels.INFO, { title = "opencode" })
    client.ensure_subscribed(true)
  end)
end

---Fetch recent conversation metadata, then send the review.
---
---If recent messages are unavailable, still send the review scoped to the
---active session and directory.
---@param current opencode.ActiveReviewSession
---@param parts table[]
local function send_with_recent_context(current, parts)
  client.session_messages(current.session_id, { directory = current.cwd, limit = 100 }, function(err, response)
    if err or type(response) ~= "table" then
      send_review(current, parts, { directory = current.cwd })
      return
    end

    local last_user = last_user_info(response)

    send_review(current, parts, {
      directory = current.cwd,
      agent = last_user and last_user.agent or nil,
      model = last_user and last_user.model or nil,
      variant = last_user and last_user.variant or nil,
    })
  end)
end

-- Public review entrypoints.

---Prompt for a review message, then send the selected file/range.
---@param selection opencode.ReviewSelection
function M.prompt_for_selection(selection)
  input.review({
    prompt = "Review message: ",
    title = review_title(selection),
  }, function(value)
    if value == nil then
      return
    end

    local message = vim.trim(value)
    if message == "" then
      vim.notify("Review message is required", vim.log.levels.WARN, { title = "opencode" })
      return
    end

    local current = active_session()
    if not current then
      return
    end

    send_with_recent_context(current, review_parts(selection, message))
  end)
end

---Review the current visual selection if active, otherwise the current line.
function M.review_selection()
  local selection, selection_err = current_selection_or_line()
  if selection_err or not selection then
    vim.notify(selection_err or "No file selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  M.prompt_for_selection(selection)
end

---Review only an explicit visual selection.
function M.review_visual_selection()
  local selection, selection_err = visual_selection()
  if selection_err or not selection then
    vim.notify(selection_err or "No visual selection available", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  M.prompt_for_selection(selection)
end

return M
