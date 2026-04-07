---Input helpers for opencode.nvim.
local M = {}

---@param opts { prompt?: string, default?: string, title?: string }
---@param on_confirm fun(value?: string)
function M.review(opts, on_confirm)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.input then
    local width = math.max(48, math.min(72, vim.o.columns - 8))
    snacks.input({
      prompt = opts.title or opts.prompt,
      default = opts.default,
      expand = false,
      win = {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        border = "rounded",
        title_pos = "left",
      },
    }, on_confirm)
    return
  end

  vim.ui.input(opts, on_confirm)
end

return M
