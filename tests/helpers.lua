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
return M
