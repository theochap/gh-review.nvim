--- Unified single-buffer diff view (VS Code–style).
--- Renders a synthetic readonly buffer containing, per hunk:
---   1. a hunk-header line (@@ -old,count +new,count @@)
---   2. context lines
---   3. all deletions as a contiguous block (DiffDelete background)
---   4. all additions as a contiguous block (DiffAdd background)
--- The ordering of deletions-then-additions is already how git's unified
--- format emits lines within each change region, so we just stream the
--- parsed hunk lines in order.

local M = {}

local state = require("gh-review.state")
local util = require("gh-review.util")
local diff_module = require("gh-review.diff")

local NS = vim.api.nvim_create_namespace("gh_review_unified")

---@class GHUnifiedState
---@field file_path? string
---@field buf? number
---@field win? number
local current = { file_path = nil, buf = nil, win = nil }

local function buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Render a parsed DiffFile into buffer lines + highlight directives.
---@param file_diff DiffFile
---@return string[] lines
---@return table[] highlights each { row (1-indexed), hl_group }
---@return table[] row_map each { row → { old_line? new_line? } } for future statuscolumn use
function M._render(file_diff)
  local lines = {}
  local highlights = {}
  local row_map = {}

  for h_idx, hunk in ipairs(file_diff.hunks) do
    -- Hunk header
    table.insert(lines, string.format("@@ -%d,%d +%d,%d @@",
      hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count))
    table.insert(highlights, { #lines, "DiffText" })
    row_map[#lines] = { kind = "header" }

    local old_line = hunk.old_start
    local new_line = hunk.new_start

    for _, dline in ipairs(hunk.lines) do
      local prefix = dline:sub(1, 1)
      local content = dline:sub(2)
      table.insert(lines, content)
      local row = #lines
      if prefix == "-" then
        table.insert(highlights, { row, "DiffDelete" })
        row_map[row] = { kind = "del", old = old_line }
        old_line = old_line + 1
      elseif prefix == "+" then
        table.insert(highlights, { row, "DiffAdd" })
        row_map[row] = { kind = "add", new = new_line }
        new_line = new_line + 1
      else
        -- context
        row_map[row] = { kind = "ctx", old = old_line, new = new_line }
        old_line = old_line + 1
        new_line = new_line + 1
      end
    end

    if h_idx < #file_diff.hunks then
      table.insert(lines, "")
      row_map[#lines] = { kind = "sep" }
    end
  end

  return lines, highlights, row_map
end

--- Find the buffer row whose row_map entry matches the target new-tree line.
---@param row_map table[]
---@param target_line number
---@return number? row 1-indexed row or nil
local function row_for_new_line(row_map, target_line)
  for row, info in pairs(row_map) do
    if info.new == target_line then return row end
  end
  return nil
end

--- Open the unified view for `file_path` (PR-relative), optionally positioning
--- the cursor near the working-tree line `line`.
---@param file_path string
---@param line? number Working-tree line to jump to, if present in the diff.
function M.open(file_path, line)
  local diff_text = state.get_diff_text()
  if not diff_text or diff_text == "" then
    vim.notify("GHReview: no diff data loaded", vim.log.levels.WARN)
    return
  end

  local files = diff_module.parse(diff_text)
  local file_diff = files[file_path]
  if not file_diff or #file_diff.hunks == 0 then
    vim.notify("GHReview: no diff for " .. file_path, vim.log.levels.INFO)
    return
  end

  -- Reopening same file → just reposition
  if current.file_path == file_path and buf_valid(current.buf) and win_valid(current.win) then
    vim.api.nvim_set_current_win(current.win)
    vim.api.nvim_win_set_buf(current.win, current.buf)
    if line then
      local row = row_for_new_line(vim.b[current.buf]._gh_unified_rowmap or {}, line)
      if row then
        vim.api.nvim_win_set_cursor(current.win, { row, 0 })
        vim.cmd("normal! zz")
      end
    end
    return
  end

  M.close()

  local buf_lines, highlights, row_map = M._render(file_diff)

  local buf = util.create_scratch_buf("ghreview://unified/" .. file_path, buf_lines, file_path)
  vim.b[buf]._gh_unified_rowmap = row_map

  vim.api.nvim_win_set_buf(0, buf)
  current.buf = buf
  current.win = vim.api.nvim_get_current_win()
  current.file_path = file_path

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, NS, hl[2], hl[1] - 1, 0, -1)
  end

  if line then
    local row = row_for_new_line(row_map, line)
    if row then
      vim.api.nvim_win_set_cursor(current.win, { row, 0 })
      vim.cmd("normal! zz")
    end
  end
end

--- Close the unified view (deletes its buffer).
function M.close()
  if buf_valid(current.buf) then
    vim.api.nvim_buf_delete(current.buf, { force = true })
  end
  current.file_path = nil
  current.buf = nil
  current.win = nil
end

--- Whether a unified view is currently open.
---@return boolean
function M.is_active()
  return current.file_path ~= nil and buf_valid(current.buf) and win_valid(current.win)
end

--- Get the path of the unified-view file if we're currently in that window.
---@return string?
function M.get_file_path()
  if not current.file_path then return nil end
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win == current.win then return current.file_path end
  return nil
end

return M
