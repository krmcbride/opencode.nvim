local t = require("tests.helpers")
local protocol = require("opencode.protocol")
local parser = require("opencode.sse")

t.test("SSE handles every byte boundary, CRLF, comments and multiline data", function()
  local frames, activity = {}, 0
  local p = parser.new(function(data)
    table.insert(frames, data)
  end, function()
    activity = activity + 1
  end)
  local wire =
    ': heartbeat\r\n\r\nid: evt_one\r\nevent: message\r\ndata: {"type":\r\ndata: "server.connected","data":{}}\r\n\r\n'
  for i = 1, #wire do
    p.feed(wire:sub(i, i))
  end
  t.eq({ '{"type":\n"server.connected","data":{}}' }, frames)
  t.eq(2, activity)
  p.feed('data: {"incomplete":true}')
  t.eq(1, #frames)
end)

t.test("SSE separates multiple frames in a chunk and ignores non-data fields", function()
  local frames = {}
  local p = parser.new(function(value)
    frames[#frames + 1] = value
  end, function() end)
  p.feed("retry: 1000\n\ndata: first\n\ndata: second\n\n")
  t.eq({ "first", "second" }, frames)
end)

t.test("native health and event ownership reject legacy and unrelated workspaces", function()
  assert(protocol.health({ healthy = true, version = "2.0.1" }))
  assert(not protocol.health({ healthy = true, version = "1.18.30" }))
  assert(not protocol.health({ directory = "/fixture" }))
  local scope = { cwd = "/fixture", workspace_id = "wrk_one", session_id = "ses_active" }
  local event = {
    type = "session.execution.succeeded",
    data = { sessionID = "ses_other" },
    location = { directory = "/fixture", workspaceID = "wrk_two" },
  }
  t.eq(nil, protocol.event(event, scope))
  event.location.workspaceID = "wrk_one"
  t.eq(event, protocol.event(event, scope))
  event.location = nil
  t.eq(nil, protocol.event(event, scope))
  event.data.sessionID = "ses_active"
  t.eq(event, protocol.event(event, scope))
  t.eq(nil, protocol.event({ type = "message.updated", properties = {} }, scope))
  t.eq(nil, protocol.session_id({ type = "form.created", data = { form = {} } }))
  t.eq("ses_active", protocol.session_id({ type = "form.created", data = { form = { sessionID = "ses_active" } } }))
end)

t.test("review attachments preserve URI escaping and one-based line ranges", function()
  local review = require("opencode.review")
  local parts =
    review.review_parts({ path = "/fixture/a #b.txt", start_line = 2, end_line = 4 }, "Please explain this.")
  local prompt = protocol.prompt(parts, "queue")
  t.eq("Please explain this.", prompt.text)
  t.eq("file:///fixture/a%20%23b.txt?start=2&end=4", prompt.files[1].uri)
  t.eq("queue", prompt.delivery)
  t.eq(nil, prompt.agent)
  t.eq(nil, prompt.model)
  assert(
    not protocol.admitted(
      { data = { id = "msg_one", sessionID = "ses_other", type = "user", delivery = "queue" } },
      "ses_active"
    )
  )
end)
