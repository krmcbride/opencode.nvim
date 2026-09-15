local t = require("tests.helpers")
local queue = require("opencode.review_queue")
local session = require("opencode.session")
local client = require("opencode.client")

t.test("review queue retains rejected and malformed sends and clears only admitted unchanged comments", function()
  t.with_server(function(base)
    local notifications = {}
    local notify = vim.notify
    vim.notify = function(message)
      table.insert(notifications, message)
    end
    local ok, err = xpcall(function()
      local selection = { path = "/fixture/example.txt", start_line = 2, end_line = 3 }
      queue.clear()
      assert(queue.add(selection, "First comment"))
      for _, id in ipairs({ "ses_rejected", "ses_malformed" }) do
        session.update_active({ route = "session", session_id = id, cwd = "/fixture" })
        queue.send()
        t.wait(function()
          return #notifications > 0
        end)
        t.eq(1, queue.count())
        notifications = {}
      end
      session.update_active({ route = "session", session_id = "ses_delayed", cwd = "/fixture" })
      local first = queue.items()[1].id
      queue.send()
      queue.update(first, "Edited while sending")
      assert(queue.add(selection, "Added while sending"))
      t.wait(function()
        return #notifications > 0
      end)
      t.eq(2, queue.count())
      notifications = {}
      queue.send()
      t.wait(function()
        return queue.count() == 0
      end)
      local requests = t.request(base, "/requests").data
      local prompts = vim.tbl_filter(function(r)
        return r.path:match("/prompt$")
      end, requests)
      t.eq(4, #prompts)
      t.eq(2, #prompts[4].body.files)
      assert(prompts[4].body.text:find("Edited while sending", 1, true))
      for _, r in ipairs(prompts) do
        t.eq("queue", r.body.delivery)
        t.eq(nil, r.body.agent)
        t.eq(nil, r.body.model)
      end
    end, debug.traceback)
    vim.notify = notify
    queue.clear()
    client.sse_unsubscribe()
    assert(ok, err)
  end)
end)
