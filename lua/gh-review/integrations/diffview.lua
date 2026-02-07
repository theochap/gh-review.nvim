--- Diffview.nvim integration
local M = {}

local state = require("gh-review.state")

--- Open diffview for the current PR against its merge base
---@param file_path? string Optional specific file to diff
function M.open(file_path)
  local ok, _ = pcall(require, "diffview")
  if not ok then
    vim.notify("diffview.nvim is required for diff view", vim.log.levels.ERROR)
    return
  end

  local pr = state.get_pr()
  if not pr then
    vim.notify("No active PR review", vim.log.levels.WARN)
    return
  end

  local cmd = "DiffviewOpen " .. pr.base_ref .. "...HEAD"
  if file_path then
    cmd = cmd .. " -- " .. file_path
  end
  vim.cmd(cmd)
end

--- Close diffview
function M.close()
  pcall(vim.cmd, "DiffviewClose")
end

return M
