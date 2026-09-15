---Bounded curl requests. Credentials and prompt bodies travel over stdin, not argv.
local M = {}
local config = require("opencode.config")

local function quoted(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

function M.command(url, method, body)
  local command = { "curl", "-q", "-sS", "--connect-timeout", "2", "--config", "-", "--request", method, "--url", url }
  local input = { 'header = "Content-Type: application/json"' }
  local auth = config.get_auth()
  if auth then
    table.insert(input, "user = " .. quoted(auth.username .. ":" .. auth.password))
  end
  if body then
    table.insert(input, "data-binary = " .. quoted(vim.json.encode(body)))
  end
  return command, table.concat(input, "\n") .. "\n"
end

---@alias opencode.JsonRequestCallback fun(err: string|nil, response: table|nil, status: integer|nil)
---@param callback opencode.JsonRequestCallback
function M.request(url, method, body, callback, timeout)
  local command, input = M.command(url, method, body)
  vim.list_extend(
    command,
    { "--max-time", tostring(timeout or 30), "-H", "Accept: application/json", "-w", "\n%{http_code}" }
  )
  local function complete(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("OpenCode request failed (curl exit " .. tostring(result.code) .. ")", nil, nil)
        return
      end
      local raw, code = (result.stdout or ""):match("^(.*)\n(%d%d%d)%s*$")
      local status = tonumber(code)
      if not status or status < 200 or status >= 300 then
        callback("OpenCode HTTP " .. (code or "response missing status"), nil, status)
        return
      end
      local ok, value = pcall(vim.json.decode, raw or "")
      if not ok or type(value) ~= "table" then
        callback("Invalid OpenCode JSON response", nil, status)
        return
      end
      callback(nil, value, status)
    end)
  end
  local ok, process = pcall(vim.system, command, { text = true, stdin = input }, complete)
  if ok then
    return process
  end
  vim.schedule(function()
    callback("Could not start curl for OpenCode", nil, nil)
  end)
end

return M
