vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = "./?.lua;" .. package.path
-- Composer UI is covered by the optional real Snacks smoke test.
package.preload["snacks"] = function()
  return {}
end
local t = require("tests.helpers")
for _, path in ipairs(vim.fn.glob("tests/*_spec.lua", false, true)) do
  dofile(path)
end
print(("Lua: %d passed, %d failed"):format(t.passed, t.failed))
vim.cmd(t.failed == 0 and "qa!" or "cquit 1")
