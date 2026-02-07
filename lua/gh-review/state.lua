--- Singleton state for current PR review session
local M = {}

---@class GHReviewComment
---@field id string GraphQL node ID
---@field author string
---@field body string
---@field created_at string
---@field url string

---@class GHReviewThread
---@field id string GraphQL node ID
---@field path string File path relative to repo root
---@field line number Line number on the diff side (RIGHT side)
---@field start_line? number For multi-line comments
---@field side string "LEFT" or "RIGHT"
---@field is_resolved boolean
---@field is_outdated boolean
---@field comments GHReviewComment[]
---@field mapped_line? number Working tree line number (computed by diff.lua)

---@class GHReviewFile
---@field path string
---@field status string "added" | "modified" | "deleted" | "renamed"
---@field additions number
---@field deletions number
---@field old_path? string For renames

---@class GHReviewPRComment
---@field author string
---@field body string
---@field created_at string
---@field url string

---@class GHReviewPR
---@field number number
---@field title string
---@field author string
---@field base_ref string
---@field head_ref string
---@field url string
---@field body string PR description markdown
---@field review_decision string "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED" | ""
---@field repository string "owner/repo"

---@class GHReviewState
---@field pr? GHReviewPR
---@field files GHReviewFile[]
---@field threads GHReviewThread[]
---@field pr_comments GHReviewPRComment[] Top-level PR comments (not inline)
---@field diff_text string Raw unified diff
---@field active boolean

---@type GHReviewState
local state = {
  pr = nil,
  files = {},
  threads = {},
  pr_comments = {},
  diff_text = "",
  active = false,
}

function M.set_pr(pr)
  state.pr = pr
  state.active = true
end

function M.get_pr()
  return state.pr
end

function M.set_files(files)
  state.files = files
end

function M.get_files()
  return state.files
end

function M.set_threads(threads)
  state.threads = threads
end

function M.get_threads()
  return state.threads
end

--- Get threads for a specific file path
---@param path string
---@return GHReviewThread[]
function M.get_threads_for_file(path)
  local result = {}
  for _, thread in ipairs(state.threads) do
    if thread.path == path then
      table.insert(result, thread)
    end
  end
  return result
end

--- Get thread at a specific file and line
---@param path string
---@param line number
---@return GHReviewThread?
function M.get_thread_at(path, line)
  for _, thread in ipairs(state.threads) do
    if thread.path == path and thread.mapped_line == line then
      return thread
    end
  end
  return nil
end

--- Get thread at or nearest to cursor (within max_dist lines)
---@param path string
---@param line number
---@param max_dist? number defaults to 3
---@return GHReviewThread?
function M.get_nearest_thread(path, line, max_dist)
  -- Exact match first
  local exact = M.get_thread_at(path, line)
  if exact then return exact end

  max_dist = max_dist or 3
  local best, best_dist = nil, max_dist + 1
  for _, thread in ipairs(M.get_threads_for_file(path)) do
    if thread.mapped_line then
      local dist = math.abs(thread.mapped_line - line)
      if dist < best_dist then
        best_dist = dist
        best = thread
      end
    end
  end
  return best
end

function M.set_pr_comments(comments)
  state.pr_comments = comments
end

function M.get_pr_comments()
  return state.pr_comments
end

function M.set_diff_text(text)
  state.diff_text = text
end

function M.get_diff_text()
  return state.diff_text
end

function M.is_active()
  return state.active
end

function M.clear()
  state.pr = nil
  state.files = {}
  state.threads = {}
  state.pr_comments = {}
  state.diff_text = ""
  state.active = false
end

return M
