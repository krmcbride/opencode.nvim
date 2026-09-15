local t = require("tests.helpers")
local config = require("opencode.config")
local session = require("opencode.session")
local previous = package.loaded["snacks.terminal"]
local captured
package.loaded["snacks.terminal"] = {
  get = function(cmd, opts)
    captured = { cmd, opts }
  end,
  open = function(cmd, opts)
    captured = { cmd, opts }
  end,
}
package.loaded["opencode.terminal"] = nil
local terminal = require("opencode.terminal")
local saved = { vim.env.OPENCODE_PASSWORD, vim.env.OPENCODE_SERVER_PASSWORD }
vim.env.OPENCODE_PASSWORD = "v2-test-password"
vim.env.OPENCODE_SERVER_PASSWORD = "legacy-test-password"

t.test("v2 launch uses explicit server, positional absolute directory, and continue", function()
  config.setup({ terminal = { dir = "/tmp/project $HOME `echo escaped`", env = { OPENCODE_PASSWORD = "wrong" } } })
  terminal.get()
  local cmd, opts = unpack(captured)
  assert(cmd:find("opencode --server ", 1, true))
  assert(not cmd:find("attach", 1, true))
  assert(not cmd:find("--dir", 1, true))
  assert(cmd:find("--continue", 1, true))
  -- Evaluate only the generated argument quoting; printf cannot execute a TUI.
  local args = vim.system({ "sh", "-c", "set -- " .. cmd .. '; printf "%s\\n" "$@"' }, { text = true }):wait()
  t.eq(0, args.code)
  assert(args.stdout:find("/tmp/project $HOME `echo escaped`", 1, true))
  t.eq("v2-test-password", opts.env.OPENCODE_PASSWORD)
  t.eq("opencode", config.get_auth().username)
end)

t.test("explicit session takes precedence and new session omits continue", function()
  terminal.get({ session_id = "ses_test" })
  assert(captured[1]:find("--session 'ses_test'", 1, true))
  assert(not captured[1]:find("--continue", 1, true))
  terminal.start({ continue = false })
  assert(not captured[1]:find("--continue", 1, true))
end)

t.test("custom terminal commands are preserved", function()
  config.setup({ terminal = { cmd = "custom-tui --flag" } })
  terminal.get()
  t.eq("custom-tui --flag", captured[1])
end)

t.test("workspace changes update session identity even with the same directory", function()
  session.update_active({ route = "session", session_id = "ses_test", cwd = "/tmp/project", workspace_id = "wrk_one" })
  t.eq("wrk_one", session.get_state().workspace_id)
  session.update_active({ route = "session", session_id = "ses_test", cwd = "/tmp/project" })
  t.eq(nil, session.get_state().workspace_id)
end)
vim.env.OPENCODE_PASSWORD, vim.env.OPENCODE_SERVER_PASSWORD = saved[1], saved[2]
config.setup()
session.update_active({ route = "home" })
require("opencode.editor_context").stop()
package.loaded["snacks.terminal"] = previous
package.loaded["opencode.terminal"] = nil
