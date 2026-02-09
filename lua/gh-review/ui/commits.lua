--- Commits picker using snacks.nvim (floating)
local M = {}

local state = require("gh-review.state")
local util = require("gh-review.util")

--- Toggle the commits picker (open / close)
function M.toggle()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for commits panel", vim.log.levels.ERROR)
    return
  end

  local pickers = Snacks.picker.get({ source = "gh_review_commits" })
  if #pickers > 0 then
    pickers[1]:close()
    return
  end
  M.show()
end

--- Show the commits picker
function M.show()
  local commits = state.get_commits()
  if #commits == 0 then
    vim.notify("GHReview: no commits", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for commits panel", vim.log.levels.ERROR)
    return
  end

  local active_commit = state.get_active_commit()
  local items = {}
  for _, c in ipairs(commits) do
    local is_active = active_commit and active_commit.oid == c.oid
    table.insert(items, {
      text = c.sha .. " " .. c.message .. " " .. c.author,
      _commit = c,
      _is_active = is_active,
    })
  end

  Snacks.picker.pick({
    source = "gh_review_commits",
    title = "PR Commits",
    items = items,
    layout = { preset = "select", preview = false },
    format = function(item)
      local c = item._commit
      local prefix = item._is_active and "> " or "  "
      local prefix_hl = item._is_active and "CurSearch" or "SnacksPickerIdx"
      local date = util.format_time(c.date or "")
      return {
        { prefix, prefix_hl },
        { c.sha, "Identifier" },
        { " " .. c.message },
        { "  @" .. c.author .. " " .. date, "Comment", virtual = true },
      }
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      local c = item._commit
      local active = state.get_active_commit()
      if active and active.oid == c.oid then
        require("gh-review").clear_commit()
      else
        require("gh-review").select_commit(c)
      end
    end,
    actions = {
      clear_commit = function(picker)
        picker:close()
        require("gh-review").clear_commit()
      end,
    },
    win = {
      input = {
        keys = {
          ["x"] = { "clear_commit", desc = "Clear commit filter" },
        },
      },
      list = {
        keys = {
          ["x"] = { "clear_commit", desc = "Clear commit filter" },
        },
      },
    },
  })
end

return M
