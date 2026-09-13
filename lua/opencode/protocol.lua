---Native OpenCode v2 wire contracts. Keep server data in its native shape.
local M = {}

function M.health(value)
  return type(value) == "table"
    and value.healthy == true
    and type(value.version) == "string"
    and value.version:match("^2%.") ~= nil
end

---Convert editor review parts to a native prompt. The session owns agent/model.
function M.prompt(parts, delivery)
  local texts, files = {}, {}
  for _, part in ipairs(parts) do
    if part.type == "text" and type(part.text) == "string" then
      table.insert(texts, part.text)
    elseif part.type == "file" and type(part.url) == "string" then
      table.insert(files, { uri = part.url, name = part.filename })
    else
      error("Unsupported OpenCode review part", 0)
    end
  end
  assert(delivery == "queue" or delivery == "steer", "review delivery must be queue or steer")
  return { text = table.concat(texts, "\n\n"), files = files, delivery = delivery }
end

function M.admitted(value, session_id)
  local item = type(value) == "table" and value.data
  return type(item) == "table"
    and type(item.id) == "string"
    and item.id:match("^msg_") ~= nil
    and item.sessionID == session_id
    and item.type == "user"
    and (item.delivery == "queue" or item.delivery == "steer")
end

function M.session_id(event)
  local data = type(event) == "table" and event.data
  if type(data) ~= "table" then
    return nil
  end
  if event.type == "form.created" then
    return type(data.form) == "table" and data.form.sessionID or nil
  end
  return type(data.sessionID) == "string" and data.sessionID or nil
end

local function normalized(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local absolute = vim.fn.fnamemodify(path, ":p")
  return (vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)):gsub("/+$", "")
end

local function workspace(value)
  return type(value) == "string" and value or nil
end

---The backend stream is global. Only server control events, the active session,
---or events with the same explicit location belong to this editor's scope.
function M.event(value, scope)
  if type(value) ~= "table" or type(value.type) ~= "string" or type(value.data) ~= "table" then
    return nil
  end
  if value.type == "server.connected" then
    return value
  end
  if scope.session_id and M.session_id(value) == scope.session_id then
    return value
  end
  local location = value.location
  if type(location) ~= "table" then
    return nil
  end
  if workspace(location.workspaceID) ~= workspace(scope.workspace_id) then
    return nil
  end
  if normalized(location.directory) ~= normalized(scope.cwd) or not normalized(scope.cwd) then
    return nil
  end
  return value
end

return M
