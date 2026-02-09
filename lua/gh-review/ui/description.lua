--- PR description page
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")
local gh = require("gh-review.gh")

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

  -- Stats
  local files = state.get_files()
  local total_add, total_del = 0, 0
  for _, f in ipairs(files) do
    total_add = total_add + (f.additions or 0)
    total_del = total_del + (f.deletions or 0)
  end
  table.insert(lines, #files .. " files changed, +" .. total_add .. " -" .. total_del)
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

  -- Commits
  local commits = state.get_commits()
  table.insert(lines, "## Commits (" .. #commits .. ")")
  table.insert(lines, "")
  if #commits == 0 then
    table.insert(lines, "(no commits)")
  else
    local active_commit = state.get_active_commit()
    for _, c in ipairs(commits) do
      local date = format_time(c.date or "")
      local prefix = (active_commit and active_commit.oid == c.oid) and "> " or "  "
      table.insert(lines, prefix .. "`" .. c.sha .. "` " .. c.message .. " — @" .. c.author .. " " .. date)
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

  -- New top-level comment
  vim.keymap.set("n", "n", function()
    require("gh-review.ui.comment_input").open({
      title = "New Comment on PR #" .. pr.number,
      on_submit = function(body)
        vim.notify("GHReview: posting comment...", vim.log.levels.INFO)
        gh.pr_add_comment(pr.number, body, function(err)
          if err then
            vim.notify("GHReview: comment failed: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("GHReview: comment posted", vim.log.levels.INFO)
            require("gh-review").refresh(function()
              M.refresh_buf(buf)
            end)
          end
        end)
      end,
    })
  end, kopts)

  -- Reply to a comment (cursor must be on/near a comment)
  vim.keymap.set("n", "r", function()
    local comments = state.get_pr_comments()
    if #comments == 0 then
      vim.notify("GHReview: no comments to reply to", vim.log.levels.INFO)
      return
    end
    -- Use the last comment as context for a reply
    local last = comments[#comments]
    local preview = last.body:match("^([^\n]+)") or ""
    if #preview > 50 then preview = preview:sub(1, 47) .. "..." end

    local context_lines = {}
    for _, comment in ipairs(comments) do
      table.insert(context_lines, "@" .. comment.author .. ":")
      for body_line in comment.body:gmatch("[^\n]*") do
        table.insert(context_lines, "  " .. body_line)
      end
      table.insert(context_lines, "")
    end

    require("gh-review.ui.comment_input").open({
      title = "Reply: " .. preview,
      context_lines = context_lines,
      on_submit = function(body)
        vim.notify("GHReview: posting reply...", vim.log.levels.INFO)
        gh.pr_add_comment(pr.number, body, function(err)
          if err then
            vim.notify("GHReview: reply failed: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("GHReview: reply posted", vim.log.levels.INFO)
            require("gh-review").refresh(function()
              M.refresh_buf(buf)
            end)
          end
        end)
      end,
    })
  end, kopts)

  -- Select commit for filtered review
  vim.keymap.set("n", "<cr>", function()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local line_text = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
    local sha = line_text:match("`(%x+)`")
    if not sha then return end

    local commits = state.get_commits()
    for _, c in ipairs(commits) do
      if c.sha == sha then
        require("gh-review").select_commit(c)
        M.refresh_buf(buf)
        return
      end
    end
  end, kopts)

  -- Clear commit filter
  vim.keymap.set("n", "x", function()
    require("gh-review").clear_commit()
    M.refresh_buf(buf)
  end, kopts)

  return win, buf
end

--- Refresh the description buffer content (if it exists)
---@param buf number
function M.refresh_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = build_lines()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

return M
