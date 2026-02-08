--- PR fuzzy picker using snacks.nvim
local M = {}

local gh = require("gh-review.gh")
local config = require("gh-review.config")

--- Format review decision for display
---@param decision string?
---@return string
local function review_badge(decision)
  local icons = config.get().icons
  if decision == "APPROVED" then
    return " " .. icons.approved
  elseif decision == "CHANGES_REQUESTED" then
    return " " .. icons.changes_requested
  elseif decision == "REVIEW_REQUIRED" then
    return " " .. icons.review_required
  end
  return ""
end

--- Build preview lines for a PR
---@param pr table
---@return string[]
local function build_preview(pr)
  local lines = {}
  local author = pr.author and pr.author.login or "unknown"

  table.insert(lines, "# #" .. pr.number .. " " .. (pr.title or ""))
  table.insert(lines, "")
  table.insert(lines, "**Author:** @" .. author)
  table.insert(lines, "**Branch:** " .. (pr.headRefName or ""))
  table.insert(lines, "**State:** " .. (pr.state or ""))

  if pr.isDraft then
    table.insert(lines, "**Draft:** yes")
  end
  if pr.reviewDecision and pr.reviewDecision ~= "" then
    table.insert(lines, "**Review:** " .. pr.reviewDecision)
  end
  if pr.createdAt then
    local date = pr.createdAt:match("^(%d%d%d%d%-%d%d%-%d%d)")
    if date then
      table.insert(lines, "**Created:** " .. date)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  local body = pr.body or ""
  if body ~= "" then
    for line in body:gmatch("[^\n]*") do
      table.insert(lines, line)
    end
  else
    table.insert(lines, "_No description_")
  end

  return lines
end

--- Show the PR picker
---@param opts { on_select: fun(pr_number: number) }
function M.show(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for PR picker", vim.log.levels.ERROR)
    return
  end

  vim.notify("GHReview: fetching PRs...", vim.log.levels.INFO)

  gh.pr_list(function(err, prs)
    if err then
      vim.notify("GHReview: failed to list PRs: " .. err, vim.log.levels.ERROR)
      return
    end
    if not prs or #prs == 0 then
      vim.notify("GHReview: no open PRs found", vim.log.levels.INFO)
      return
    end

    local items = {}
    for _, pr in ipairs(prs) do
      local author = pr.author and pr.author.login or "unknown"
      local draft = pr.isDraft and "[DRAFT] " or ""
      local badge = review_badge(pr.reviewDecision)
      -- text includes all searchable fields
      local text = string.format(
        "#%d %s%s @%s %s",
        pr.number, draft, pr.title or "", author, pr.body or ""
      )
      table.insert(items, {
        text = text,
        _pr = pr,
        _author = author,
        _draft = draft,
        _badge = badge,
      })
    end

    Snacks.picker.pick({
      title = "Checkout PR",
      items = items,
      format = function(item)
        local pr = item._pr
        return {
          { "#" .. pr.number, "Number" },
          { "  " .. item._draft, "WarningMsg" },
          { pr.title or "", "Normal" },
          { "  @" .. item._author .. item._badge, "Special", virtual = true },
        }
      end,
      preview = function(ctx)
        local item = ctx.item
        if not item or not item._pr then return end
        local lines = build_preview(item._pr)
        ctx.preview:set_lines(lines)
        ctx.preview:highlight({ ft = "markdown" })
      end,
      confirm = function(picker, item)
        if not item then return end
        picker:close()
        if opts.on_select and item._pr then
          opts.on_select(item._pr.number)
        end
      end,
    })
  end)
end

return M
