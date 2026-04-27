---Native OpenCode editor-context WebSocket server.
---
---OpenCode's TUI can connect to an IDE integration over a localhost WebSocket
---whose port is provided by `OPENCODE_EDITOR_SSE_PORT`. Despite the env var
---name, the transport is WebSocket JSON-RPC. This module implements only the
---small server subset the TUI needs: handshake/framing, `initialize`, and live
---`selection_changed` notifications for the active Neovim file context.
local M = {}

local bit = require("bit")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local PROTOCOL_VERSION = "2025-11-25"

---@class opencode.EditorContextState
---@field server uv.uv_tcp_t|nil
---@field port integer|nil
---@field clients table<uv.uv_tcp_t, true>
---@field last_win integer|nil
---@field last_selection table|nil
---@field last_selection_key string
---@field augroup integer|nil

---@type opencode.EditorContextState
local state = {
  server = nil,
  port = nil,
  clients = {},
  last_win = nil,
  last_selection = nil,
  last_selection_key = "",
  augroup = nil,
}

local function u32(value)
  return value % 4294967296
end

local function sha1(message)
  local bytes = { message:byte(1, #message) }
  local bit_len_hi = math.floor((#message * 8) / 4294967296)
  local bit_len_lo = (#message * 8) % 4294967296

  table.insert(bytes, 0x80)
  while (#bytes % 64) ~= 56 do
    table.insert(bytes, 0)
  end

  for shift = 24, 0, -8 do
    table.insert(bytes, bit.band(bit.rshift(bit_len_hi, shift), 0xff))
  end
  for shift = 24, 0, -8 do
    table.insert(bytes, bit.band(bit.rshift(bit_len_lo, shift), 0xff))
  end

  local h0 = 0x67452301
  local h1 = 0xefcdab89
  local h2 = 0x98badcfe
  local h3 = 0x10325476
  local h4 = 0xc3d2e1f0

  for chunk = 1, #bytes, 64 do
    local w = {}
    for i = 0, 15 do
      local index = chunk + i * 4
      w[i] = bit.bor(
        bit.lshift(bytes[index], 24),
        bit.lshift(bytes[index + 1], 16),
        bit.lshift(bytes[index + 2], 8),
        bytes[index + 3]
      )
    end
    for i = 16, 79 do
      w[i] = bit.rol(bit.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a = h0
    local b = h1
    local c = h2
    local d = h3
    local e = h4

    for i = 0, 79 do
      local f
      local k
      if i <= 19 then
        f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
        k = 0x5a827999
      elseif i <= 39 then
        f = bit.bxor(b, c, d)
        k = 0x6ed9eba1
      elseif i <= 59 then
        f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
        k = 0x8f1bbcdc
      else
        f = bit.bxor(b, c, d)
        k = 0xca62c1d6
      end

      local temp = u32(bit.rol(a, 5) + f + e + k + w[i])
      e = d
      d = c
      c = bit.rol(b, 30)
      b = a
      a = temp
    end

    h0 = u32(h0 + a)
    h1 = u32(h1 + b)
    h2 = u32(h2 + c)
    h3 = u32(h3 + d)
    h4 = u32(h4 + e)
  end

  local out = {}
  for _, word in ipairs({ h0, h1, h2, h3, h4 }) do
    for shift = 24, 0, -8 do
      table.insert(out, string.char(bit.band(bit.rshift(word, shift), 0xff)))
    end
  end

  return table.concat(out)
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(input)
  local out = {}
  for index = 1, #input, 3 do
    local a = input:byte(index) or 0
    local b = input:byte(index + 1) or 0
    local c = input:byte(index + 2) or 0
    local n = a * 65536 + b * 256 + c

    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64

    table.insert(out, base64_alphabet:sub(c1 + 1, c1 + 1))
    table.insert(out, base64_alphabet:sub(c2 + 1, c2 + 1))
    table.insert(out, index + 1 <= #input and base64_alphabet:sub(c3 + 1, c3 + 1) or "=")
    table.insert(out, index + 2 <= #input and base64_alphabet:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

local function websocket_accept(key)
  return base64_encode(sha1(key .. WS_GUID))
end

local function encode_frame(payload, opcode)
  opcode = opcode or 1
  local length = #payload
  local header
  if length < 126 then
    header = string.char(0x80 + opcode, length)
  elseif length < 65536 then
    header = string.char(0x80 + opcode, 126, math.floor(length / 256), length % 256)
  else
    local high = math.floor(length / 4294967296)
    local low = length % 4294967296
    header = string.char(
      0x80 + opcode,
      127,
      0,
      0,
      0,
      high % 256,
      bit.band(bit.rshift(low, 24), 0xff),
      bit.band(bit.rshift(low, 16), 0xff),
      bit.band(bit.rshift(low, 8), 0xff),
      bit.band(low, 0xff)
    )
  end
  return header .. payload
end

local function decode_frame(buffer)
  if #buffer < 2 then
    return nil, buffer
  end

  local b1 = buffer:byte(1)
  local b2 = buffer:byte(2)
  local opcode = bit.band(b1, 0x0f)
  local masked = bit.band(b2, 0x80) ~= 0
  local length = bit.band(b2, 0x7f)
  local index = 3

  if length == 126 then
    if #buffer < 4 then
      return nil, buffer
    end
    length = buffer:byte(3) * 256 + buffer:byte(4)
    index = 5
  elseif length == 127 then
    if #buffer < 10 then
      return nil, buffer
    end
    local high = 0
    local low = 0
    for i = 3, 6 do
      high = high * 256 + buffer:byte(i)
    end
    for i = 7, 10 do
      low = low * 256 + buffer:byte(i)
    end
    length = high * 4294967296 + low
    index = 11
  end

  local mask
  if masked then
    if #buffer < index + 3 then
      return nil, buffer
    end
    mask = { buffer:byte(index, index + 3) }
    index = index + 4
  end

  local frame_end = index + length - 1
  if #buffer < frame_end then
    return nil, buffer
  end

  local payload = buffer:sub(index, frame_end)
  if masked then
    local out = {}
    for i = 1, #payload do
      out[i] = string.char(bit.bxor(payload:byte(i), mask[((i - 1) % 4) + 1]))
    end
    payload = table.concat(out)
  end

  return {
    opcode = opcode,
    payload = payload,
  }, buffer:sub(frame_end + 1)
end

local function is_file_buf(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_get_option_value("buftype", { buf = buf }) == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function active_file_win()
  local current = vim.api.nvim_get_current_win()
  if is_file_buf(vim.api.nvim_win_get_buf(current)) then
    return current
  end

  if
    state.last_win
    and vim.api.nvim_win_is_valid(state.last_win)
    and is_file_buf(vim.api.nvim_win_get_buf(state.last_win))
  then
    return state.last_win
  end

  local best_win
  local best_last_used = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_file_buf(buf) then
      local info = vim.fn.getbufinfo(buf)[1]
      local last_used = info and info.lastused or 0
      if last_used > best_last_used then
        best_win = win
        best_last_used = last_used
      end
    end
  end

  return best_win
end

local function normalize_range(start_line, start_col, end_line, end_col)
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    return end_line, end_col, start_line, start_col
  end
  return start_line, start_col, end_line, end_col
end

local function line_length(buf, line)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  return #text
end

local function visual_selection(buf, win)
  if win ~= vim.api.nvim_get_current_win() then
    return nil
  end

  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\022" then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local visual = vim.fn.getpos("v")
  local start_line, start_col, end_line, end_col = normalize_range(visual[2], visual[3], cursor[1], cursor[2] + 1)

  if mode == "V" then
    start_col = 1
    end_col = line_length(buf, end_line)
  end

  local lines = vim.api.nvim_buf_get_text(buf, start_line - 1, start_col - 1, end_line - 1, end_col, {})
  return {
    text = table.concat(lines, "\n"),
    selection = {
      start = { line = start_line, character = start_col },
      ["end"] = { line = end_line, character = end_col + 1 },
    },
  }
end

local function build_selection()
  local win = active_file_win()
  if not win then
    return nil
  end

  local buf = vim.api.nvim_win_get_buf(win)
  if not is_file_buf(buf) then
    return nil
  end

  state.last_win = win
  local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
  local visual = visual_selection(buf, win)
  if visual then
    visual.filePath = file_path
    return visual
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local character = cursor[2] + 1
  return {
    text = "",
    filePath = file_path,
    selection = {
      start = { line = cursor[1], character = character },
      ["end"] = { line = cursor[1], character = character },
    },
  }
end

local function selection_key(selection)
  if not selection then
    return ""
  end
  return table.concat({
    selection.filePath,
    selection.selection.start.line,
    selection.selection.start.character,
    selection.selection["end"].line,
    selection.selection["end"].character,
    selection.text,
  }, "\0")
end

local function send(client, message)
  if client:is_closing() then
    return
  end
  client:write(encode_frame(vim.json.encode(message)))
end

local function broadcast_selection(force)
  local selection = state.last_selection or build_selection()
  local key = selection_key(selection)
  if not force and key == state.last_selection_key then
    return
  end

  state.last_selection = selection
  state.last_selection_key = key
  if not selection then
    return
  end

  for client in pairs(state.clients) do
    send(client, {
      jsonrpc = "2.0",
      method = "selection_changed",
      params = selection,
    })
  end
end

local function broadcast_mention(selection)
  if not selection or not next(state.clients) then
    return false
  end

  local line_start = selection.selection.start.line
  local line_end = selection.selection["end"].line
  if line_start > line_end then
    line_start, line_end = line_end, line_start
  end

  for client in pairs(state.clients) do
    send(client, {
      jsonrpc = "2.0",
      method = "at_mentioned",
      params = {
        filePath = selection.filePath,
        lineStart = line_start,
        lineEnd = line_end,
      },
    })
  end

  return true
end

local pending_update = false

local function capture_and_broadcast()
  if pending_update then
    return
  end
  pending_update = true
  vim.schedule(function()
    pending_update = false
    local selection = build_selection()
    if selection then
      state.last_selection = selection
    end
    broadcast_selection(false)
  end)
end

local function handle_message(client, payload)
  local ok, message = pcall(vim.json.decode, payload)
  if not ok or type(message) ~= "table" then
    return
  end

  if message.method == "initialize" and message.id ~= nil then
    send(client, {
      jsonrpc = "2.0",
      id = message.id,
      result = {
        protocolVersion = PROTOCOL_VERSION,
        serverInfo = {
          name = "opencode.nvim",
          version = "0.0.0",
        },
      },
    })
    vim.schedule(function()
      broadcast_selection(true)
    end)
  end
end

local function close_client(client)
  state.clients[client] = nil
  if not client:is_closing() then
    client:close()
  end
end

local function handle_frame(client, frame)
  if frame.opcode == 1 then
    handle_message(client, frame.payload)
  elseif frame.opcode == 8 then
    client:write(encode_frame("", 8), function()
      close_client(client)
    end)
  elseif frame.opcode == 9 then
    client:write(encode_frame(frame.payload, 10))
  end
end

local function handshake_response(request)
  local key = request:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
  if not key then
    return nil
  end

  key = vim.trim(key)
  return table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. websocket_accept(key),
    "",
    "",
  }, "\r\n")
end

local function accept_client(server)
  local client = assert(vim.uv.new_tcp(), "Failed to accept OpenCode editor context connection")
  server:accept(client)

  local buffer = ""
  local upgraded = false

  client:read_start(function(err, chunk)
    if err or not chunk then
      close_client(client)
      return
    end

    buffer = buffer .. chunk

    if not upgraded then
      local header_end = buffer:find("\r\n\r\n", 1, true) or buffer:find("\n\n", 1, true)
      if not header_end then
        return
      end

      local delimiter = buffer:sub(header_end, header_end + 3) == "\r\n\r\n" and 4 or 2
      local request = buffer:sub(1, header_end + delimiter - 1)
      local response = handshake_response(request)
      if not response then
        close_client(client)
        return
      end

      upgraded = true
      state.clients[client] = true
      client:write(response)
      buffer = buffer:sub(header_end + delimiter)
      vim.schedule(function()
        broadcast_selection(true)
      end)
    end

    while buffer ~= "" do
      local frame
      frame, buffer = decode_frame(buffer)
      if not frame then
        return
      end
      handle_frame(client, frame)
    end
  end)
end

local function ensure_autocmds()
  if state.augroup then
    return
  end

  state.augroup = vim.api.nvim_create_augroup("OpencodeEditorContext", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufWinEnter",
    "CursorMoved",
    "CursorMovedI",
    "ModeChanged",
    "TextChanged",
    "TextChangedI",
    "WinEnter",
  }, {
    group = state.augroup,
    callback = capture_and_broadcast,
    desc = "Publish active editor context to embedded OpenCode TUI",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = M.stop,
    desc = "Stop OpenCode editor-context WebSocket server",
  })
end

function M.ensure()
  if state.server and state.port then
    return { port = state.port }
  end

  local server = assert(vim.uv.new_tcp(), "Failed to create OpenCode editor context server")
  server:bind("127.0.0.1", 0)
  server:listen(16, function(err)
    if err then
      vim.schedule(function()
        vim.notify("OpenCode editor context error: " .. err, vim.log.levels.ERROR, { title = "opencode" })
      end)
      return
    end
    accept_client(server)
  end)

  local socket = server:getsockname()
  local port = socket and socket.port or nil
  assert(port, "Failed to determine OpenCode editor context port")

  state.server = server
  state.port = port
  ensure_autocmds()
  capture_and_broadcast()

  return { port = port }
end

function M.stop()
  for client in pairs(state.clients) do
    close_client(client)
  end
  if state.server and not state.server:is_closing() then
    state.server:close()
  end
  state.server = nil
  state.port = nil
end

function M.mention_current()
  local selection = build_selection()
  if not selection then
    return false
  end

  state.last_selection = selection
  state.last_selection_key = selection_key(selection)
  broadcast_selection(true)
  return broadcast_mention(selection)
end

function M.status()
  return {
    running = state.server ~= nil,
    port = state.port,
    clients = vim.tbl_count(state.clients),
  }
end

return M
