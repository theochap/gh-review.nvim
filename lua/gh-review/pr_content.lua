--- The content of a PR — changed files, unified diff, commits — from the
--- cheapest source that is known to be right:
---
---   1. the cache, keyed by the PR's head and base commit oids;
---   2. the local repository, when both commits are in the local git/jj store
---      (a fetched jj stack has them): `git diff` from the merge base gives
---      the same diff GitHub shows;
---   3. the GitHub API, whose result is then cached.
---
--- `load_jj` is the other way to get it: the local jj version of the PR, with
--- unpushed edits, in place of what GitHub has.
local M = {}

local cache = require("gh-review.cache")
local vcs = require("gh-review.vcs")

---@class GHReviewPRRef
---@field repo string owner/name
---@field number number
---@field head_oid? string
---@field base_oid? string

---@class GHReviewPRContent
---@field files table[] { path, status, additions, deletions, old_path }
---@field diff_text string
---@field commits GHReviewCommit[]
---@field source "cache"|"local"|"network"|"jj"
---@field base_sha? string Merge base the diff starts from (`load_jj` only)

--- Cache key for a PR's content, or nil when the commits are unknown. The base
--- oid is part of it because a force-pushed base (a rebased stack) changes the
--- merge base, and so the diff, without touching the head.
---@param ref GHReviewPRRef
---@return string?
function M.cache_key(ref)
  if not (ref.repo and ref.head_oid and ref.base_oid) then return nil end
  return ref.repo .. "#" .. ref.number .. "@" .. ref.head_oid .. "-" .. ref.base_oid
end

--- Convert `gh.pr_files` output to the state format.
---@param files table[]
---@return table[]
function M.parse_files(files)
  local parsed = {}
  for _, f in ipairs(files or {}) do
    table.insert(parsed, {
      path = f.path,
      status = (f.status or "modified"):lower(),
      additions = f.additions or 0,
      deletions = f.deletions or 0,
      old_path = f.previousFilename,
    })
  end
  return parsed
end

--- Convert `gh.pr_commits` output to the state format.
---@param commits table[]
---@return GHReviewCommit[]
function M.parse_commits(commits)
  local parsed = {}
  for _, c in ipairs(commits or {}) do
    local commit = c.commit or c
    local full_oid = c.oid or commit.oid or ""
    table.insert(parsed, {
      sha = full_oid:sub(1, 7),
      oid = full_oid,
      message = (commit.messageHeadline or commit.message or ""):match("^([^\n]+)") or "",
      author = commit.authors and commit.authors[1] and commit.authors[1].login
        or commit.author and commit.author.login
        or "unknown",
      date = commit.committedDate or commit.authoredDate or "",
    })
  end
  return parsed
end

---@type table<string, string>
local GIT_STATUS = {
  A = "added",
  M = "modified",
  D = "deleted",
  R = "renamed",
  C = "copied",
  T = "changed",
}

--- Parse `git diff --name-status -M -z` and `git diff --numstat -M -z` into the
--- state file format, in name-status order.
---@param name_status string
---@param numstat string
---@return table[]
function M.parse_git_files(name_status, numstat)
  local counts = {}
  local fields = vim.split(numstat, "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local add, del, path = fields[i]:match("^(%S+)\t(%S+)\t(.*)$")
    if not add then
      i = i + 1
    else
      if path == "" then
        -- Renames: "add\tdel\t" then old path, then new path.
        path = fields[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      if path then
        counts[path] = { tonumber(add) or 0, tonumber(del) or 0 }
      end
    end
  end

  local files = {}
  fields = vim.split(name_status, "\0", { plain = true })
  i = 1
  while i <= #fields do
    local code = fields[i]:sub(1, 1)
    local status = GIT_STATUS[code]
    if not status then
      i = i + 1
    else
      local old_path, path
      if code == "R" or code == "C" then
        old_path, path = fields[i + 1], fields[i + 2]
        i = i + 3
      else
        path = fields[i + 1]
        i = i + 2
      end
      local c = counts[path] or { 0, 0 }
      table.insert(files, {
        path = path,
        status = status,
        additions = c[1],
        deletions = c[2],
        old_path = old_path,
      })
    end
  end
  return files
end

--- Parse `git log --format=%H%x1f%s%x1f%an%x1f%cI` output.
---@param log string
---@return GHReviewCommit[]
function M.parse_git_log(log)
  local commits = {}
  for line in log:gmatch("[^\n]+") do
    local oid, subject, author, date = line:match("^(%x+)\31(.-)\31(.-)\31(.*)$")
    if oid then
      table.insert(commits, { sha = oid:sub(1, 7), oid = oid, message = subject, author = author, date = date })
    end
  end
  return commits
end

--- Run git commands in parallel; `callback` gets every stdout, or nil when any
--- of them fails.
---@param cmds string[][] git arguments
---@param callback fun(outputs: string[]?)
local function git_all(cmds, callback)
  local outputs, pending, failed = {}, #cmds, false
  for i, args in ipairs(cmds) do
    vim.system(vcs.git_cmd(args), { text = true }, function(result)
      vim.schedule(function()
        if failed then return end
        if result.code ~= 0 then
          failed = true
          callback(nil)
          return
        end
        outputs[i] = result.stdout or ""
        pending = pending - 1
        if pending == 0 then callback(outputs) end
      end)
    end)
  end
end

--- Content of the range `mb..head` from the local repository: the diff from
--- the merge base `mb`, and the commits of `log_range`.
---@param mb string
---@param head string
---@param log_range string
---@param source "local"|"jj"
---@param callback fun(content: GHReviewPRContent?)
local function compute_range(mb, head, log_range, source, callback)
  local diff_args = { "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "-M" }
  git_all({
    vim.list_extend(vim.deepcopy(diff_args), { "--src-prefix=a/", "--dst-prefix=b/", mb, head }),
    vim.list_extend(vim.deepcopy(diff_args), { "--name-status", "-z", mb, head }),
    vim.list_extend(vim.deepcopy(diff_args), { "--numstat", "-z", mb, head }),
    { "log", "--reverse", "--format=%H%x1f%s%x1f%an%x1f%cI", log_range },
  }, function(res)
    if not res then
      callback(nil)
      return
    end
    callback({
      diff_text = res[1],
      files = M.parse_git_files(res[2], res[3]),
      commits = M.parse_git_log(res[4]),
      source = source,
    })
  end)
end

--- Compute the content from the local repository. Calls back with nil when
--- either commit is missing locally, or git fails.
---@param ref GHReviewPRRef
---@param callback fun(content: GHReviewPRContent?)
function M.compute_local(ref, callback)
  if not (ref.head_oid and ref.base_oid) then
    callback(nil)
    return
  end
  git_all({
    { "cat-file", "-e", ref.head_oid .. "^{commit}" },
    { "cat-file", "-e", ref.base_oid .. "^{commit}" },
    { "merge-base", ref.base_oid, ref.head_oid },
  }, function(out)
    local mb = out and vim.trim(out[3]) or ""
    if mb == "" then
      callback(nil)
      return
    end
    compute_range(mb, ref.head_oid, ref.base_oid .. ".." .. ref.head_oid, "local", callback)
  end)
end

--- The local jj version of a PR: from the merge base with the local base
--- branch to the local tip of the PR, which includes unpushed commits and
--- working-copy edits on top of the head branch (see `vcs.jj_local_pr`).
--- Never cached: the working copy changes without a new commit id to key on.
---@param spec GHReviewLocalPRSpec
---@param callback fun(err: string?, content: GHReviewPRContent?)
function M.load_jj(spec, callback)
  vcs.jj_local_pr(spec, function(err, range)
    if err or not range then
      callback(err or "no local PR range")
      return
    end
    compute_range(range.base, range.head, range.base .. ".." .. range.head, "jj", function(content)
      if not content then
        callback("git could not diff " .. range.base:sub(1, 8) .. ".." .. range.head:sub(1, 8))
        return
      end
      content.base_sha = range.base
      callback(nil, content)
    end)
  end)
end

--- Build a unified diff from the per-file patches of `gh.pr_files`. Returns
--- nil when a changed file has no patch (GitHub omits it for very large
--- diffs), so the caller fetches the full diff instead.
---@param files table[] `gh.pr_files` output
---@return string?
function M.diff_from_patches(files)
  local parts = {}
  for _, f in ipairs(files or {}) do
    local changed = (f.additions or 0) + (f.deletions or 0) > 0
    if f.patch then
      local old = f.previousFilename or f.path
      table.insert(parts, string.format("diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n%s\n", old, f.path, old, f.path, f.patch))
    elseif changed then
      return nil
    end
  end
  return table.concat(parts)
end

--- Fetch the content from GitHub. The file list carries each file's hunks, so
--- the diff comes with it; `gh pr diff` only runs when a patch is missing.
---@param ref GHReviewPRRef
---@param callback fun(errors: string[]?, content: GHReviewPRContent?)
function M.fetch_network(ref, callback)
  local gh = require("gh-review.gh")
  local content = { source = "network" }
  local errors, pending = {}, 2
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    if #errors > 0 then
      callback(errors, nil)
    else
      callback(nil, content)
    end
  end
  gh.pr_files(ref.number, function(err, files)
    if err then
      table.insert(errors, "files: " .. err)
      done()
      return
    end
    content.files = M.parse_files(files)
    content.diff_text = M.diff_from_patches(files)
    if content.diff_text then
      done()
      return
    end
    gh.pr_diff(ref.number, function(diff_err, diff_text)
      if diff_err then table.insert(errors, "diff: " .. diff_err) else content.diff_text = diff_text or "" end
      done()
    end)
  end)
  gh.pr_commits(ref.number, function(err, commits)
    if err then table.insert(errors, "commits: " .. err) else content.commits = M.parse_commits(commits) end
    done()
  end)
end

--- Load a PR's content from the cheapest source. See the module comment.
---@param ref GHReviewPRRef
---@param callback fun(errors: string[]?, content: GHReviewPRContent?)
function M.load(ref, callback)
  local key = M.cache_key(ref)
  local cached = key and cache.get("content", key)
  if type(cached) == "table" and cached.diff_text then
    cached.source = "cache"
    callback(nil, cached)
    return
  end
  M.compute_local(ref, function(local_content)
    if local_content then
      callback(nil, local_content)
      return
    end
    M.fetch_network(ref, function(errors, content)
      if content and key then
        cache.set("content", key, { files = content.files, diff_text = content.diff_text, commits = content.commits })
      end
      callback(errors, content)
    end)
  end)
end

return M
