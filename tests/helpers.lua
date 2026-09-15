local M = { passed = 0, failed = 0 }
function M.eq(expected, actual)
  assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. "\nactual " .. vim.inspect(actual))
end
function M.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    M.passed = M.passed + 1
    print("PASS " .. name)
  else
    M.failed = M.failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
function M.wait(predicate, message)
  assert(vim.wait(5000, predicate, 10), message or "timed out")
end
function M.request(base, path, method, body)
  local done, result
  require("opencode.http").request(base .. path, method or "GET", body, function(err, value, status)
    result, done = { err, value, status }, true
  end)
  M.wait(function()
    return done
  end)
  assert(not result[1], result[1])
  return result[2]
end
function M.with_server(fn)
  local config = require("opencode.config")
  local old = config.opts
  local password, legacy = vim.env.OPENCODE_PASSWORD, vim.env.OPENCODE_SERVER_PASSWORD
  vim.env.OPENCODE_PASSWORD, vim.env.OPENCODE_SERVER_PASSWORD = "fixture-password", "ignored-password"
  local base
  local server = vim.system({ "bun", "tests/server.ts" }, {
    stdout = function(_, data)
      if data then
        base = data:match("http://127%.0%.0%.1:%d+") or base
      end
    end,
  })
  local ok, err = xpcall(function()
    M.wait(function()
      return base
    end, "fixture did not start")
    config.setup({ server = { url = base } })
    fn(base)
  end, debug.traceback)
  require("opencode.client").sse_unsubscribe()
  server:kill(15)
  server:wait()
  config.opts = old
  vim.env.OPENCODE_PASSWORD, vim.env.OPENCODE_SERVER_PASSWORD = password, legacy
  assert(ok, err)
end
return M
