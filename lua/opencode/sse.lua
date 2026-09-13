---Incremental SSE framing, independent of curl/Neovim chunk boundaries.
local M = {}

---@param on_data fun(data: string)
---@param on_activity fun()
function M.new(on_data, on_activity)
  local pending, lines = "", {}
  local function line(value)
    if value == "" then
      if #lines > 0 then
        on_activity()
        local data = table.concat(lines, "\n")
        lines = {}
        on_data(data)
      end
    elseif value:sub(1, 1) == ":" then
      on_activity()
    else
      local field, content = value:match("^([^:]+): ?(.*)$")
      if value == "data" then
        field, content = "data", ""
      end
      if field == "data" then
        table.insert(lines, content)
      end
      -- id/event/retry fields do not contain JSON. This feed has no replay.
    end
  end
  return {
    feed = function(chunk)
      pending = pending .. chunk
      local start = 1
      while true do
        local stop = pending:find("[\r\n]", start)
        if not stop then
          break
        end
        local cr = pending:sub(stop, stop) == "\r"
        if cr and stop == #pending then
          break
        end -- CRLF may cross chunks
        line(pending:sub(start, stop - 1))
        start = stop + ((cr and pending:sub(stop + 1, stop + 1) == "\n") and 2 or 1)
      end
      pending = pending:sub(start)
    end,
    -- An incomplete frame at EOF is intentionally discarded, never delivered.
  }
end

return M
