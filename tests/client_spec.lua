local t = require("tests.helpers")
local client = require("opencode.client")
local session = require("opencode.session")
local http = require("opencode.http")

t.test("curl transports auth and prompt bytes over stdin and unwraps current session state", function()
  t.with_server(function(base)
    local command, input = http.command(base, "POST", { text = 'quotes " and \\ and\nnewlines' })
    assert(not table.concat(command, " "):find("fixture-password", 1, true))
    assert(input:find("fixture-password", 1, true))
    local done
    client.get_session("ses_active", function(err, value)
      assert(not err, err)
      t.eq("current-model", value.model.id)
      done = true
    end)
    t.wait(function()
      return done
    end)
    local text = 'Please explain "this" \\ path.\nKeep both lines.'
    done = false
    client.prompt("ses_active", { { type = "text", text = text } }, {}, function(err, value)
      assert(not err, err)
      t.eq("msg_admitted", value.id)
      t.eq(text, value.payload.text)
      done = true
    end)
    t.wait(function()
      return done
    end)
  end)
end)

t.test("native SSE filters locations and reconnects with a fresh session snapshot", function()
  t.with_server(function(base)
    session.update_active({ route = "session", session_id = "ses_active", cwd = "/fixture", workspace_id = "wrk_one" })
    local events, resyncs, refreshed = {}, 0, 0
    local group = vim.api.nvim_create_augroup("OpenCodeClientTest", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OpencodeEvent:*",
      callback = function(ev)
        table.insert(events, ev.data.event.type)
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OpencodeResync",
      callback = function()
        resyncs = resyncs + 1
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OpencodeSessionRefreshed",
      callback = function()
        refreshed = refreshed + 1
      end,
    })
    client.ensure_subscribed(true)
    t.wait(client.is_connected)
    t.wait(function()
      return refreshed == 1
    end)
    t.request(base, "/emit", "POST", { raw = ": heartbeat\r\n\r\ndata: not json\n\n" })
    t.request(base, "/emit", "POST", {
      type = "permission.asked",
      data = { sessionID = "ses_other" },
      location = { directory = "/fixture", workspaceID = "wrk_two" },
    })
    t.request(base, "/emit", "POST", { type = "session.execution.succeeded", data = { sessionID = "ses_active" } })
    t.wait(function()
      return vim.tbl_contains(events, "session.execution.succeeded")
    end)
    assert(not vim.tbl_contains(events, "permission.asked"))
    t.eq(1, resyncs)
    -- A scope switch does not open a second global connection.
    session.update_active({ route = "session", session_id = "ses_next", cwd = "/next" })
    client.ensure_subscribed()
    t.eq(1, #vim.tbl_filter(function(r)
      return r.path == "/api/event"
    end, t.request(base, "/requests").data))
    t.request(base, "/disconnect", "POST", {})
    t.wait(function()
      return resyncs == 2 and refreshed == 2
    end)
    t.eq("/next", client.get_status().directory)
    client.sse_unsubscribe()
    local count = resyncs
    vim.wait(350, function()
      return false
    end)
    t.eq(count, resyncs)
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
