--- GraphQL queries and mutations for PR review threads
local M = {}

local gh = require("gh-review.gh")

--- Fetch all review threads for a PR
M.REVIEW_THREADS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          diffSide
          comments(first: 100) {
            nodes {
              id
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}
]]

--- Parse review threads response into our thread format
---@param data table GraphQL response data
---@return table[] threads
local function parse_threads(data)
  local threads = {}
  local pr = data.repository.pullRequest
  for _, node in ipairs(pr.reviewThreads.nodes) do
    local comments = {}
    for _, c in ipairs(node.comments.nodes) do
      table.insert(comments, {
        id = c.id,
        author = c.author and c.author.login or "ghost",
        body = c.body,
        created_at = c.createdAt,
        url = c.url,
      })
    end
    table.insert(threads, {
      id = node.id,
      path = node.path,
      line = node.line,
      start_line = node.startLine,
      side = node.diffSide or "RIGHT",
      is_resolved = node.isResolved,
      is_outdated = node.isOutdated,
      comments = comments,
    })
  end
  return threads
end

--- Fetch all review threads (handles pagination)
---@param owner string
---@param repo string
---@param pr_number number
---@param callback fun(err: string?, threads: table[]?)
function M.fetch_threads(owner, repo, pr_number, callback)
  local all_threads = {}

  local function fetch_page(cursor)
    local vars = {
      owner = owner,
      repo = repo,
      number = pr_number,
    }
    if cursor then
      vars.cursor = cursor
    end

    gh.graphql(M.REVIEW_THREADS_QUERY, vars, function(err, data)
      if err then
        callback(err, nil)
        return
      end

      local threads = parse_threads(data)
      vim.list_extend(all_threads, threads)

      local page_info = data.repository.pullRequest.reviewThreads.pageInfo
      if page_info.hasNextPage then
        fetch_page(page_info.endCursor)
      else
        callback(nil, all_threads)
      end
    end)
  end

  fetch_page(nil)
end

--- Reply to an existing review thread
---@param pr_id string PR node ID (not number)
---@param thread_id string Thread node ID
---@param body string Reply body
---@param callback fun(err: string?)
function M.reply_to_thread(pr_id, thread_id, body, callback)
  local query = [[
    mutation($prId: ID!, $threadId: ID!, $body: String!) {
      addPullRequestReviewComment(input: {
        pullRequestId: $prId,
        pullRequestReviewThreadId: $threadId,
        body: $body
      }) {
        comment { id }
      }
    }
  ]]
  gh.graphql(query, { prId = pr_id, threadId = thread_id, body = body }, function(err, _)
    callback(err)
  end)
end

--- Create a new review thread
---@param pr_id string PR node ID
---@param path string File path
---@param line number Line number
---@param side string "LEFT" or "RIGHT"
---@param body string Comment body
---@param callback fun(err: string?)
function M.create_thread(pr_id, path, line, side, body, callback)
  local query = [[
    mutation($prId: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!) {
      addPullRequestReviewThread(input: {
        pullRequestId: $prId,
        path: $path,
        line: $line,
        side: $side,
        body: $body
      }) {
        thread { id }
      }
    }
  ]]
  gh.graphql(query, {
    prId = pr_id,
    path = path,
    line = line,
    side = side,
    body = body,
  }, function(err, _)
    callback(err)
  end)
end

--- Resolve a review thread
---@param thread_id string Thread node ID
---@param callback fun(err: string?)
function M.resolve_thread(thread_id, callback)
  local query = [[
    mutation($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) {
        thread { id isResolved }
      }
    }
  ]]
  gh.graphql(query, { threadId = thread_id }, function(err, _)
    callback(err)
  end)
end

--- Unresolve a review thread
---@param thread_id string Thread node ID
---@param callback fun(err: string?)
function M.unresolve_thread(thread_id, callback)
  local query = [[
    mutation($threadId: ID!) {
      unresolveReviewThread(input: { threadId: $threadId }) {
        thread { id isResolved }
      }
    }
  ]]
  gh.graphql(query, { threadId = thread_id }, function(err, _)
    callback(err)
  end)
end

--- Fetch the PR node ID (needed for mutations)
---@param owner string
---@param repo string
---@param pr_number number
---@param callback fun(err: string?, pr_id: string?)
function M.fetch_pr_id(owner, repo, pr_number, callback)
  local query = [[
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          id
        }
      }
    }
  ]]
  gh.graphql(query, { owner = owner, repo = repo, number = pr_number }, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, data.repository.pullRequest.id)
  end)
end

return M
