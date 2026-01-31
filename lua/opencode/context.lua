---Context for prompts - captures editor state and provides placeholder expansion.
---
---Captures the current window, buffer, cursor position, and visual selection
---when created. Expands placeholders like @this, @buffer, @diagnostics in
---prompt strings to opencode's file reference format (e.g., `@file.lua L21-L30`).
---@class opencode.Context
---@field win integer
---@field buf integer
---@field cursor integer[] { row, col } (1,0-based)
---@field range? opencode.context.Range
local Context = {}
Context.__index = Context

local ns_id = vim.api.nvim_create_namespace("OpencodeContext")

---@class opencode.context.Range
---@field from integer[] { line, col } (1,0-based)
---@field to integer[] { line, col } (1,0-based)
---@field kind "char"|"line"|"block"

local function is_buf_valid(buf)
  return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function last_used_valid_win()
  local last_used_win = 0
  local latest_last_used = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_buf_valid(buf) then
      local last_used = vim.fn.getbufinfo(buf)[1].lastused or 0
      if last_used > latest_last_used then
        latest_last_used = last_used
        last_used_win = win
      end
    end
  end
  return last_used_win
end

---@param buf integer
---@return opencode.context.Range|nil
local function get_selection(buf)
  local mode = vim.fn.mode()
  local kind = (mode == "V" and "line") or (mode == "v" and "char") or (mode == "\22" and "block")
  if not kind then
    return nil
  end

  -- Exit visual mode for consistent marks
  if vim.fn.mode():match("[vV\22]") then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
  end

  local from = vim.api.nvim_buf_get_mark(buf, "<")
  local to = vim.api.nvim_buf_get_mark(buf, ">")
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end

  return {
    from = { from[1], from[2] },
    to = { to[1], to[2] },
    kind = kind,
  }
end

---@param buf integer
---@param range opencode.context.Range
local function highlight_range(buf, range)
  local end_row = range.to[1] - (range.kind == "line" and 0 or 1)
  local end_col = nil
  if range.kind ~= "line" then
    local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
    end_col = math.min(range.to[2] + 1, #line)
  end
  vim.api.nvim_buf_set_extmark(buf, ns_id, range.from[1] - 1, range.from[2], {
    end_row = end_row,
    end_col = end_col,
    hl_group = "Visual",
  })
end

---Format a location for opencode (GitHub-style).
---e.g. `@file.lua#L21` or `@file.lua#L21-30`
---@param args { buf?: integer, path?: string, start_line?: integer, end_line?: integer }
---@return string
local function format_location(args)
  local result = ""
  if (args.buf and is_buf_valid(args.buf)) or args.path then
    local rel_path = vim.fn.fnamemodify(args.path or vim.api.nvim_buf_get_name(args.buf), ":.")
    result = "@" .. rel_path
  end
  if args.start_line and args.end_line and args.start_line > args.end_line then
    args.start_line, args.end_line = args.end_line, args.start_line
  end
  if args.start_line then
    if result ~= "" then
      result = result .. "#"
    end
    result = result .. string.format("L%d", args.start_line)
    if args.end_line and args.end_line ~= args.start_line then
      result = result .. string.format("-%d", args.end_line)
    end
  end
  return result
end

---Create a new context capturing current editor state.
---@param range? opencode.context.Range Optional range override
---@return opencode.Context
function Context.new(range)
  local self = setmetatable({}, Context)
  self.win = last_used_valid_win()
  self.buf = vim.api.nvim_win_get_buf(self.win)
  self.cursor = vim.api.nvim_win_get_cursor(self.win)
  self.range = range or get_selection(self.buf)
  if self.range then
    highlight_range(self.buf, self.range)
  end
  return self
end

---Clear context highlights.
function Context:clear()
  vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
end

---Get @this: range if present, else current line.
---@return string
function Context:this()
  if self.range then
    return format_location({
      buf = self.buf,
      start_line = self.range.from[1],
      end_line = self.range.to[1],
    })
  else
    -- No selection: reference current line
    return format_location({
      buf = self.buf,
      start_line = self.cursor[1],
    })
  end
end

---Get @buffer: current buffer path.
---@return string
function Context:buffer()
  return format_location({ buf = self.buf })
end

---Get @diagnostics: LSP diagnostics for current buffer.
---@return string|nil
function Context:diagnostics()
  local diagnostics = vim.diagnostic.get(self.buf)
  if #diagnostics == 0 then
    return nil
  end

  local file_ref = format_location({ buf = self.buf })
  local diagnostic_strings = {}

  for _, diagnostic in ipairs(diagnostics) do
    local location = format_location({
      start_line = diagnostic.lnum + 1,
      end_line = diagnostic.end_lnum + 1,
    })
    table.insert(
      diagnostic_strings,
      string.format(
        "- %s (%s): %s",
        location,
        diagnostic.source or "unknown source",
        diagnostic.message:gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
      )
    )
  end

  return #diagnostics .. " diagnostics in " .. file_ref .. "\n" .. table.concat(diagnostic_strings, "\n")
end

---Expand context placeholders in a prompt.
---@param prompt string
---@return string
function Context:expand(prompt)
  local placeholders = {
    {
      pattern = "@this",
      fn = function()
        return self:this()
      end,
    },
    {
      pattern = "@buffer",
      fn = function()
        return self:buffer()
      end,
    },
    {
      pattern = "@diagnostics",
      fn = function()
        return self:diagnostics()
      end,
    },
  }

  -- Sort by length (longest first) to handle overlapping placeholders
  table.sort(placeholders, function(a, b)
    return #a.pattern > #b.pattern
  end)

  local result = prompt
  for _, placeholder in ipairs(placeholders) do
    local value = placeholder.fn()
    if value then
      result = result:gsub(placeholder.pattern, value)
    end
  end

  return result
end

return Context
