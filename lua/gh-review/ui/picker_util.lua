--- Shared bits of the snacks.nvim pickers: how the entry the review is scoped to
--- is highlighted, and how the picker opens on it.
local M = {}

--- Marker in front of the entry the review is currently scoped to.
M.ACTIVE = "GHReviewPickerActive"
--- The rest of that entry's text, so the selected row reads as highlighted.
M.ACTIVE_ENTRY = "GHReviewPickerActiveEntry"

local defined = false

--- The PR number a picker query asks for: "123" or "#123". Nil for any other
--- query.
---@param pattern string?
---@return string?
function M.pr_number_query(pattern)
  return vim.trim(pattern or ""):match("^#?(%d+)$")
end

--- snacks.nvim `filter` option for pickers over PRs: a query that is a PR
--- number is rewritten by `rewrite` into a query that matches on numbers
--- only, so digits in titles and bodies do not match it.
---@param rewrite fun(number: string): string
---@return table
function M.pr_number_filter(rewrite)
  return {
    transform = function(_, filter)
      local number = M.pr_number_query(filter.pattern)
      if number then filter.pattern = rewrite(number) end
    end,
  }
end

--- Raw query typed in a snacks picker, or "".
---@param picker table
---@return string
function M.query(picker)
  local ok, pattern = pcall(function() return picker.input.filter.pattern end)
  return ok and type(pattern) == "string" and pattern or ""
end

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

--- Redraw a picker after its items changed in place (e.g. data loaded in the
--- background), optionally with a new title. A closed picker is left alone.
---@param picker table? snacks picker
---@param title? string
function M.redraw(picker, title)
  if not picker or picker.closed then return end
  if title then
    picker.title = title
    pcall(picker.update_titles, picker)
  end
  pcall(function() picker.list:update({ force = true }) end)
  pcall(function() picker:show_preview() end)
end

return M
