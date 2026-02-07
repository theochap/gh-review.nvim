--- Unified diff parser and line number mapping
--- Maps GitHub diff positions (left/right side line numbers) to working tree lines
local M = {}

---@class DiffHunk
---@field old_start number
---@field old_count number
---@field new_start number
---@field new_count number
---@field lines string[]

---@class DiffFile
---@field path string
---@field hunks DiffHunk[]

--- Parse a unified diff string into structured data
---@param diff_text string
---@return table<string, DiffFile> Map of path -> DiffFile
function M.parse(diff_text)
  local files = {}
  local current_file = nil
  local current_hunk = nil

  for line in diff_text:gmatch("[^\n]*") do
    -- Detect file header: diff --git a/path b/path
    local path = line:match("^diff %-%-git a/.+ b/(.+)$")
    if path then
      current_file = { path = path, hunks = {} }
      files[path] = current_file
      current_hunk = nil
    end

    -- Detect hunk header: @@ -old_start,old_count +new_start,new_count @@
    if current_file then
      local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if os then
        current_hunk = {
          old_start = tonumber(os),
          old_count = tonumber(oc) or 1,
          new_start = tonumber(ns),
          new_count = tonumber(nc) or 1,
          lines = {},
        }
        table.insert(current_file.hunks, current_hunk)
      elseif current_hunk and (line:sub(1, 1) == "+" or line:sub(1, 1) == "-" or line:sub(1, 1) == " ") then
        table.insert(current_hunk.lines, line)
      end
    end
  end

  return files
end

--- Map a diff-side line number to a working tree line number
--- GitHub stores comment positions as line numbers on LEFT or RIGHT side of the diff.
--- LEFT = old file line number, RIGHT = new file line number.
--- For RIGHT side, the line number IS the working tree line number (for non-deleted files).
--- For LEFT side, we need to find the corresponding new line number.
---@param diff_file DiffFile
---@param diff_line number Line number as stored by GitHub
---@param side string "LEFT" or "RIGHT"
---@return number? Working tree line number, nil if line was deleted
function M.map_to_working_tree(diff_file, diff_line, side)
  if side == "RIGHT" then
    -- RIGHT side line numbers correspond directly to new file lines
    return diff_line
  end

  -- LEFT side: find the corresponding new line number
  -- Walk through hunks to find where this old line maps to
  for _, hunk in ipairs(diff_file.hunks) do
    local old_line = hunk.old_start
    local new_line = hunk.new_start

    for _, l in ipairs(hunk.lines) do
      local prefix = l:sub(1, 1)
      if prefix == " " then
        -- Context line: exists in both
        if old_line == diff_line then
          return new_line
        end
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        -- Removed line: only in old
        if old_line == diff_line then
          -- This line was deleted; map to the nearest new line
          return new_line
        end
        old_line = old_line + 1
      elseif prefix == "+" then
        -- Added line: only in new
        new_line = new_line + 1
      end
    end
  end

  -- Line is outside any hunk; compute offset from cumulative hunk changes
  local offset = 0
  for _, hunk in ipairs(diff_file.hunks) do
    if hunk.old_start + hunk.old_count <= diff_line then
      offset = offset + (hunk.new_count - hunk.old_count)
    end
  end
  return diff_line + offset
end

--- Map all threads' line numbers to working tree line numbers
---@param threads table[] List of GHReviewThread
---@param diff_files table<string, DiffFile>
---@return table[] threads with mapped_line populated
function M.map_threads(threads, diff_files)
  for _, thread in ipairs(threads) do
    local df = diff_files[thread.path]
    if df and thread.line then
      thread.mapped_line = M.map_to_working_tree(df, thread.line, thread.side)
    else
      -- No diff info; best effort: use the line as-is
      thread.mapped_line = thread.line
    end
  end
  return threads
end

return M
