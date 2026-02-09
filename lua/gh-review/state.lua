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
---@field commit_oid? string OID of the commit associated with this thread
---@field comments GHReviewComment[]
---@field mapped_line? number Working tree line number (computed by diff.lua)

---@class GHReviewCommit
---@field sha string
---@field oid string
---@field message string
---@field author string
---@field authored_date string

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
---@field commits GHReviewCommit[]
---@field active_commit? GHReviewCommit
---@field commit_files GHReviewFile[]

---@type GHReviewState
local state = {
  pr = nil,
  files = {},
  threads = {},
  pr_comments = {},
  diff_text = "",
  active = false,
  commits = {},
  active_commit = nil,
  commit_files = {},
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
  local result = {}
  for _, thread in ipairs(state.threads) do
    if not thread.is_outdated then
      table.insert(result, thread)
    end
  end
  return result
end

--- Get threads for a specific file path
---@param path string
---@return GHReviewThread[]
function M.get_threads_for_file(path)
  local result = {}
  for _, thread in ipairs(state.threads) do
    if thread.path == path and not thread.is_outdated then
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
    if thread.path == path and thread.mapped_line == line and not thread.is_outdated then
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

function M.set_commits(commits)
  state.commits = commits
end

function M.get_commits()
  return state.commits
end

function M.set_active_commit(commit)
  state.active_commit = commit
end

function M.get_active_commit()
  return state.active_commit
end

function M.clear_active_commit()
  state.active_commit = nil
  state.commit_files = {}
end

function M.set_commit_files(files)
  state.commit_files = files
end

function M.get_commit_files()
  return state.commit_files
end

--- Get the effective file list: commit files when viewing a commit, PR files otherwise
---@return GHReviewFile[]
function M.get_effective_files()
  if state.active_commit then
    return state.commit_files
  end
  return state.files
end

--- Get the effective threads: filtered to commit when viewing a commit, all PR threads otherwise
---@return GHReviewThread[]
function M.get_effective_threads()
  if state.active_commit then
    local commit_paths = {}
    for _, f in ipairs(state.commit_files) do
      commit_paths[f.path] = true
    end

    -- Build set of valid originalCommit OIDs: the selected commit and all
    -- commits after it in the PR. A comment placed when HEAD was commit N
    -- could be about any file changed in commits 1..N.
    local valid_oids = {}
    local found = false
    for _, c in ipairs(state.commits) do
      if c.oid == state.active_commit.oid then
        found = true
      end
      if found then
        valid_oids[c.oid] = true
      end
    end

    local result = {}
    for _, thread in ipairs(state.threads) do
      if not thread.is_outdated and commit_paths[thread.path] then
        if not thread.commit_oid or valid_oids[thread.commit_oid] then
          table.insert(result, thread)
        end
      end
    end
    return result
  end
  return M.get_threads()
end

--- Get the effective threads for a specific file path
---@param path string
---@return GHReviewThread[]
function M.get_effective_threads_for_file(path)
  local threads = M.get_effective_threads()
  local result = {}
  for _, thread in ipairs(threads) do
    if thread.path == path then
      table.insert(result, thread)
    end
  end
  return result
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
  state.commits = {}
  state.active_commit = nil
  state.commit_files = {}
end

return M
