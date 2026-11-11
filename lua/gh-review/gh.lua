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
--- top of it. When jj already has the PR head, the fetch is skipped.
---@param pr_number number
---@param callback fun(err: string?)
---@param hint? GHReviewCheckoutHint
local function jj_checkout(pr_number, callback, hint)
  local function go(branch)
    vcs.jj_checkout(branch, callback, nil, nil, {
      head_oid = hint and hint.head_oid,
      on_fetch = function()
        vim.notify("GHReview: fetching " .. branch .. "...", vim.log.levels.INFO)
      end,
    })
  end
  if hint and hint.head_ref and hint.head_ref ~= "" then
    go(hint.head_ref)
    return
  end
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
    go(branch)
  end)
end

--- Checkout a PR branch.
---
--- In any jj workspace the jj-native way is used: fetch the head branch and
--- `jj new` on it. A workspace without a git worktree cannot run
--- `gh pr checkout` at all. One that is a git worktree (a colocated main
--- workspace, or a secondary one made by jj ≥ 0.34) can, but `gh pr checkout`
--- moves git HEAD behind jj's back, and fails when the branch is checked out
--- in another worktree. It remains the fallback there for what jj cannot
--- fetch, such as a PR from a fork; `jj git import` then syncs jj.
---@param pr_number number
---@param callback fun(err: string?)
---@param hint? GHReviewCheckoutHint What the caller knows of the PR already
function M.checkout(pr_number, callback, hint)
  local ctx = vcs.context()
  if ctx.kind == "jj" then
    jj_checkout(pr_number, callback, hint)
    return
  end
  if ctx.jj_root then
    jj_checkout(pr_number, function(err)
      if not err then
        callback(nil)
        return
      end
      vim.notify("GHReview: jj checkout failed (" .. vim.trim(err) .. "), trying gh pr checkout", vim.log.levels.WARN)
      M._gh_pr_checkout(pr_number, callback)
    end, hint)
    return
  end
  M._gh_pr_checkout(pr_number, callback)
end

---@class GHReviewCheckoutHint
---@field head_oid? string PR head commit
---@field base_oid? string PR base commit
---@field head_ref? string PR head branch

--- `gh pr checkout`, then `jj git import` in a colocated jj repo.
---@param pr_number number
---@param callback fun(err: string?)
function M._gh_pr_checkout(pr_number, callback)
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
local PR_VIEW_FIELDS = "number,title,author,baseRefName,baseRefOid,headRefName,headRefOid,url,reviewDecision,body"

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
          -- Hunks of this file; GitHub leaves it out for very large diffs.
          patch = type(f.patch) == "string" and f.patch or nil,
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

--- `gh pr list` arguments for the open PRs matching `search`.
---@param fields string
---@param search? string
---@return string[]
local function pr_list_args(fields, search)
  local args = {
    "pr", "list",
    "--json", fields,
    "--limit", "50",
  }
  if search and search ~= "" then
    vim.list_extend(args, { "--search", search })
  end
  return args
end

--- List open PRs for the current repo. `reviewDecision` is left out: it costs
--- GitHub more than every other field together (~2 s for 50 PRs), so the
--- picker loads it afterwards with `pr_review_states`.
---@param callback fun(err: string?, prs: table?)
---@param search? string GitHub search qualifiers, e.g. "author:@me"
function M.pr_list(callback, search)
  local fields = "number,title,author,body,state,headRefName,headRefOid,baseRefName,baseRefOid,isDraft,createdAt"
  M.run_json(pr_list_args(fields, search), callback)
end

---@class GHReviewReviewState
---@field decision? string Overall review decision (APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED)
---@field viewer? string State of your own latest review (APPROVED, CHANGES_REQUESTED, COMMENTED, ...)

--- Review decision and your own latest review of the open PRs matching
--- `search`, newest 50 (the same PRs `pr_list` returns).
---@param callback fun(err: string?, states: table<number, GHReviewReviewState>?) By PR number
---@param search? string
function M.pr_review_states(callback, search)
  M.repo_name(function(repo_err, repo)
    if repo_err then
      callback(repo_err, nil)
      return
    end
    local query = [[
      query($q: String!) {
        search(query: $q, type: ISSUE, first: 50) {
          nodes {
            ... on PullRequest {
              number
              reviewDecision
              viewerLatestReview { state }
            }
          }
        }
      }
    ]]
    local q = vim.trim(string.format("repo:%s is:pr is:open sort:created-desc %s", repo, search or ""))
    M.graphql(query, { q = q }, function(err, data)
      if err then
        callback(err, nil)
        return
      end
      local states = {}
      for _, node in ipairs(data.search and data.search.nodes or {}) do
        if node.number then
          local review = type(node.viewerLatestReview) == "table" and node.viewerLatestReview or {}
          states[node.number] = {
            decision = type(node.reviewDecision) == "string" and node.reviewDecision or nil,
            viewer = type(review.state) == "string" and review.state or nil,
          }
        end
      end
      callback(nil, states)
    end)
  end)
end

--- Native stacks of the open PRs matching `search`, newest 50 (the same PRs
--- `pr_list` returns): the raw `stack` of each stacked PR, by PR number. It
--- asks for the PR number, state and author of each entry only, so it stays
--- cheap enough to run for every PR list. Kept apart from `pr_review_states`,
--- because a host without native stacks fails the whole query.
---@param callback fun(err: string?, stacks: table<number, table>?) Raw PullRequestStack by PR number
---@param search? string
function M.pr_stacks(callback, search)
  M.repo_name(function(repo_err, repo)
    if repo_err then
      callback(repo_err, nil)
      return
    end
    local query = [[
      query($q: String!) {
        search(query: $q, type: ISSUE, first: 50) {
          nodes {
            ... on PullRequest {
              number
              stack {
                number
                size
                baseRefName
                entries(first: 100) {
                  nodes { position pullRequest { number state author { login } } }
                }
              }
            }
          }
        }
      }
    ]]
    local q = vim.trim(string.format("repo:%s is:pr is:open sort:created-desc %s", repo, search or ""))
    M.graphql(query, { q = q }, function(err, data)
      if err then
        callback(err, nil)
        return
      end
      local stacks = {}
      for _, node in ipairs(data.search and data.search.nodes or {}) do
        if node.number and type(node.stack) == "table" then stacks[node.number] = node.stack end
      end
      callback(nil, stacks)
    end)
  end)
end

--- Open PRs by head branch, all in one GraphQL query: each branch is an
--- aliased `pullRequests(headRefName:)` field. Branches without an open PR
--- are absent from the result.
---@param branches string[]
---@param callback fun(err: string?, numbers: table<string, number>?) PR number by branch
function M.prs_by_head(branches, callback)
  if #branches == 0 then
    callback(nil, {})
    return
  end
  M.repo_name(function(repo_err, repo)
    local owner, name = (repo or ""):match("^(.+)/(.+)$")
    if repo_err or not owner then
      callback(repo_err or "invalid repo " .. tostring(repo), nil)
      return
    end
    local decls, fields = { "$owner: String!", "$name: String!" }, {}
    local vars = { owner = owner, name = name }
    for i, branch in ipairs(branches) do
      table.insert(decls, "$h" .. i .. ": String!")
      table.insert(fields, ("b%d: pullRequests(headRefName: $h%d, states: OPEN, first: 1) { nodes { number } }"):format(i, i))
      vars["h" .. i] = branch
    end
    local query = "query(" .. table.concat(decls, ", ") .. ") { repository(owner: $owner, name: $name) { "
      .. table.concat(fields, " ") .. " } }"
    M.graphql(query, vars, function(err, data)
      if err then
        callback(err, nil)
        return
      end
      local repo_data = data and data.repository or {}
      local numbers = {}
      for i, branch in ipairs(branches) do
        local conn = repo_data["b" .. i]
        local node = type(conn) == "table" and conn.nodes and conn.nodes[1]
        if type(node) == "table" and node.number then numbers[branch] = node.number end
      end
      callback(nil, numbers)
    end)
  end)
end

---@type string?
local viewer_login

--- Login of the authenticated user. Remembered after the first answer.
---@param callback fun(err: string?, login: string?)
function M.viewer_login(callback)
  if viewer_login then
    callback(nil, viewer_login)
    return
  end
  M.graphql("query { viewer { login } }", {}, function(err, data)
    local login = not err and data and data.viewer and data.viewer.login or nil
    if type(login) ~= "string" or login == "" then
      callback(err or "no viewer login", nil)
      return
    end
    viewer_login = login
    callback(nil, login)
  end)
end

--- Forget the remembered viewer login (tests, account switches).
function M.forget_viewer_login()
  viewer_login = nil
end

--- REST API version that has the async merge endpoint.
local MERGE_ASYNC_API_VERSION = "X-GitHub-Api-Version: 2026-03-10"

--- Start an async merge of a PR. For a stacked PR this merges (or enqueues)
--- every open PR below it too, in one atomic operation.
---@param repo string owner/name
---@param pr_number number
---@param opts { merge_method?: string, sha?: string }
---@param callback fun(err: string?, result: { status: string, details: table }?)
function M.pr_merge_async(repo, pr_number, opts, callback)
  local args = {
    "api", "--method", "PUT", "-H", MERGE_ASYNC_API_VERSION,
    "repos/" .. repo .. "/pulls/" .. tostring(pr_number) .. "/merge-async",
  }
  if opts.merge_method then
    vim.list_extend(args, { "-f", "merge_method=" .. opts.merge_method })
  end
  if opts.sha then
    vim.list_extend(args, { "-f", "sha=" .. opts.sha })
  end
  M.run_json(args, callback)
end

--- Poll the result of an async merge started with `pr_merge_async`.
---@param repo string owner/name
---@param pr_number number
---@param uuid string
---@param callback fun(err: string?, result: { status: string, details: table }?)
function M.pr_merge_async_status(repo, pr_number, uuid, callback)
  M.run_json({
    "api", "-H", MERGE_ASYNC_API_VERSION,
    "repos/" .. repo .. "/pulls/" .. tostring(pr_number) .. "/merge-async/" .. uuid,
  }, callback)
end

--- Checkout a whole native stack. Under jj, every open branch of the stack is
--- fetched so the stack navigation finds a bookmark for each PR, and the working
--- copy goes on top of the topmost one. Under git, the topmost PR is checked out:
--- its branch holds every PR below it.
---@param top_number number Topmost open PR
---@param branches string[] Head branches of the open PRs, bottom first
---@param callback fun(err: string?)
---@param head_oid? string Head commit of the topmost PR; skips the fetch when jj has it
function M.checkout_stack(top_number, branches, callback, head_oid)
  if vcs.jj_root(vim.fn.getcwd()) and #branches > 0 then
    vcs.jj_checkout(branches[#branches], callback, nil, branches, {
      head_oid = head_oid,
      on_fetch = function()
        vim.notify("GHReview: fetching " .. #branches .. " stack branches...", vim.log.levels.INFO)
      end,
    })
    return
  end
  M.checkout(top_number, callback, { head_oid = head_oid })
end

---@type table<string, string>
local repo_names = {}
---@type table<string, fun(err: string?, repo: string?)[]>
local repo_waiters = {}

--- Get repository owner/name. The answer is remembered per directory (and
--- GH_REPO): `gh repo view` costs ~0.5 s and every PR load needs it first.
--- Calls back at once on a hit; calls made while a lookup runs share it.
---@param callback fun(err: string?, repo: string?)
function M.repo_name(callback)
  local ctx = vcs.gh_context()
  local key = (ctx.cwd or vim.fn.getcwd()) .. "|" .. (ctx.env and ctx.env.GH_REPO or "")
  if repo_names[key] then
    callback(nil, repo_names[key])
    return
  end
  if repo_waiters[key] then
    table.insert(repo_waiters[key], callback)
    return
  end
  repo_waiters[key] = { callback }
  M.run({
    "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner",
  }, function(err, output)
    local name = not err and vim.trim(output or "") or nil
    if name and name ~= "" then repo_names[key] = name end
    local waiters = repo_waiters[key] or {}
    repo_waiters[key] = nil
    for _, cb in ipairs(waiters) do
      if err then cb(err, nil) else cb(nil, name) end
    end
  end)
end

--- Forget remembered repository names (e.g. after the cwd changes).
function M.forget_repo_names()
  repo_names = {}
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
