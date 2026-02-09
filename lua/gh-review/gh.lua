--- Async gh CLI wrapper using vim.system
local M = {}

local config = require("gh-review.config")

--- Run a gh command asynchronously
---@param args string[] Arguments to pass to gh
---@param callback fun(err: string?, output: string?) Called with result
---@param opts? { cwd?: string }
function M.run(args, callback, opts)
  local cmd = vim.list_extend({ config.get().gh_cmd }, args)
  vim.system(cmd, {
    text = true,
    cwd = opts and opts.cwd or nil,
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

--- Run a gh command synchronously (for health checks etc.)
---@param args string[]
---@param opts? { cwd?: string }
---@return string? output, string? error
function M.run_sync(args, opts)
  local cmd = vim.list_extend({ config.get().gh_cmd }, args)
  local result = vim.system(cmd, {
    text = true,
    cwd = opts and opts.cwd or nil,
  }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ("gh exited with code " .. result.code)
  end
  return result.stdout, nil
end

--- Checkout a PR branch
---@param pr_number number
---@param callback fun(err: string?)
function M.checkout(pr_number, callback)
  M.run({ "pr", "checkout", tostring(pr_number) }, function(err, _)
    callback(err)
  end)
end

--- Get PR metadata as JSON
---@param pr_number number
---@param callback fun(err: string?, data: table?)
function M.pr_view(pr_number, callback)
  local fields = "number,title,author,baseRefName,headRefName,url,reviewDecision,body"
  M.run({
    "pr", "view", tostring(pr_number),
    "--json", fields,
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse PR JSON: " .. tostring(data), nil)
      return
    end
    callback(nil, data)
  end)
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
    M.run({
      "api", "repos/" .. repo .. "/pulls/" .. tostring(pr_number) .. "/files",
      "--paginate",
    }, function(err2, output)
      if err2 then
        callback(err2, nil)
        return
      end
      local ok, data = pcall(vim.json.decode, output)
      if not ok then
        callback("Failed to parse files JSON: " .. tostring(data), nil)
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
  M.run({
    "pr", "view", tostring(pr_number),
    "--json", "comments",
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse comments JSON: " .. tostring(data), nil)
      return
    end
    callback(nil, data.comments or {})
  end)
end

--- Get PR metadata for the current branch (no PR number needed)
---@param callback fun(err: string?, data: table?)
function M.pr_view_current(callback)
  local fields = "number,title,author,baseRefName,headRefName,url,reviewDecision,body"
  M.run({
    "pr", "view",
    "--json", fields,
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse PR JSON: " .. tostring(data), nil)
      return
    end
    callback(nil, data)
  end)
end

--- Get PR commits
---@param pr_number number
---@param callback fun(err: string?, commits: table?)
function M.pr_commits(pr_number, callback)
  M.run({
    "pr", "view", tostring(pr_number),
    "--json", "commits",
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse commits JSON: " .. tostring(data), nil)
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

--- List open PRs for the current repo
---@param callback fun(err: string?, prs: table?)
function M.pr_list(callback)
  local fields = "number,title,author,body,state,headRefName,isDraft,createdAt,reviewDecision"
  M.run({
    "pr", "list",
    "--json", fields,
    "--limit", "50",
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse PR list JSON: " .. tostring(data), nil)
      return
    end
    callback(nil, data)
  end)
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
    table.insert(args, "-F")
    table.insert(args, key .. "=" .. tostring(val))
  end
  table.insert(args, "-f")
  table.insert(args, "query=" .. query)

  M.run(args, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse GraphQL JSON: " .. tostring(data), nil)
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
