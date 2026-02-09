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
      graphql.reply_to_thread("PR_ID", "THREAD_ID", "my reply", function(err)
        result_err = err
      end)

      assert.is_nil(result_err)
      assert.are.equal("PR_ID", captured_vars.prId)
      assert.are.equal("THREAD_ID", captured_vars.threadId)
      assert.are.equal("my reply", captured_vars.body)
    end)

    it("passes through error", function()
      gh.graphql = function(_, _, cb)
        cb("mutation failed", nil)
      end

      local result_err
      graphql.reply_to_thread("PR_ID", "T_ID", "body", function(err)
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
end)
