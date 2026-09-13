local t = require("tests.helpers")

t.test("watchdog tolerates v2 heartbeats and ignores stale stream/probe callbacks", function()
  require("opencode.client").sse_unsubscribe()
  local system, new_timer = vim.system, vim.uv.new_timer
  local timers, jobs = {}, {}
  vim.uv.new_timer = function()
    local timer = { stop = function() end }
    timer.start = function(_, delay, _, cb)
      timer.delay, timer.callback = delay, cb
    end
    table.insert(timers, timer)
    return timer
  end
  vim.system = function(command, opts, complete)
    local job = { command = command, opts = opts, complete = complete, kill = function() end }
    table.insert(jobs, job)
    return job
  end
  package.loaded["opencode.client"] = nil
  local client = require("opencode.client")
  local function flush()
    vim.wait(10, function()
      return false
    end)
  end
  local ok, err = xpcall(function()
    require("opencode.session").update_active({ route = "home" })
    client.ensure_subscribed()
    jobs[1].complete({ code = 0, stdout = '{"healthy":true,"version":"2.0.1"}\n200' })
    flush()
    local stream = jobs[2]
    t.eq(45000, timers[1].delay)
    stream.opts.stdout(nil, ": heartbeat\n\n")
    flush()
    assert(client.is_connected())
    -- The full grace period restarts on comments and unrelated event frames.
    stream.opts.stdout(nil, 'data: {"type":"permission.asked","data":{"sessionID":"ses_other"}}\n\n')
    flush()
    t.eq(45000, timers[1].delay)
    timers[1].callback()
    flush()
    assert(not client.is_connected())
    t.eq(250, timers[2].delay)
    timers[2].callback()
    flush()
    local probe = jobs[3]
    client.sse_unsubscribe()
    stream.opts.stdout(nil, ": heartbeat\n\n")
    stream.complete({ code = 0 })
    probe.complete({ code = 0, stdout = '{"healthy":true,"version":"2.0.1"}\n200' })
    flush()
    t.eq(3, #jobs)
    assert(not client.is_connected())
    client.ensure_subscribed()
    jobs[4].complete({ code = 0, stdout = '{"healthy":true,"version":"1.18.30"}\n200' })
    flush()
    t.eq(4, #jobs) -- a v1 daemon never opens an event stream
    client.sse_unsubscribe()
  end, debug.traceback)
  vim.system, vim.uv.new_timer = system, new_timer
  package.loaded["opencode.client"] = nil
  assert(ok, err)
end)

t.test("a retry already queued on the main loop cannot survive unsubscribe", function()
  local system, new_timer = vim.system, vim.uv.new_timer
  local timers, jobs = {}, {}
  vim.uv.new_timer = function()
    local timer = { stop = function() end }
    timer.start = function(_, _, _, callback)
      timer.callback = callback
    end
    table.insert(timers, timer)
    return timer
  end
  vim.system = function(command, opts, complete)
    local job = { command = command, opts = opts, complete = complete, kill = function() end }
    table.insert(jobs, job)
    return job
  end
  package.loaded["opencode.client"] = nil
  local client = require("opencode.client")
  local function flush()
    vim.wait(10, function()
      return false
    end)
  end
  local ok, err = xpcall(function()
    client.ensure_subscribed()
    jobs[1].complete({ code = 7 })
    flush()
    timers[2].callback() -- schedule_wrap has queued work that timer:stop cannot cancel
    client.sse_unsubscribe()
    flush()
    t.eq(1, #jobs)
    client.ensure_subscribed()
    t.eq(2, #jobs)
    jobs[2].complete({ code = 7 })
    flush()
    timers[2].callback()
    client.sse_unsubscribe()
    client.ensure_subscribed() -- a newer subscription must also survive the old retry
    local probe = jobs[3]
    flush()
    t.eq(3, #jobs)
    probe.complete({ code = 0, stdout = '{"healthy":true,"version":"2.0.1"}\n200' })
    flush()
    jobs[4].opts.stdout(nil, ": heartbeat\n\n")
    flush()
    assert(client.is_connected())
  end, debug.traceback)
  client.sse_unsubscribe()
  vim.system, vim.uv.new_timer = system, new_timer
  package.loaded["opencode.client"] = nil
  assert(ok, err)
end)
