--- Lualine statusline component
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Lualine component function
--- Returns a string like "⎇ PR #1234 ✓" when a review is active
---@return string
function M.component()
  if not state.is_active() then
    return ""
  end

  local pr = state.get_pr()
  if not pr then
    return ""
  end

  local icons = config.get().icons
  local status_icon = icons.review_required
  local decision = pr.review_decision or ""
  if decision == "APPROVED" then
    status_icon = icons.approved
  elseif decision == "CHANGES_REQUESTED" then
    status_icon = icons.changes_requested
  end

  return string.format("%s PR #%d %s", icons.branch, pr.number, status_icon)
end

--- Condition function: only show when review is active
---@return boolean
function M.condition()
  return state.is_active()
end

--- Returns a lualine component spec table
---@return table
function M.spec()
  return {
    M.component,
    cond = M.condition,
  }
end

return M
