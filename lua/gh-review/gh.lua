--- Async gh CLI wrapper using vim.system
local M = {}

local config = require("gh-review.config")
local util = require("gh-review.util")
local vcs = require("gh-review.vcs")

--- Run a gh command asynchronously
---@param args string[] Arguments to pass to gh
---@param callback fun(err: string?, output: string?) Called with result
---@param opts? { cwd?: string }
function M.run(args, callback, opts)
  local cmd = vim.list_extend({ config.get().gh_cmd }, args)
  local ghctx = vcs.gh_context()
  vim.system(cmd, {
    text = true,
    cwd = opts and opts.cwd or ghctx.cwd,
    env = ghctx.env,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err = result.stderr or ("gh exited with code " .. result.code)
        callback(err, nil)
      else
        callback(nil, result.stdout)
      end
    end)
  end)
end

--- Run a gh command and JSON-decode the output
---@param args string[] Arguments to pass to gh
---@param callback fun(err: string?, data: table?) Called with decoded JSON
---@param opts? { cwd?: string }
function M.run_json(args, callback, opts)
  M.run(args, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("JSON decode error: " .. tostring(data), nil)
      return
    end
    callback(nil, data)
  end, opts)
end

--- Run a gh command synchronously (for health checks etc.)
---@param args string[]
---@param opts? { cwd?: string }
---@return string? output, string? error
function M.run_sync(args, opts)
  local cmd = vim.list_extend({ config.get().gh_cmd }, args)
  local ghctx = vcs.gh_context()
  local result = vim.system(cmd, {
    text = true,
    cwd = opts and opts.cwd or ghctx.cwd,
    env = ghctx.env,
  }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ("gh exited with code " .. result.code)
  end
  return result.stdout, nil
end

--- Check out a PR the jj way: fetch the head branch and put the working copy on
--- top of it. Used where `git` has no worktree to check anything out into — a
--- secondary jj workspace or a non-colocated jj repo.
---@param pr_number number
---@param callback fun(err: string?)
local function jj_checkout(pr_number, callback)
  M.run_json({ "pr", "view", tostring(pr_number), "--json", "headRefName" }, function(err, data)
    if err then
      callback(err)
      return
    end
    local branch = data and data.headRefName
    if not branch or branch == "" then
      callback("could not determine PR head branch")
      return
    end
    vcs.jj_checkout(branch, callback)
  end)
end

--- Checkout a PR branch.
---
--- In a jj workspace without a git worktree, `gh pr checkout` cannot run at all,
--- so the jj-native equivalent is used instead. In a colocated jj repository
--- `gh pr checkout` works, but is followed by `jj git import` so jj sees the new
--- branch and HEAD movement — otherwise the user's jj state would silently
--- diverge from git until they imported manually.
---@param pr_number number
---@param callback fun(err: string?)
function M.checkout(pr_number, callback)
  if vcs.context().kind == "jj" then
    jj_checkout(pr_number, callback)
    return
  end

  M.run({ "pr", "checkout", tostring(pr_number) }, function(err, _)
    if err then
      callback(err)
      return
    end

    local cwd = vim.fn.getcwd()
    local jj_root = util.find_jj_root(cwd)
    if not jj_root then
      callback(nil)
      return
    end

    util.jj_git_import_async(jj_root, function(import_err)
      if import_err then
        vim.notify("GHReview: jj git import failed: " .. import_err, vim.log.levels.WARN)
      end
      -- Checkout itself succeeded — surface the import failure as a warning
      -- but don't fail the overall operation; review data can still load.
      callback(nil)
    end)
  end)
end

--- Fields requested for PR metadata. `headRefOid` is the commit that inline
--- comments must be anchored to when posting them through the REST API.
local PR_VIEW_FIELDS = "number,title,author,baseRefName,headRefName,headRefOid,url,reviewDecision,body"

--- Get PR metadata as JSON
---@param pr_number number
---@param callback fun(err: string?, data: table?)
function M.pr_view(pr_number, callback)
  M.run_json({ "pr", "view", tostring(pr_number), "--json", PR_VIEW_FIELDS }, callback)
end

--- Get PR changed files (via REST API for status info)
---@param pr_number number
---@param callback fun(err: string?, files: table?)
function M.pr_files(pr_number, callback)
  -- Use REST API because GraphQL PullRequestChangedFile has no status field
  M.repo_name(function(err, repo)
    if err then
      callback(err, nil)
      return
    end
    M.run_json({
      "api", "repos/" .. repo .. "/pulls/" .. tostring(pr_number) .. "/files",
      "--paginate",
    }, function(err2, data)
      if err2 then
        callback(err2, nil)
        return
      end
      -- Map REST API fields to match expected format
      local status_map = { removed = "deleted" }
      local files = {}
      for _, f in ipairs(data) do
        local status = f.status or "modified"
        table.insert(files, {
          path = f.filename,
          status = status_map[status] or status,
          additions = f.additions or 0,
          deletions = f.deletions or 0,
          previousFilename = f.previous_filename,
        })
      end
      callback(nil, files)
    end)
  end)
end

--- Get PR unified diff
---@param pr_number number
---@param callback fun(err: string?, diff: string?)
function M.pr_diff(pr_number, callback)
  M.run({ "pr", "diff", tostring(pr_number) }, function(err, output)
    callback(err, output)
  end)
end

--- Get top-level PR comments (not inline review threads)
---@param pr_number number
---@param callback fun(err: string?, comments: table?)
function M.pr_comments(pr_number, callback)
  M.run_json({
    "pr", "view", tostring(pr_number),
    "--json", "comments",
  }, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, data.comments or {})
  end)
end

--- Get PR metadata for the current branch (no PR number needed).
---
--- `gh pr view` with no argument asks git for the current branch, which fails
--- outright under jj: the working copy is a detached HEAD (or there is no git
--- worktree at all). In that case look the PR up by each jj bookmark reachable
--- from the working copy, nearest first, reporting the bookmarks that were tried
--- if none of them has a PR.
---@param callback fun(err: string?, data: table?)
function M.pr_view_current(callback)
  vcs.pr_branch_candidates_async(function(candidates)
    if #candidates == 0 then
      M.run_json({ "pr", "view", "--json", PR_VIEW_FIELDS }, callback)
      return
    end
    M.pr_view_branch(candidates, callback)
  end)
end

--- Get PR metadata by head branch name, trying each candidate in turn and
--- reporting the first that resolves to a PR.
---@param branches string[] Branch names, most likely first
---@param callback fun(err: string?, data: table?)
function M.pr_view_branch(branches, callback)
  if #branches == 0 then
    callback("no branch to look a PR up by", nil)
    return
  end

  local idx = 0
  local function try_next()
    idx = idx + 1
    local branch = branches[idx]
    if not branch then
      callback("no PR found for " .. table.concat(branches, ", "), nil)
      return
    end
    M.run_json({ "pr", "view", branch, "--json", PR_VIEW_FIELDS }, function(err, data)
      if err or not data then
        try_next()
        return
      end
      callback(nil, data)
    end)
  end
  try_next()
end

--- Get PR commits
---@param pr_number number
---@param callback fun(err: string?, commits: table?)
function M.pr_commits(pr_number, callback)
  M.run_json({
    "pr", "view", tostring(pr_number),
    "--json", "commits",
  }, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, data.commits or {})
  end)
end

--- Add a top-level comment to a PR
---@param pr_number number
---@param body string
---@param callback fun(err: string?)
function M.pr_add_comment(pr_number, body, callback)
  M.run({
    "pr", "comment", tostring(pr_number),
    "--body", body,
  }, function(err, _)
    callback(err)
  end)
end

--- Post an inline comment on a PR diff line that is published immediately.
---
--- The REST endpoint is used rather than GraphQL's `addPullRequestReviewThread`
--- because that mutation always files the thread under a pending review
--- (creating one if the viewer has none), which is exactly what a "direct"
--- comment is meant to avoid.
---@param pr_number number
---@param opts { body: string, commit_id: string, path: string, line: number, start_line?: number, side?: string, repo?: string }
---@param callback fun(err: string?)
function M.pr_add_review_comment(pr_number, opts, callback)
  local function post(repo)
    local side = opts.side or "RIGHT"
    local args = {
      "api", "--method", "POST",
      "repos/" .. repo .. "/pulls/" .. tostring(pr_number) .. "/comments",
      "-f", "body=" .. opts.body,
      "-f", "commit_id=" .. opts.commit_id,
      "-f", "path=" .. opts.path,
      "-f", "side=" .. side,
      "-F", "line=" .. tostring(opts.line),
    }
    -- GitHub rejects start_line == line, so only send a range when there is one.
    if opts.start_line and opts.start_line ~= opts.line then
      vim.list_extend(args, {
        "-F", "start_line=" .. tostring(opts.start_line),
        "-f", "start_side=" .. side,
      })
    end
    M.run(args, function(err, _)
      callback(err)
    end)
  end

  if opts.repo then
    post(opts.repo)
    return
  end
  M.repo_name(function(err, repo)
    if err then
      callback(err)
      return
    end
    post(repo)
  end)
end

--- List open PRs for the current repo
---@param callback fun(err: string?, prs: table?)
function M.pr_list(callback)
  local fields = "number,title,author,body,state,headRefName,isDraft,createdAt,reviewDecision"
  M.run_json({
    "pr", "list",
    "--json", fields,
    "--limit", "50",
  }, callback)
end

--- Get repository owner/name
---@param callback fun(err: string?, repo: string?)
function M.repo_name(callback)
  M.run({
    "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner",
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, vim.trim(output or ""))
  end)
end

--- Run a GraphQL query
---@param query string
---@param variables table
---@param callback fun(err: string?, data: table?)
function M.graphql(query, variables, callback)
  local args = { "api", "graphql" }
  for key, val in pairs(variables) do
    -- `-F` types the value (numbers, booleans, null, @file); `-f` keeps it a
    -- raw string. Strings must go through `-f` or gh turns a numeric-looking
    -- comment body like "42" into an Int and GitHub rejects the mutation.
    table.insert(args, type(val) == "string" and "-f" or "-F")
    table.insert(args, key .. "=" .. tostring(val))
  end
  table.insert(args, "-f")
  table.insert(args, "query=" .. query)

  M.run_json(args, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    if data.errors then
      local msgs = {}
      for _, e in ipairs(data.errors) do
        table.insert(msgs, e.message)
      end
      callback("GraphQL errors: " .. table.concat(msgs, "; "), nil)
      return
    end
    callback(nil, data.data)
  end)
end

return M
