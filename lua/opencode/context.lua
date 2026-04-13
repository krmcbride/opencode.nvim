---Prompt-context snapshot and placeholder expansion for opencode.nvim.
---
---A `Context` captures editor state at the moment a prompt is assembled, before
---focus may move into the embedded terminal. It owns placeholder expansion for
---plugin-defined prompt shorthands like `@this`, `@buffer`, and `@diagnostics`.
---
---Those placeholders are invented by `opencode.nvim`, not by OpenCode itself.
---This module rewrites them into plain prompt text and native OpenCode-style
---file references before anything is sent to the TUI/backend.
---
---That means they only have effect when prompt text flows through plugin APIs
---like `require("opencode").prompt(...)`. Typing `@this` directly into the
---OpenCode TUI will not trigger any special expansion.
---
---This is distinct from `opencode.review`, which owns direct review sends and
---their explicit file/line selection handling. `opencode.context` is about
---prompt text expansion and OpenCode TUI file-reference formatting.
---@class opencode.Context
---@field win integer
---@field buf integer
---@field cursor opencode.context.Position { row, col } using Neovim's (1,0-based) cursor tuple
---@field range? opencode.context.Range
local Context = {}
Context.__index = Context

---@type integer
local ns_id = vim.api.nvim_create_namespace("OpencodeContext")

---@class opencode.context.Position
---@field [1] integer
---@field [2] integer

---@class opencode.context.Range
---@field from opencode.context.Position { line, col } (1,0-based)
---@field to opencode.context.Position { line, col } (1,0-based)
---@field kind "char"|"line"|"block"

---@class opencode.context.LocationArgs
---@field buf? integer
---@field path? string
---@field start_line? integer
---@field start_col? integer
---@field end_line? integer
---@field end_col? integer

---@class opencode.context.Placeholder
---@field pattern string
---@field fn fun(): string|nil

---Whether a buffer is a normal named file buffer suitable for prompt context.
---@param buf integer
---@return boolean
local function is_buf_valid(buf)
  return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

---Pick the most recently used file window.
---
---Prompt commands may be invoked while focus is in the embedded terminal or a
---float. For context capture we prefer the most recently used normal file
---window rather than blindly using the current window.
---@return integer
local function last_used_valid_win()
  local last_used_win = 0
  local latest_last_used = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_buf_valid(buf) then
      local info = vim.fn.getbufinfo(buf)[1]
      local last_used = info and info.lastused or 0
      if last_used > latest_last_used then
        latest_last_used = last_used
        last_used_win = win
      end
    end
  end
  return last_used_win
end

---Capture the current visual selection as a range snapshot.
---
---When invoked from Visual mode, exit Visual mode first so the `<` / `>` marks
---settle to the final selection bounds before we read them.
---@param buf integer
---@return opencode.context.Range|nil
local function get_selection(buf)
  local mode = vim.fn.mode()
  local kind = (mode == "V" and "line") or (mode == "v" and "char") or (mode == "\22" and "block")
  if not kind then
    return nil
  end

  -- Exit Visual mode so `<` and `>` marks reflect the final selection bounds.
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

---Highlight the captured range so the active prompt context remains visible.
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

---Format an OpenCode TUI file/location reference.
---
---Line fragments use `#N` / `#N-M`, not `#LN`. When column precision is also
---available, emit `columns X-Y in @file#A-B` so the `@file...` reference stays
---last; that matches the TUI's autocomplete behavior when the cursor lands at
---the end of the file reference.
---@param args opencode.context.LocationArgs
---@return string
local function format_location(args)
  if args.start_line and args.end_line and args.start_line > args.end_line then
    args.start_line, args.end_line = args.end_line, args.start_line
    args.start_col, args.end_col = args.end_col, args.start_col
  elseif
    args.start_line
    and args.end_line
    and args.start_line == args.end_line
    and args.start_col
    and args.end_col
    and args.start_col > args.end_col
  then
    args.start_col, args.end_col = args.end_col, args.start_col
  end

  local has_path = (args.buf and is_buf_valid(args.buf)) or args.path
  local rel_path = has_path and vim.fn.fnamemodify(args.path or vim.api.nvim_buf_get_name(args.buf), ":.") or nil

  -- Column precision: plain-text columns first; `@path#line` last for TUI file autocomplete.
  if rel_path and args.start_line and args.start_col ~= nil and args.end_col ~= nil then
    local line_start = args.start_line
    local line_end = args.end_line or args.start_line
    local hash = line_start == line_end and string.format("%d", line_start)
      or string.format("%d-%d", line_start, line_end)
    return string.format("columns %d-%d in @%s#%s", args.start_col, args.end_col, rel_path, hash)
  end

  local result = ""
  if has_path then
    result = "@" .. rel_path
  end
  if args.start_line then
    if result ~= "" then
      result = result .. "#"
    end
    result = result .. string.format("%d", args.start_line)
    local has_end = args.end_line
      and (args.end_line ~= args.start_line or (args.end_col and args.end_col ~= args.start_col))
    if has_end then
      result = result .. string.format("-%d", args.end_line)
    end
  end
  return result
end

---Create a new prompt context by snapshotting current editor state.
---
---The snapshot is intentionally eager so later terminal focus changes do not
---change what `@this` / `@buffer` / `@diagnostics` refer to.
---@param range? opencode.context.Range Optional range override
---@return opencode.Context
function Context.new(range)
  ---@type opencode.Context
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

---Clear any temporary highlight created for this context snapshot.
function Context:clear()
  vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
end

---Expand `@this` to the captured selection or current line.
---@return string
function Context:this()
  if self.range then
    local same_line = self.range.from[1] == self.range.to[1]
    local use_columns = same_line and self.range.kind ~= "line"

    return format_location({
      buf = self.buf,
      start_line = self.range.from[1],
      end_line = self.range.to[1],
      start_col = use_columns and (self.range.from[2] + 1) or nil,
      end_col = use_columns and (self.range.to[2] + 1) or nil,
    })
  else
    -- No selection: reference current line
    return format_location({
      buf = self.buf,
      start_line = self.cursor[1],
    })
  end
end

---Expand `@buffer` to the captured buffer path.
---@return string
function Context:buffer()
  return format_location({ buf = self.buf })
end

---Expand `@diagnostics` to a formatted diagnostic summary for the buffer.
---
---The returned text is prompt prose plus a trailing file reference, not just a
---bare `@file...` token.
---@return string|nil
function Context:diagnostics()
  local diagnostics = vim.diagnostic.get(self.buf)
  if #diagnostics == 0 then
    return nil
  end

  local file_ref = format_location({ buf = self.buf })
  ---@type string[]
  local diagnostic_strings = {}

  for _, diagnostic in ipairs(diagnostics) do
    local end_lnum = diagnostic.end_lnum or diagnostic.lnum
    local location = format_location({
      start_line = diagnostic.lnum + 1,
      end_line = end_lnum + 1,
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

  return "Check the following diagnostics for me:\n\n"
    .. table.concat(diagnostic_strings, "\n")
    .. "\n\nin "
    .. file_ref
end

---Expand supported context placeholders in a prompt string.
---
---Placeholder patterns are applied longest-first so overlapping names remain
---stable if more placeholders are added later.
---@param prompt string
---@return string
function Context:expand(prompt)
  ---@type opencode.context.Placeholder[]
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
