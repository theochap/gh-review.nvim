--- Shared bits of the snacks.nvim pickers: how the entry the review is scoped to
--- is highlighted, and how the picker opens on it.
local M = {}

--- Marker in front of the entry the review is currently scoped to.
M.ACTIVE = "GHReviewPickerActive"
--- The rest of that entry's text, so the selected row reads as highlighted.
M.ACTIVE_ENTRY = "GHReviewPickerActiveEntry"

local defined = false

--- Define the plugin's highlight groups. Both are `default`, so a colorscheme or
--- a user override always wins.
function M.ensure_highlights()
  if defined then return end
  defined = true
  vim.api.nvim_set_hl(0, M.ACTIVE, { link = "CurSearch", default = true })
  vim.api.nvim_set_hl(0, M.ACTIVE_ENTRY, { link = "Visual", default = true })
end

--- Put the cursor on the entry the review is scoped to, so an already selected
--- commit is where the picker opens instead of something the user has to hunt
--- for. Safe to pass as `on_show`.
---@param picker table snacks picker
---@param is_current fun(item: table): boolean?
function M.focus_current(picker, is_current)
  for i, item in ipairs(picker:items()) do
    if is_current(item) then
      picker.list:view(i)
      -- Centering is cosmetic, and the action is snacks' to rename.
      pcall(function() require("snacks").picker.actions.list_scroll_center(picker) end)
      return
    end
  end
end

return M
