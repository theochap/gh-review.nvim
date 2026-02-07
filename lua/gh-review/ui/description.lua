--- PR description page
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Format a timestamp for display
---@param ts string ISO 8601 timestamp
---@return string
local function format_time(ts)
  local date = ts:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date or ts
end

--- Build the description buffer content
---@return string[]
local function build_lines()
  local pr = state.get_pr()
  if not pr then return { "(no active PR)" } end

  local icons = config.get().icons
  local lines = {}

  -- Title
  table.insert(lines, "# PR #" .. pr.number .. ": " .. pr.title)
  table.insert(lines, "")

  -- Metadata line
  local status_icon = ""
  if pr.review_decision == "APPROVED" then
    status_icon = icons.approved
  elseif pr.review_decision == "CHANGES_REQUESTED" then
    status_icon = icons.changes_requested
  elseif pr.review_decision == "REVIEW_REQUIRED" then
    status_icon = icons.review_required
  end
  local status_str = pr.review_decision ~= "" and (pr.review_decision .. " " .. status_icon) or "PENDING"
  table.insert(lines, "Author: @" .. pr.author .. " | Status: " .. status_str .. " | Base: " .. pr.base_ref .. " <- " .. pr.head_ref)
  table.insert(lines, "URL: " .. pr.url)
  table.insert(lines, "")

  -- Description
  table.insert(lines, "## Description")
  table.insert(lines, "")
  local body = pr.body or ""
  if body == "" then
    table.insert(lines, "(no description)")
  else
    for line in body:gmatch("[^\n]*") do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")

  -- Top-level comments
  local comments = state.get_pr_comments()
  table.insert(lines, "## Comments (" .. #comments .. ")")
  table.insert(lines, "")

  if #comments == 0 then
    table.insert(lines, "(no top-level comments)")
  else
    for i, comment in ipairs(comments) do
      local author = comment.author or "unknown"
      local date = format_time(comment.created_at or "")
      table.insert(lines, "@" .. author .. " -- " .. date)
      for body_line in (comment.body or ""):gmatch("[^\n]*") do
        table.insert(lines, "  " .. body_line)
      end
      if i < #comments then
        table.insert(lines, "")
      end
    end
  end

  return lines
end

--- Show the PR description page in a bottom split
function M.show()
  local pr = state.get_pr()
  if not pr then
    vim.notify("GHReview: no active review", vim.log.levels.WARN)
    return
  end

  -- Check if buffer already exists and is visible
  local buf_name = "gh-review://description"
  local buf = vim.fn.bufnr(buf_name)

  -- If already visible in a window, focus it
  if buf ~= -1 then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end

  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, buf_name)
  end

  local lines = build_lines()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buflisted = false

  -- Open in a bottom split
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.cmd("resize 20")
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 0

  -- Buffer-local keymaps
  local kopts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, kopts)

  vim.keymap.set("n", "o", function()
    if pr.url then
      vim.ui.open(pr.url)
    end
  end, kopts)

  return win, buf
end

return M
