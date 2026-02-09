--- Shared pure helpers for gh-review.nvim
local M = {}

local config = require("gh-review.config")

--- Format an ISO 8601 timestamp to YYYY-MM-DD
---@param ts string ISO 8601 timestamp
---@return string
function M.format_time(ts)
  local date = ts:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date or ts
end

--- Get the icon for a review decision
---@param decision string? e.g. "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"
---@return string icon (may be empty string)
function M.review_icon(decision)
  local icons = config.get().icons
  if decision == "APPROVED" then
    return icons.approved
  elseif decision == "CHANGES_REQUESTED" then
    return icons.changes_requested
  elseif decision == "REVIEW_REQUIRED" then
    return icons.review_required
  end
  return ""
end

--- Build context lines from a list of comments (for reply UI)
---@param comments table[] each with .author and .body
---@return string[]
function M.build_thread_context(comments)
  local context_lines = {}
  for i, comment in ipairs(comments) do
    table.insert(context_lines, "@" .. comment.author .. ":")
    for body_line in comment.body:gmatch("[^\n]*") do
      table.insert(context_lines, "  " .. body_line)
    end
    if i < #comments then
      table.insert(context_lines, "")
    end
  end
  return context_lines
end

--- Run `git show <ref>` synchronously, return lines with trailing blank removed
---@param ref string e.g. "origin/main:path/to/file"
---@param cwd string working directory
---@return string[] lines (empty table on failure)
function M.git_show_lines(ref, cwd)
  local result = vim.system({ "git", "show", ref }, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 or not result.stdout then
    return {}
  end
  local lines = vim.split(result.stdout, "\n")
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Create a readonly scratch buffer with a name, filetype detection, and wipe-on-hide
---@param name string buffer name
---@param lines string[] content lines
---@param file_path string path used for filetype detection
---@return number buf
function M.create_scratch_buf(name, lines, file_path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local ft = vim.filetype.match({ filename = file_path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

return M
