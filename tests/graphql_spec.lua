---@module 'luassert'

local config = require("gh-review.config")

describe("graphql", function()
  local graphql, gh

  before_each(function()
    config.setup()
    package.loaded["gh-review.gh"] = nil
    package.loaded["gh-review.graphql"] = nil
    gh = require("gh-review.gh")
    graphql = require("gh-review.graphql")
  end)

  --- Build a minimal GraphQL response for review threads
  local function make_thread_response(nodes, has_next_page, end_cursor)
    return {
      repository = {
        pullRequest = {
          reviewThreads = {
            pageInfo = {
              hasNextPage = has_next_page or false,
              endCursor = end_cursor,
            },
            nodes = nodes or {},
          },
        },
      },
    }
  end

  --- Build a single thread node for responses
  local function make_thread_node(overrides)
    return vim.tbl_deep_extend("force", {
      id = "RT_1",
      path = "src/file.lua",
      line = 10,
      startLine = nil,
      diffSide = "RIGHT",
      isResolved = false,
      isOutdated = false,
      comments = {
        nodes = {
          {
            id = "C_1",
            author = { login = "reviewer" },
            body = "Fix this",
            createdAt = "2024-01-15T10:00:00Z",
            url = "https://example.com/c/1",
            commit = { oid = "abc123def456" },
          },
        },
      },
    }, overrides or {})
  end

  describe("_parse_threads", function()
    it("parses a basic thread", function()
      local data = make_thread_response({ make_thread_node() })

      local threads = graphql._parse_threads(data)
      assert.are.equal(1, #threads)
      assert.are.equal("RT_1", threads[1].id)
      assert.are.equal("src/file.lua", threads[1].path)
      assert.are.equal(10, threads[1].line)
      assert.is_nil(threads[1].start_line)
      assert.are.equal("RIGHT", threads[1].side)
      assert.is_false(threads[1].is_resolved)
      assert.is_false(threads[1].is_outdated)
      assert.are.equal("abc123def456", threads[1].commit_oid)
      assert.are.equal(1, #threads[1].comments)
      assert.are.equal("C_1", threads[1].comments[1].id)
      assert.are.equal("reviewer", threads[1].comments[1].author)
      assert.are.equal("Fix this", threads[1].comments[1].body)
      assert.are.equal("2024-01-15T10:00:00Z", threads[1].comments[1].created_at)
    end)

    it("handles resolved and outdated threads", function()
      local data = make_thread_response({
        make_thread_node({ id = "RT_2", isResolved = true, isOutdated = true }),
      })

      local threads = graphql._parse_threads(data)
      assert.is_true(threads[1].is_resolved)
      assert.is_true(threads[1].is_outdated)
    end)

    it("handles LEFT side", function()
      local data = make_thread_response({
        make_thread_node({ diffSide = "LEFT" }),
      })

      local threads = graphql._parse_threads(data)
      assert.are.equal("LEFT", threads[1].side)
    end)

    it("defaults side to RIGHT when nil", function()
      local data = make_thread_response({
        make_thread_node({ diffSide = nil }),
      })

      local threads = graphql._parse_threads(data)
      assert.are.equal("RIGHT", threads[1].side)
    end)

    it("handles multi-line comment (startLine)", function()
      local data = make_thread_response({
        make_thread_node({ startLine = 5, line = 10 }),
      })

      local threads = graphql._parse_threads(data)
      assert.are.equal(5, threads[1].start_line)
      assert.are.equal(10, threads[1].line)
    end)

    it("handles nil line (file-level comment)", function()
      local node = make_thread_node()
      node.line = nil
      local data = make_thread_response({ node })

      local threads = graphql._parse_threads(data)
      assert.is_nil(threads[1].line)
    end)

    it("handles ghost author (nil author)", function()
      local node = make_thread_node()
      node.comments.nodes[1].author = nil
      local data = make_thread_response({ node })

      local threads = graphql._parse_threads(data)
      assert.are.equal("ghost", threads[1].comments[1].author)
    end)

    it("handles missing commit on first comment", function()
      local node = make_thread_node()
      node.comments.nodes[1].commit = nil
      local data = make_thread_response({ node })

      local threads = graphql._parse_threads(data)
      assert.is_nil(threads[1].commit_oid)
    end)

    it("handles multiple comments in a thread", function()
      local node = make_thread_node()
      table.insert(node.comments.nodes, {
        id = "C_2",
        author = { login = "author2" },
        body = "Reply body",
        createdAt = "2024-01-16T10:00:00Z",
        url = "https://example.com/c/2",
        commit = { oid = "def456" },
      })
      local data = make_thread_response({ node })

      local threads = graphql._parse_threads(data)
      assert.are.equal(2, #threads[1].comments)
      assert.are.equal("author2", threads[1].comments[2].author)
    end)

    it("parses multiple threads", function()
      local data = make_thread_response({
        make_thread_node({ id = "RT_1" }),
        make_thread_node({ id = "RT_2", path = "src/other.lua", line = 20 }),
      })

      local threads = graphql._parse_threads(data)
      assert.are.equal(2, #threads)
      assert.are.equal("RT_1", threads[1].id)
      assert.are.equal("RT_2", threads[2].id)
    end)

    it("handles empty nodes list", function()
      local data = make_thread_response({})
      local threads = graphql._parse_threads(data)
      assert.are.same({}, threads)
    end)
  end)

  describe("fetch_threads", function()
    it("fetches single page of threads", function()
      local node = make_thread_node()
      gh.graphql = function(query, vars, cb)
        assert.are.equal("testowner", vars.owner)
        assert.are.equal("testrepo", vars.repo)
        assert.are.equal(42, vars.number)
        cb(nil, make_thread_response({ node }))
      end

      local result_threads
      graphql.fetch_threads("testowner", "testrepo", 42, function(err, threads)
        assert.is_nil(err)
        result_threads = threads
      end)

      assert.are.equal(1, #result_threads)
      assert.are.equal("RT_1", result_threads[1].id)
    end)

    it("handles pagination across multiple pages", function()
      local call_count = 0
      gh.graphql = function(query, vars, cb)
        call_count = call_count + 1
        if call_count == 1 then
          assert.is_nil(vars.cursor)
          cb(nil, make_thread_response(
            { make_thread_node({ id = "RT_1" }) },
            true, "cursor_1"
          ))
        elseif call_count == 2 then
          assert.are.equal("cursor_1", vars.cursor)
          cb(nil, make_thread_response(
            { make_thread_node({ id = "RT_2" }) },
            false
          ))
        end
      end

      local result_threads
      graphql.fetch_threads("owner", "repo", 1, function(err, threads)
        assert.is_nil(err)
        result_threads = threads
      end)

      assert.are.equal(2, call_count)
      assert.are.equal(2, #result_threads)
      assert.are.equal("RT_1", result_threads[1].id)
      assert.are.equal("RT_2", result_threads[2].id)
    end)

    it("propagates error from gh.graphql", function()
      gh.graphql = function(_, _, cb)
        cb("network error", nil)
      end

      local result_err
      graphql.fetch_threads("o", "r", 1, function(err, _)
        result_err = err
      end)

      assert.are.equal("network error", result_err)
    end)
  end)

  describe("reply_to_thread", function()
    it("calls gh.graphql with correct variables", function()
      local captured_vars
      gh.graphql = function(query, vars, cb)
        captured_vars = vars
        cb(nil, {})
      end

      local result_err
      graphql.reply_to_thread("THREAD_ID", "my reply", function(err)
        result_err = err
      end)

      assert.is_nil(result_err)
      assert.is_nil(captured_vars.prId)
      assert.are.equal("THREAD_ID", captured_vars.threadId)
      assert.are.equal("my reply", captured_vars.body)
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("mutation failed", nil)
      end

      local result_err
      graphql.reply_to_thread("T_ID", "body", function(err)
        result_err = err
      end)

      assert.are.equal("mutation failed", result_err)
    end)
  end)

  describe("create_thread", function()
    it("calls gh.graphql with correct variables", function()
      local captured_vars
      gh.graphql = function(query, vars, cb)
        captured_vars = vars
        cb(nil, {})
      end

      graphql.create_thread("PR_ID", "src/file.lua", 42, "RIGHT", "new comment", function(err)
        assert.is_nil(err)
      end)

      assert.are.equal("PR_ID", captured_vars.prId)
      assert.are.equal("src/file.lua", captured_vars.path)
      assert.are.equal(42, captured_vars.line)
      assert.are.equal("RIGHT", captured_vars.side)
      assert.are.equal("new comment", captured_vars.body)
    end)
  end)

  describe("resolve_thread", function()
    it("calls gh.graphql with thread ID", function()
      local captured_vars
      gh.graphql = function(query, vars, cb)
        captured_vars = vars
        cb(nil, {})
      end

      graphql.resolve_thread("THREAD_ID", function(err)
        assert.is_nil(err)
      end)

      assert.are.equal("THREAD_ID", captured_vars.threadId)
    end)
  end)

  describe("unresolve_thread", function()
    it("calls gh.graphql with thread ID", function()
      local captured_vars
      gh.graphql = function(query, vars, cb)
        captured_vars = vars
        cb(nil, {})
      end

      graphql.unresolve_thread("THREAD_ID", function(err)
        assert.is_nil(err)
      end)

      assert.are.equal("THREAD_ID", captured_vars.threadId)
    end)
  end)

  describe("fetch_pending_review", function()
    --- Wrap pending review nodes in the response shape GitHub returns.
    local function make_response(nodes)
      return {
        repository = {
          pullRequest = {
            reviews = { nodes = nodes or {} },
          },
        },
      }
    end

    it("returns the pending review with its comments", function()
      local captured_vars
      gh.graphql = function(_, vars, cb)
        captured_vars = vars
        cb(nil, make_response({
          {
            id = "PRR_1",
            url = "https://github.com/o/r/pull/1#pullrequestreview-1",
            body = "summary so far",
            comments = {
              totalCount = 2,
              nodes = {
                { id = "C1", path = "a.lua", line = 5, startLine = 3, body = "nit", outdated = false },
                { id = "C2", path = "b.lua", line = 9, body = "question", outdated = true },
              },
            },
          },
        }))
      end

      local result
      graphql.fetch_pending_review("owner", "repo", 12, function(err, review)
        assert.is_nil(err)
        result = review
      end)

      assert.are.equal("owner", captured_vars.owner)
      assert.are.equal(12, captured_vars.number)
      assert.are.equal("PRR_1", result.id)
      assert.are.equal("summary so far", result.body)
      assert.are.equal(2, result.total_count)
      assert.are.equal(2, #result.comments)
      assert.are.equal("a.lua", result.comments[1].path)
      assert.are.equal(5, result.comments[1].line)
      assert.are.equal(3, result.comments[1].start_line)
      assert.is_false(result.comments[1].is_outdated)
      assert.is_true(result.comments[2].is_outdated)
      assert.is_nil(result.comments[2].start_line)
    end)

    it("returns nil when nothing is pending", function()
      gh.graphql = function(_, _, cb)
        cb(nil, make_response({}))
      end

      local called, result = false, "unset"
      graphql.fetch_pending_review("o", "r", 1, function(err, review)
        assert.is_nil(err)
        called = true
        result = review
      end)

      assert.is_true(called)
      assert.is_nil(result)
    end)

    it("falls back to the original line for outdated comments", function()
      gh.graphql = function(_, _, cb)
        cb(nil, make_response({
          {
            id = "PRR_2",
            comments = {
              totalCount = 1,
              nodes = {
                {
                  id = "C1",
                  path = "a.lua",
                  -- GraphQL nulls decode to vim.NIL, which is truthy in Lua
                  line = vim.NIL,
                  originalLine = 40,
                  startLine = vim.NIL,
                  originalStartLine = 38,
                  body = "stale",
                  outdated = true,
                },
              },
            },
          },
        }))
      end

      local result
      graphql.fetch_pending_review("o", "r", 1, function(_, review) result = review end)

      assert.are.equal(40, result.comments[1].line)
      assert.are.equal(38, result.comments[1].start_line)
    end)

    it("reports the true total when more than a page is pending", function()
      gh.graphql = function(_, _, cb)
        cb(nil, make_response({
          { id = "PRR_3", comments = { totalCount = 130, nodes = { { id = "C1", path = "a", line = 1, body = "x" } } } },
        }))
      end

      local result
      graphql.fetch_pending_review("o", "r", 1, function(_, review) result = review end)

      assert.are.equal(130, result.total_count)
      assert.are.equal(1, #result.comments)
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("bad credentials", nil)
      end

      local result_err
      graphql.fetch_pending_review("o", "r", 1, function(err, _) result_err = err end)

      assert.are.equal("bad credentials", result_err)
    end)
  end)

  describe("submit_review", function()
    it("sends the review ID, event and body", function()
      local captured_query, captured_vars
      gh.graphql = function(query, vars, cb)
        captured_query = query
        captured_vars = vars
        cb(nil, { submitPullRequestReview = { pullRequestReview = { id = "PRR_1", state = "COMMENTED" } } })
      end

      local result
      graphql.submit_review("PRR_1", "COMMENT", "looks good overall", function(err, review)
        assert.is_nil(err)
        result = review
      end)

      assert.are.equal("PRR_1", captured_vars.reviewId)
      assert.are.equal("COMMENT", captured_vars.event)
      assert.are.equal("looks good overall", captured_vars.body)
      assert.is_truthy(captured_query:find("$body: String!", 1, true))
      assert.are.equal("COMMENTED", result.state)
    end)

    it("omits the body entirely when empty", function()
      local captured_query, captured_vars
      gh.graphql = function(query, vars, cb)
        captured_query = query
        captured_vars = vars
        cb(nil, {})
      end

      graphql.submit_review("PRR_1", "APPROVE", "", function() end)

      assert.is_nil(captured_vars.body)
      assert.is_nil(captured_query:find("body", 1, true))
    end)

    it("omits the body when it is nil", function()
      local captured_vars
      gh.graphql = function(_, vars, cb)
        captured_vars = vars
        cb(nil, {})
      end

      graphql.submit_review("PRR_1", "APPROVE", nil, function() end)

      assert.is_nil(captured_vars.body)
      assert.are.equal("APPROVE", captured_vars.event)
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("Can not approve your own pull request", nil)
      end

      local result_err
      graphql.submit_review("PRR_1", "APPROVE", nil, function(err, _) result_err = err end)

      assert.is_truthy(result_err and result_err:find("own pull request", 1, true))
    end)
  end)

  describe("create_review", function()
    it("sends the PR ID, event and body, and submits right away", function()
      local captured_query, captured_vars
      gh.graphql = function(query, vars, cb)
        captured_query = query
        captured_vars = vars
        cb(nil, { addPullRequestReview = { pullRequestReview = { id = "PRR_9", state = "APPROVED" } } })
      end

      local result
      graphql.create_review("PR_1", "APPROVE", "ship it", function(err, review)
        assert.is_nil(err)
        result = review
      end)

      assert.are.equal("PR_1", captured_vars.pullRequestId)
      assert.are.equal("APPROVE", captured_vars.event)
      assert.are.equal("ship it", captured_vars.body)
      assert.is_truthy(captured_query:find("addPullRequestReview", 1, true))
      -- Without an event in the input the mutation would open a pending review
      assert.is_truthy(captured_query:find("event: $event", 1, true))
      assert.are.equal("APPROVED", result.state)
    end)

    it("omits the body entirely when empty", function()
      local captured_query, captured_vars
      gh.graphql = function(query, vars, cb)
        captured_query = query
        captured_vars = vars
        cb(nil, {})
      end

      graphql.create_review("PR_1", "APPROVE", "", function() end)

      assert.is_nil(captured_vars.body)
      assert.is_nil(captured_query:find("body", 1, true))
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("Can not approve your own pull request", nil)
      end

      local result_err
      graphql.create_review("PR_1", "APPROVE", nil, function(err, _) result_err = err end)

      assert.is_truthy(result_err and result_err:find("own pull request", 1, true))
    end)
  end)

  describe("fetch_pr_id", function()
    it("returns PR node ID from response", function()
      gh.graphql = function(query, vars, cb)
        assert.are.equal("owner", vars.owner)
        assert.are.equal("repo", vars.repo)
        assert.are.equal(99, vars.number)
        cb(nil, {
          repository = {
            pullRequest = { id = "PR_NODE_ID_99" },
          },
        })
      end

      local result_id
      graphql.fetch_pr_id("owner", "repo", 99, function(err, id)
        assert.is_nil(err)
        result_id = id
      end)

      assert.are.equal("PR_NODE_ID_99", result_id)
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("not found", nil)
      end

      local result_err
      graphql.fetch_pr_id("o", "r", 1, function(err, _)
        result_err = err
      end)

      assert.are.equal("not found", result_err)
    end)
  end)

  describe("search_stacked_prs", function()
    it("asks for stack metadata only, and drops unstacked PRs", function()
      local sent
      gh.graphql = function(query, vars, cb)
        sent = { query = query, vars = vars }
        cb(nil, { search = { nodes = {
          { number = 1, stack = { number = 3, size = 2 } },
          { number = 2, stack = vim.NIL },
        } } })
      end
      local nodes
      graphql.search_stacked_prs("o", "r", "author:@me", function(_, n) nodes = n end)
      assert.are.equal("repo:o/r is:pr is:open author:@me", sent.vars.q)
      assert.is_truthy(sent.query:find("baseRefOid", 1, true))
      assert.is_nil(sent.query:find("statusCheckRollup", 1, true))
      assert.is_nil(sent.query:find("mergeStateStatus", 1, true))
      assert.are.equal(1, #nodes)
    end)
  end)

  describe("_batches", function()
    it("splits a list into chunks", function()
      assert.are.same({ { 1, 2 }, { 3, 4 }, { 5 } }, graphql._batches({ 1, 2, 3, 4, 5 }, 2))
      assert.are.same({}, graphql._batches({}, 2))
    end)
  end)

  describe("fetch_pr_statuses", function()
    it("fetches batches of aliased PRs and joins them by number", function()
      graphql.STATUS_BATCH = 2
      local queries = {}
      gh.graphql = function(query, vars, cb)
        table.insert(queries, query)
        assert.are.same({ owner = "o", repo = "r" }, vars)
        local repo = {}
        for n in query:gmatch("p(%d+): pullRequest") do
          repo["p" .. n] = { number = tonumber(n), mergeStateStatus = "CLEAN" }
        end
        cb(nil, { repository = repo })
      end
      local statuses
      graphql.fetch_pr_statuses("o", "r", { 4, 7, 9 }, function(err, s)
        assert.is_nil(err)
        statuses = s
      end)
      assert.are.equal(2, #queries)
      assert.is_truthy(queries[1]:find("statusCheckRollup { state }", 1, true))
      assert.are.same({ 4, 7, 9 }, vim.tbl_map(function(n) return statuses[n].number end, { 4, 7, 9 }))
    end)

    it("reports the first error once and handles no PRs", function()
      graphql.STATUS_BATCH = 1
      local calls = 0
      gh.graphql = function(_, _, cb) cb("HTTP 502", nil) end
      graphql.fetch_pr_statuses("o", "r", { 1, 2 }, function(err)
        calls = calls + 1
        assert.are.equal("HTTP 502", err)
      end)
      assert.are.equal(1, calls)
      local empty
      graphql.fetch_pr_statuses("o", "r", {}, function(_, s) empty = s end)
      assert.are.same({}, empty)
    end)
  end)

  describe("fetch_pr_checks", function()
    it("normalises check runs and status contexts", function()
      local vars
      gh.graphql = function(_, v, cb)
        vars = v
        cb(nil, { repository = { pullRequest = {
          headRefOid = "h1",
          statusCheckRollup = { contexts = { nodes = {
            { __typename = "CheckRun", name = "test", status = "COMPLETED", conclusion = "FAILURE",
              detailsUrl = "https://x/1", isRequired = true,
              checkSuite = { workflowRun = { workflow = { name = "CI" } } } },
            { __typename = "CheckRun", name = "lint", status = "IN_PROGRESS", conclusion = vim.NIL,
              detailsUrl = "https://x/2", isRequired = false, checkSuite = { workflowRun = vim.NIL } },
            { __typename = "StatusContext", context = "buildkite", state = "EXPECTED", targetUrl = vim.NIL, isRequired = false },
          } } },
        } } })
      end
      local result
      graphql.fetch_pr_checks("o", "r", 5, function(err, r)
        assert.is_nil(err)
        result = r
      end)
      assert.are.same({ owner = "o", repo = "r", number = 5 }, vars)
      assert.are.equal("h1", result.head_oid)
      assert.are.same({
        { name = "test", workflow = "CI", state = "FAILURE", url = "https://x/1", required = true },
        { name = "lint", state = "PENDING", url = "https://x/2", required = false },
        { name = "buildkite", state = "PENDING", required = false },
      }, result.checks)
    end)

    it("handles a PR without checks", function()
      gh.graphql = function(_, _, cb) cb(nil, { repository = { pullRequest = { headRefOid = "h", statusCheckRollup = vim.NIL } } }) end
      local result
      graphql.fetch_pr_checks("o", "r", 5, function(_, r) result = r end)
      assert.are.same({}, result.checks)
    end)
  end)
end)
