---Coalesced, location-scoped disk checks for v2's incomplete file event feed.
local M = {}
local config = require("opencode.config")
local pending, scheduled = {}, false

local function canonical(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  return (vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)):gsub("/+$", "")
end

local function matches(name, request)
  local path = canonical(name)
  if request.file then
    return path == canonical(request.file)
  end
  if not request.directory then
    return false
  end
  local directory = canonical(request.directory)
  return path == directory or path:sub(1, #directory + 1) == directory .. "/"
end

local function autoread(buf)
  local value = vim.api.nvim_get_option_value("autoread", { buf = buf })
  -- An unset global-local boolean is nil; honor the inherited global value.
  if value == nil then
    return vim.go.autoread
  end
  return value
end

function M.request(request)
  if config.opts.auto_reload == false then
    return
  end
  table.insert(pending, request)
  if scheduled then
    return
  end
  scheduled = true
  vim.defer_fn(function()
    local requests = pending
    pending, scheduled = {}, false
    if config.opts.auto_reload == false then
      return
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buftype == ""
        and not vim.bo[buf].modified
        and autoread(buf)
      then
        local name = vim.api.nvim_buf_get_name(buf)
        for _, item in ipairs(requests) do
          if name ~= "" and matches(name, item) then
            -- In Terminal mode, avoid unrelated autocmds stealing TUI input.
            local prefix = vim.api.nvim_get_mode().mode:sub(1, 1) == "t" and "noautocmd " or ""
            pcall(vim.cmd, prefix .. "checktime " .. buf)
            break
          end
        end
      end
    end
  end, 150)
end

return M
