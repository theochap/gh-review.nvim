--- Filter manager of the PR and stack lists: every filter in one list, the
--- active ones marked. Toggling several at once adds the inactive ones and
--- removes the active ones.
local M = {}

local config = require("gh-review.config")
local scope_mod = require("gh-review.scope")

--- Show the filters of `scope`. `<Tab>` selects options, `<cr>` toggles the
--- selected ones (or the one under the cursor), the clear key drops every
--- filter. `on_scope` gets the new scope.
---@param scope GHReviewScope
---@param on_scope fun(scope: GHReviewScope)
---@return table? picker
function M.show(scope, on_scope)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    scope_mod.prompt_filter(scope, on_scope)
    return nil
  end

  local items = {}
  for _, opt in ipairs(scope_mod.filter_options(scope)) do
    table.insert(items, { text = opt.label, _option = opt })
  end

  local pk = config.get().picker_keys
  local keys = {}
  if pk.clear_filters and pk.clear_filters ~= "" then
    keys[pk.clear_filters] = { "clear_filters", mode = { "i", "n" }, desc = "Clear filters" }
  end

  return Snacks.picker.pick({
    title = "Filters — <Tab> select · <cr> toggle"
      .. (keys[pk.clear_filters] and (" · " .. pk.clear_filters .. " clear all") or ""),
    items = items,
    layout = { preset = "select", preview = false },
    format = function(item)
      local opt = item._option
      return {
        { opt.active and "✓ " or "  ", opt.active and "DiagnosticOk" or "Comment" },
        { opt.label, opt.active and "Normal" or (opt.def and "Comment" or "Normal") },
      }
    end,
    confirm = function(picker)
      local picked = {}
      for _, item in ipairs(picker:selected({ fallback = true })) do
        if item._option then table.insert(picked, item._option) end
      end
      picker:close()
      if #picked == 0 then return end
      local new, prompts = scope_mod.toggle_filters(scope, picked)
      scope_mod.prompt_values(new, prompts, on_scope)
    end,
    actions = {
      clear_filters = function(picker)
        picker:close()
        on_scope(scope_mod.without_filters(scope))
      end,
    },
    win = { input = { keys = keys }, list = { keys = keys } },
  })
end

return M
