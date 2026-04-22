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

--- Compute merge-base between a base ref and HEAD.
--- Tries `origin/<base_ref>` first (matches state after `gh pr checkout`), then falls back to `<base_ref>`.
--- Returns nil if neither resolves — callers should fall back to the branch name.
---@param base_ref string Base branch name, e.g. "main"
---@param cwd string working directory
---@return string? sha Full commit SHA of the merge base, or nil on failure
function M.git_merge_base(base_ref, cwd)
  for _, ref in ipairs({ "origin/" .. base_ref, base_ref }) do
    local result = vim.system({ "git", "merge-base", ref, "HEAD" }, { text = true, cwd = cwd }):wait()
    if result.code == 0 and result.stdout then
      local sha = vim.trim(result.stdout)
      if sha ~= "" then
        return sha
      end
    end
  end
  return nil
end

--- Find the root of a jj repository containing `cwd`, if any.
--- Returns the directory path that holds `.jj/`, or nil if `cwd` is not inside
--- a jj repo. Used to detect colocated jj so we can sync jj state after a git
--- write (e.g. `gh pr checkout`).
---@param cwd string
---@return string?
function M.find_jj_root(cwd)
  local matches = vim.fs.find(".jj", { path = cwd, upward = true, type = "directory", limit = 1 })
  if #matches == 0 then return nil end
  return vim.fs.dirname(matches[1])
end

--- Run `jj git import` asynchronously to sync jj's view of the git refs after
--- a git-level write. Only call this when you know cwd is a jj colocated repo.
---@param cwd string
---@param callback fun(err: string?)
function M.jj_git_import_async(cwd, callback)
  vim.system({ "jj", "git", "import" }, { text = true, cwd = cwd }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(result.stderr and vim.trim(result.stderr) ~= "" and result.stderr or ("jj exited with code " .. result.code))
      else
        callback(nil)
      end
    end)
  end)
end

-- Diff-surface toggles. Each toggle mutates only the specific `diffopt`
-- entries it owns (so toggles compose) and, while any toggle is active, a
-- single wrapper around `vim.diff` injects matching options for mini.diff.

local diff_flags = {
  ignore_whitespace = false,
  linematch_suppressed = false,
}

local saved_vim_diff
local saved_linematch_entry -- e.g. "linematch:40" captured on suppress

-- Any toggle makes changes active?
local function any_flag_active()
  for _, v in pairs(diff_flags) do
    if v then return true end
  end
  return false
end

local function ensure_diff_wrapper()
  if saved_vim_diff then return end
  saved_vim_diff = vim.diff
  vim.diff = function(a, b, opts)
    local merged = vim.tbl_extend("force", opts or {}, {})
    if diff_flags.ignore_whitespace then merged.ignore_whitespace = true end
    if diff_flags.linematch_suppressed then merged.linematch = 0 end
    return saved_vim_diff(a, b, merged)
  end
end

local function maybe_unwrap()
  if any_flag_active() then return end
  if saved_vim_diff then
    vim.diff = saved_vim_diff
    saved_vim_diff = nil
  end
end

local function diffopt_parts()
  return vim.split(vim.o.diffopt, ",", { trimempty = true })
end

local function diffopt_set(parts)
  vim.o.diffopt = table.concat(parts, ",")
end

--- Whether ignore-whitespace is currently active.
---@return boolean
function M.ignore_whitespace_active()
  return diff_flags.ignore_whitespace
end

--- Enable ignore-whitespace across all diff surfaces. Idempotent.
--- - `diffopt` gets `iwhiteall,iblank` appended (affects :diffthis and diffview).
--- - `vim.diff` is wrapped so every caller (notably mini.diff) gets
---   `ignore_whitespace = true` injected into opts.
function M.enable_ignore_whitespace()
  if diff_flags.ignore_whitespace then return end
  local parts = diffopt_parts()
  local seen = {}
  for _, p in ipairs(parts) do seen[p] = true end
  for _, p in ipairs({ "iwhiteall", "iblank" }) do
    if not seen[p] then table.insert(parts, p) end
  end
  diffopt_set(parts)
  diff_flags.ignore_whitespace = true
  ensure_diff_wrapper()
end

--- Disable ignore-whitespace. Only removes the specific entries we added.
function M.disable_ignore_whitespace()
  if not diff_flags.ignore_whitespace then return end
  local kept = vim.tbl_filter(function(p)
    return p ~= "iwhiteall" and p ~= "iblank"
  end, diffopt_parts())
  diffopt_set(kept)
  diff_flags.ignore_whitespace = false
  maybe_unwrap()
end

--- Whether linematch suppression is active.
---@return boolean
function M.linematch_suppressed()
  return diff_flags.linematch_suppressed
end

--- Remove `linematch:N` from diffopt (grouping deletions+additions as blocks)
--- and also inject `linematch = 0` through the vim.diff wrapper so mini.diff
--- follows suit. Idempotent. Remembers the original `linematch:N` entry so
--- `restore_linematch` can put it back verbatim.
function M.suppress_linematch()
  if diff_flags.linematch_suppressed then return end
  local kept = {}
  for _, p in ipairs(diffopt_parts()) do
    if p:match("^linematch:%d+$") then
      saved_linematch_entry = p
    else
      table.insert(kept, p)
    end
  end
  diffopt_set(kept)
  diff_flags.linematch_suppressed = true
  ensure_diff_wrapper()
end

--- Re-add the `linematch:N` entry captured by the last `suppress_linematch`.
--- If the original diffopt had no linematch entry, this is just a toggle-off.
function M.restore_linematch()
  if not diff_flags.linematch_suppressed then return end
  if saved_linematch_entry then
    local parts = diffopt_parts()
    table.insert(parts, saved_linematch_entry)
    diffopt_set(parts)
    saved_linematch_entry = nil
  end
  diff_flags.linematch_suppressed = false
  maybe_unwrap()
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
