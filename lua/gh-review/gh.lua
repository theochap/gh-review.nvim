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

--- Get PR changed files
---@param pr_number number
---@param callback fun(err: string?, files: table?)
function M.pr_files(pr_number, callback)
  M.run({
    "pr", "view", tostring(pr_number),
    "--json", "files",
  }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok then
      callback("Failed to parse files JSON: " .. tostring(data), nil)
      return
    end
    callback(nil, data.files or {})
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
