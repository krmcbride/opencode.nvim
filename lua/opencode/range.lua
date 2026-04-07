---Line-range helpers for direct session sends.
local M = {}

---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

---@return { start_line: integer, end_line: integer }|nil
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

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return {
    start_line = start_line,
    end_line = end_line,
  }
end

---@param buf integer
---@return { start_line: integer, end_line: integer }|nil
local function get_mark_line_range(buf)
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")
  local start_line = start_pos[1]
  local end_line = end_pos[1]

  if start_line == 0 or end_line == 0 then
    return nil
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return {
    start_line = start_line,
    end_line = end_line,
  }
end

---@return { buf: integer, path: string, start_line: integer, end_line: integer }|nil, string|nil
function M.current_selection_or_line()
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

---@return { buf: integer, path: string, start_line: integer, end_line: integer }|nil, string|nil
function M.visual_selection()
  local buf = vim.api.nvim_get_current_buf()
  if not is_file_buffer(buf) then
    return nil, "Current buffer is not a file"
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local range = get_active_visual_line_range() or get_mark_line_range(buf)
  if not range then
    return nil, "No visual selection marks available"
  end

  return {
    buf = buf,
    path = path,
    start_line = range.start_line,
    end_line = range.end_line,
  }, nil
end

---@param path string
---@param start_line integer
---@param end_line integer
---@return string
function M.file_url(path, start_line, end_line)
  return vim.uri_from_fname(path) .. "?start=" .. tostring(start_line) .. "&end=" .. tostring(end_line)
end

---@param path string
---@param start_line integer
---@param end_line integer
---@return string
function M.display_name(path, start_line, end_line)
  local rel = vim.fn.fnamemodify(path, ":.")
  if start_line == end_line then
    return rel .. "#" .. tostring(start_line)
  end
  return rel .. "#" .. tostring(start_line) .. "-" .. tostring(end_line)
end

return M
