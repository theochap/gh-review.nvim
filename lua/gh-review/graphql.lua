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
              commit { oid }
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
    -- Get commit OID from the first comment (PR HEAD when comment was placed)
    local first_node = node.comments.nodes[1]
    local commit = first_node and type(first_node.commit) == "table" and first_node.commit or nil
    local commit_oid = commit and commit.oid or nil

    table.insert(threads, {
      id = node.id,
      path = node.path,
      line = type(node.line) == "number" and node.line or nil,
      start_line = type(node.startLine) == "number" and node.startLine or nil,
      side = node.diffSide or "RIGHT",
      is_resolved = node.isResolved == true,
      is_outdated = node.isOutdated == true,
      commit_oid = commit_oid,
      comments = comments,
    })
  end
  return threads
end

-- Exposed for testing
M._parse_threads = parse_threads

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
---@param thread_id string Thread node ID
---@param body string Reply body
---@param callback fun(err: string?)
function M.reply_to_thread(thread_id, body, callback)
  local query = [[
    mutation($threadId: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $threadId,
        body: $body
      }) {
        comment { id }
      }
    }
  ]]
  gh.graphql(query, { threadId = thread_id, body = body }, function(err, _)
    callback(err)
  end)
end

--- Create a new review thread. For multi-line threads pass `start_line`
--- (the topmost selected line); GitHub treats the pair as a range comment.
---@param pr_id string PR node ID
---@param path string File path
---@param line number End line of the range (or the single commented line)
---@param side string "LEFT" or "RIGHT"
---@param body string Comment body
---@param callback fun(err: string?)
---@param start_line? number First line of the range; omit/equal-to-line for single-line
function M.create_thread(pr_id, path, line, side, body, callback, start_line)
  local is_multi = type(start_line) == "number" and start_line ~= line
  local query
  local vars = {
    prId = pr_id,
    path = path,
    line = line,
    side = side,
    body = body,
  }
  if is_multi then
    query = [[
      mutation($prId: ID!, $path: String!, $line: Int!, $startLine: Int!, $side: DiffSide!, $body: String!) {
        addPullRequestReviewThread(input: {
          pullRequestId: $prId,
          path: $path,
          line: $line,
          startLine: $startLine,
          startSide: $side,
          side: $side,
          body: $body
        }) {
          thread { id }
        }
      }
    ]]
    vars.startLine = start_line
  else
    query = [[
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
  end
  gh.graphql(query, vars, function(err, _)
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

--- GraphQL nulls decode to `vim.NIL`, which is truthy in Lua.
---@param value any
---@return number?
local function as_number(value)
  return type(value) == "number" and value or nil
end

--- Fetch the viewer's pending (unsubmitted) review for a PR, if there is one.
--- GitHub only exposes the viewer's own pending review, and there can only be
--- one, so the first node is the answer.
---@param owner string
---@param repo string
---@param pr_number number
---@param callback fun(err: string?, review: table?) review is nil when nothing is pending
function M.fetch_pending_review(owner, repo, pr_number, callback)
  local query = [[
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviews(first: 1, states: [PENDING]) {
            nodes {
              id
              url
              body
              comments(first: 100) {
                totalCount
                nodes {
                  id
                  path
                  line
                  originalLine
                  startLine
                  originalStartLine
                  outdated
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
  gh.graphql(query, { owner = owner, repo = repo, number = pr_number }, function(err, data)
    if err then
      callback(err, nil)
      return
    end

    local pr = data and data.repository and data.repository.pullRequest
    local reviews = pr and pr.reviews and pr.reviews.nodes or {}
    local node = reviews[1]
    if not node then
      callback(nil, nil)
      return
    end

    local comments = {}
    for _, c in ipairs(node.comments and node.comments.nodes or {}) do
      table.insert(comments, {
        id = c.id,
        path = c.path,
        -- `line` is null for comments on outdated diffs; the original line is
        -- the best anchor we have in that case.
        line = as_number(c.line) or as_number(c.originalLine),
        start_line = as_number(c.startLine) or as_number(c.originalStartLine),
        is_outdated = c.outdated == true,
        body = c.body or "",
        created_at = c.createdAt,
        url = c.url,
      })
    end

    callback(nil, {
      id = node.id,
      url = node.url,
      body = type(node.body) == "string" and node.body or "",
      total_count = node.comments and node.comments.totalCount or #comments,
      comments = comments,
    })
  end)
end

--- Submit a pending review, publishing all of its comments at once.
---@param review_id string Pending review node ID
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
---@param body? string Optional summary comment
---@param callback fun(err: string?, review: table?)
function M.submit_review(review_id, event, body, callback)
  local vars = { reviewId = review_id, event = event }
  -- Omit the body entirely when empty: GitHub rejects an empty-string body on
  -- an APPROVE, but is happy with no body at all.
  local decl, field = "", ""
  if body and body ~= "" then
    vars.body = body
    decl = ", $body: String!"
    field = ", body: $body"
  end

  local query = string.format([[
    mutation($reviewId: ID!, $event: PullRequestReviewEvent!%s) {
      submitPullRequestReview(input: {
        pullRequestReviewId: $reviewId,
        event: $event%s
      }) {
        pullRequestReview { id state url }
      }
    }
  ]], decl, field)

  gh.graphql(query, vars, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    local result = data and data.submitPullRequestReview and data.submitPullRequestReview.pullRequestReview
    callback(nil, result)
  end)
end

--- Create a PR-level review and publish it in one call, with no inline
--- comments of its own.
---
--- `addPullRequestReview` only submits when it is given an `event`; without one
--- it opens a *pending* review instead. It also fails when the viewer already
--- has a pending review, so callers must submit that one instead (see
--- `M.submit_review`).
---@param pr_id string PR node ID
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
---@param body? string Optional summary comment
---@param callback fun(err: string?, review: table?)
function M.create_review(pr_id, event, body, callback)
  local vars = { pullRequestId = pr_id, event = event }
  -- Same reason as in `M.submit_review`: an empty-string body is rejected on an
  -- APPROVE, no body at all is fine.
  local decl, field = "", ""
  if body and body ~= "" then
    vars.body = body
    decl = ", $body: String!"
    field = ", body: $body"
  end

  local query = string.format([[
    mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!%s) {
      addPullRequestReview(input: {
        pullRequestId: $pullRequestId,
        event: $event%s
      }) {
        pullRequestReview { id state url }
      }
    }
  ]], decl, field)

  gh.graphql(query, vars, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    local result = data and data.addPullRequestReview and data.addPullRequestReview.pullRequestReview
    callback(nil, result)
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

--- Metadata of a native PR stack: cheap fields only. Merge status (checks,
--- review, mergeability) costs ~60 ms per PR on GitHub's side, so it is
--- fetched on its own by `fetch_pr_statuses`, after the pickers are open.
local STACK_FIELDS = [[
  number
  size
  baseRefName
  entries(first: 100) {
    nodes {
      position
      pullRequest {
        number
        title
        url
        state
        isDraft
        author { login }
        headRefName
        headRefOid
        baseRefName
        baseRefOid
      }
    }
  }
]]

--- Search open PRs of a repo that sit in a native stack, with the stack
--- metadata.
---@param owner string
---@param repo string
---@param term string Extra search qualifiers, e.g. "author:@me"
---@param callback fun(err: string?, nodes: { number: number, stack: table }[]?)
function M.search_stacked_prs(owner, repo, term, callback)
  local query = [[
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        nodes {
          ... on PullRequest {
            number
            stack {
]] .. STACK_FIELDS .. [[
            }
          }
        }
      }
    }
  ]]
  local q = vim.trim(string.format("repo:%s/%s is:pr is:open %s", owner, repo, term))
  gh.graphql(query, { q = q }, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    local nodes = {}
    for _, node in ipairs(data.search and data.search.nodes or {}) do
      if type(node.stack) == "table" then table.insert(nodes, node) end
    end
    callback(nil, nodes)
  end)
end

--- Most PRs whose merge status is fetched in one query. GitHub resolves the
--- PRs of one query in turn (~60-200 ms each) and gives up after ~10 s (HTTP
--- 502), but runs separate queries side by side: small batches in parallel
--- are fastest (59 PRs: 4.9 s in batches of 25, 2 s in batches of 5).
M.STATUS_BATCH = 5

--- Split a list into batches of at most `limit` items.
---@generic T
---@param items T[]
---@param limit number
---@return T[][]
function M._batches(items, limit)
  local batches = {}
  for i = 1, #items, limit do
    table.insert(batches, vim.list_slice(items, i, i + limit - 1))
  end
  return batches
end

--- Fetch the merge status of PRs, in parallel batches of aliased fields.
---@param owner string
---@param repo string
---@param numbers number[]
---@param callback fun(err: string?, statuses: table<number, table>?) PullRequest nodes by number
function M.fetch_pr_statuses(owner, repo, numbers, callback)
  local batches = M._batches(numbers, M.STATUS_BATCH)
  if #batches == 0 then
    callback(nil, {})
    return
  end
  local statuses, pending, failed = {}, #batches, false
  for _, batch in ipairs(batches) do
    local fields = {}
    for _, n in ipairs(batch) do
      table.insert(fields, string.format(
        "p%d: pullRequest(number: %d) { number headRefOid baseRefOid mergeable mergeStateStatus reviewDecision statusCheckRollup { state } }",
        n, n
      ))
    end
    local query = string.format([[
      query($owner: String!, $repo: String!) {
        repository(owner: $owner, name: $repo) {
          %s
        }
      }
    ]], table.concat(fields, "\n"))
    gh.graphql(query, { owner = owner, repo = repo }, function(err, data)
      if failed then return end
      if err then
        failed = true
        callback(err, nil)
        return
      end
      for _, n in ipairs(batch) do
        local pr = data.repository and data.repository["p" .. n]
        if type(pr) == "table" then statuses[n] = pr end
      end
      pending = pending - 1
      if pending == 0 then callback(nil, statuses) end
    end)
  end
end

---@class GHReviewCheck
---@field name string Job or status context name
---@field workflow? string Workflow name, for GitHub Actions jobs
---@field state string Normalised: FAILURE, PENDING, SUCCESS, SKIPPED, NEUTRAL, CANCELLED, ...
---@field url? string
---@field required boolean

--- Fetch the checks of a PR's head commit: GitHub Actions jobs and other check
--- runs, plus commit status contexts.
---@param owner string
---@param repo string
---@param pr_number number
---@param callback fun(err: string?, result: { head_oid: string?, checks: GHReviewCheck[] }?)
function M.fetch_pr_checks(owner, repo, pr_number, callback)
  local query = [[
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          headRefOid
          statusCheckRollup {
            contexts(first: 100) {
              nodes {
                __typename
                ... on CheckRun {
                  name
                  status
                  conclusion
                  detailsUrl
                  isRequired(pullRequestNumber: $number)
                  checkSuite { workflowRun { workflow { name } } }
                }
                ... on StatusContext {
                  context
                  state
                  targetUrl
                  isRequired(pullRequestNumber: $number)
                }
              }
            }
          }
        }
      }
    }
  ]]
  gh.graphql(query, { owner = owner, repo = repo, number = pr_number }, function(err, data)
    if err then
      callback(err, nil)
      return
    end
    local pr = data.repository.pullRequest
    local rollup = type(pr.statusCheckRollup) == "table" and pr.statusCheckRollup or nil
    local nodes = rollup and rollup.contexts and rollup.contexts.nodes or {}
    local function str(v) return type(v) == "string" and v or nil end
    local checks = {}
    for _, node in ipairs(nodes) do
      if node.__typename == "CheckRun" then
        local suite = type(node.checkSuite) == "table" and node.checkSuite or {}
        local run = type(suite.workflowRun) == "table" and suite.workflowRun or {}
        local workflow = type(run.workflow) == "table" and run.workflow or {}
        -- A check run only has a conclusion once it is COMPLETED.
        local state = node.status == "COMPLETED" and (str(node.conclusion) or "NEUTRAL") or "PENDING"
        table.insert(checks, {
          name = str(node.name) or "?",
          workflow = str(workflow.name),
          state = state,
          url = str(node.detailsUrl),
          required = node.isRequired == true,
        })
      elseif node.__typename == "StatusContext" then
        local state = str(node.state) or "PENDING"
        if state == "EXPECTED" then state = "PENDING" end
        table.insert(checks, {
          name = str(node.context) or "?",
          state = state,
          url = str(node.targetUrl),
          required = node.isRequired == true,
        })
      end
    end
    callback(nil, { head_oid = str(pr.headRefOid), checks = checks })
  end)
end

---@class GHReviewMergeSettings
---@field methods string[] Allowed merge methods, e.g. { "squash", "merge" }
---@field merge_queue boolean Whether merges go through a merge queue

--- Fetch the stack metadata of a PR, plus the repo's merge settings.
---@param owner string
---@param repo string
---@param pr_number number
---@param callback fun(err: string?, stack: table?, settings: GHReviewMergeSettings?) `stack` is the raw PullRequestStack, nil when the PR is not stacked
function M.fetch_pr_stack(owner, repo, pr_number, callback)
  local query = [[
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        mergeCommitAllowed
        squashMergeAllowed
        rebaseMergeAllowed
        pullRequest(number: $number) {
          isMergeQueueEnabled
          stack {
]] .. STACK_FIELDS .. [[
          }
        }
      }
    }
  ]]
  gh.graphql(query, { owner = owner, repo = repo, number = pr_number }, function(err, data)
    if err then
      callback(err, nil, nil)
      return
    end
    local r = data.repository
    local methods = {}
    if r.squashMergeAllowed then table.insert(methods, "squash") end
    if r.mergeCommitAllowed then table.insert(methods, "merge") end
    if r.rebaseMergeAllowed then table.insert(methods, "rebase") end
    local pr = r.pullRequest
    local stack = type(pr.stack) == "table" and pr.stack or nil
    callback(nil, stack, { methods = methods, merge_queue = pr.isMergeQueueEnabled == true })
  end)
end

return M
