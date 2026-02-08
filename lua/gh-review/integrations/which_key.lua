--- Which-key integration: register <leader>gp group
local M = {}

local config = require("gh-review.config")

--- Register keybindings with which-key
function M.register()
  local ok, wk = pcall(require, "which-key")
  if not ok then
    return
  end

  local prefix = config.get().keymaps.prefix
  wk.add({
    { prefix, group = "PR Review" },
    { prefix .. "o", desc = "Checkout PR" },
    { prefix .. "O", desc = "Review PR for current branch" },
    { prefix .. "f", desc = "Toggle file tree" },
    { prefix .. "c", desc = "Toggle comments panel" },
    { prefix .. "r", desc = "Reply to thread" },
    { prefix .. "n", desc = "New comment thread" },
    { prefix .. "t", desc = "Toggle resolve" },
    { prefix .. "v", desc = "View comment at cursor" },
    { prefix .. "d", desc = "PR description" },
    { prefix .. "D", desc = "Toggle diff overlay" },
    { prefix .. "e", desc = "Open file with diff overlay" },
    { prefix .. "R", desc = "Refresh PR data" },
    { prefix .. "q", desc = "Close review" },
    { "]d", desc = "Next diff hunk (cross-file)" },
    { "[d", desc = "Prev diff hunk (cross-file)" },
  })
end

return M
