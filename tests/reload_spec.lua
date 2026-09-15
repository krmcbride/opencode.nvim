local t = require("tests.helpers")
local reload = require("opencode.reload")

t.test("reload coalesces settlement events and preserves dirty/unrelated buffers", function()
  local root = assert(vim.uv.fs_mkdtemp((vim.env.TMPDIR or "/tmp") .. "/opencode-reload.XXXXXX"))
  local files = { root .. "/clean.txt", root .. "/dirty.txt", root .. "/other/outside.txt" }
  vim.fn.mkdir(root .. "/other")
  for _, path in ipairs(files) do
    vim.fn.writefile({ "original" }, path)
  end
  local buffers = {}
  for _, path in ipairs(files) do
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].autoread = true
    table.insert(buffers, buf)
  end
  vim.api.nvim_buf_set_lines(buffers[2], 0, -1, false, { "unsaved editor change" })
  for _, path in ipairs(files) do
    vim.fn.writefile({ "longer disk replacement" }, path)
  end
  reload.request({ file = files[1] })
  reload.request({ file = files[1] })
  reload.request({ file = files[2] })
  t.wait(function()
    return vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false)[1] == "longer disk replacement"
  end)
  t.eq({ "unsaved editor change" }, vim.api.nvim_buf_get_lines(buffers[2], 0, -1, false))
  t.eq({ "original" }, vim.api.nvim_buf_get_lines(buffers[3], 0, -1, false))
  for _, buf in ipairs(buffers) do
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.fn.delete(root, "rf")
end)

t.test("reload honors inherited autoread and explicit buffer overrides", function()
  local root = assert(vim.uv.fs_mkdtemp((vim.env.TMPDIR or "/tmp") .. "/opencode-autoread.XXXXXX"))
  local buffers, global = {}, vim.go.autoread
  local ok, err = xpcall(function()
    vim.go.autoread = true
    for _, name in ipairs({ "inherited.txt", "override.txt" }) do
      local path = root .. "/" .. name
      vim.fn.writefile({ "original" }, path)
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      table.insert(buffers, buf)
    end
    vim.bo[buffers[2]].autoread = false
    local function replace(text)
      for _, buf in ipairs(buffers) do
        vim.fn.writefile({ text }, vim.api.nvim_buf_get_name(buf))
      end
      reload.request({ directory = root })
    end
    replace("first disk replacement")
    t.wait(function()
      return vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false)[1] == "first disk replacement"
    end)
    t.eq({ "original" }, vim.api.nvim_buf_get_lines(buffers[2], 0, -1, false))
    vim.go.autoread = false
    vim.bo[buffers[2]].autoread = true
    replace("second longer disk replacement")
    t.wait(function()
      return vim.api.nvim_buf_get_lines(buffers[2], 0, -1, false)[1] == "second longer disk replacement"
    end)
    t.eq({ "first disk replacement" }, vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false))
  end, debug.traceback)
  for _, buf in ipairs(buffers) do
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.go.autoread = global
  vim.fn.delete(root, "rf")
  assert(ok, err)
end)
