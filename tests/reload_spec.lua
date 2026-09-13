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
