--- Lualine statusline component
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")
local util = require("gh-review.util")

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
  local status_icon = util.review_icon(pr.review_decision or "")
  if status_icon == "" then
    status_icon = icons.review_required
  end

  local base = string.format("%s #%d %s %s", icons.branch, pr.number, pr.head_ref or "", status_icon)
  local active_commit = state.get_active_commit()
  if active_commit then
    local msg = active_commit.message or ""
    if #msg > 30 then
      msg = msg:sub(1, 27) .. "..."
    end
    return base .. " @ " .. active_commit.sha .. " " .. msg
  end
  return base
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
