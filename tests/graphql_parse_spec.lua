---@module 'luassert'

local graphql = require("gh-review.graphql")

--- Build a minimal GraphQL response for parse_threads
---@param thread_nodes table[] Raw thread node data
---@return table GraphQL response data shape
local function make_response(thread_nodes)
  return {
    repository = {
      pullRequest = {
        reviewThreads = {
          nodes = thread_nodes,
        },
      },
    },
  }
end

--- Build a single thread node with sensible defaults
---@param overrides? table
---@return table
local function make_thread_node(overrides)
  overrides = overrides or {}
  return {
    id = overrides.id or "PRRT_thread1",
    isResolved = overrides.isResolved ~= nil and overrides.isResolved or false,
    isOutdated = overrides.isOutdated ~= nil and overrides.isOutdated or false,
    path = overrides.path or "src/main.lua",
    line = overrides.line ~= nil and overrides.line or 10,
    startLine = overrides.startLine,
    diffSide = overrides.diffSide or "RIGHT",
    comments = overrides.comments or {
      nodes = {
        {
          id = "PRRC_comment1",
          author = { login = "alice" },
          body = "Please fix this",
          createdAt = "2025-01-01T00:00:00Z",
          url = "https://github.com/test/repo/pull/1#comment-1",
          commit = overrides.commit or { oid = "abc1234567890" },
        },
      },
    },
  }
end

describe("graphql parse_threads", function()
  describe("vim.NIL handling", function()
    -- vim.json.decode turns JSON null into vim.NIL, which is truthy userdata.
    -- The parser must use type() checks, not truthiness, to handle this.

    it("converts vim.NIL line to nil", function()
      local node = make_thread_node({ line = vim.NIL })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.is_nil(threads[1].line)
    end)

    it("converts vim.NIL startLine to nil", function()
      local node = make_thread_node({ startLine = vim.NIL })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.is_nil(threads[1].start_line)
    end)

    it("converts vim.NIL isResolved to false", function()
      local node = make_thread_node({ isResolved = vim.NIL })
      local threads = graphql._parse_threads(make_response({ node }))
      -- vim.NIL == true is false, so `node.isResolved == true` correctly returns false
      assert.is_false(threads[1].is_resolved)
    end)

    it("converts vim.NIL isOutdated to false", function()
      local node = make_thread_node({ isOutdated = vim.NIL })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.is_false(threads[1].is_outdated)
    end)

    it("handles vim.NIL line without crashing downstream consumers", function()
      -- This is the key regression: vim.NIL is truthy, so `line or 1` doesn't
      -- fall through, and passing vim.NIL to math.max() causes a crash.
      local node = make_thread_node({ line = vim.NIL })
      local threads = graphql._parse_threads(make_response({ node }))
      local line = threads[1].line
      -- Should be safe to use in arithmetic: nil or 1 = 1
      local safe_line = line or 1
      assert.are.equal(1, safe_line)
    end)
  end)

  describe("commit_oid extraction", function()
    it("extracts commit oid from first comment", function()
      local node = make_thread_node({
        commit = { oid = "def4567890abc" },
      })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.are.equal("def4567890abc", threads[1].commit_oid)
    end)

    it("handles missing commit field", function()
      local node = make_thread_node()
      -- Override comments to have no commit
      node.comments = {
        nodes = {
          {
            id = "PRRC_1",
            author = { login = "alice" },
            body = "Comment",
            createdAt = "2025-01-01T00:00:00Z",
            url = "https://example.com",
            commit = nil,
          },
        },
      }
      local threads = graphql._parse_threads(make_response({ node }))
      assert.is_nil(threads[1].commit_oid)
    end)

    it("handles vim.NIL commit field without crashing", function()
      local node = make_thread_node()
      node.comments = {
        nodes = {
          {
            id = "PRRC_1",
            author = { login = "alice" },
            body = "Comment",
            createdAt = "2025-01-01T00:00:00Z",
            url = "https://example.com",
            commit = vim.NIL,
          },
        },
      }
      -- vim.NIL is truthy userdata; naive `x and x.oid` would crash.
      -- The parser must use type() check to guard against this.
      local threads = graphql._parse_threads(make_response({ node }))
      assert.is_nil(threads[1].commit_oid)
    end)
  end)

  describe("basic parsing", function()
    it("parses a standard thread correctly", function()
      local node = make_thread_node({
        id = "PRRT_abc",
        path = "lib/util.lua",
        line = 42,
        diffSide = "LEFT",
        isResolved = true,
        isOutdated = false,
      })
      local threads = graphql._parse_threads(make_response({ node }))

      assert.are.equal(1, #threads)
      local t = threads[1]
      assert.are.equal("PRRT_abc", t.id)
      assert.are.equal("lib/util.lua", t.path)
      assert.are.equal(42, t.line)
      assert.are.equal("LEFT", t.side)
      assert.is_true(t.is_resolved)
      assert.is_false(t.is_outdated)
    end)

    it("defaults diffSide to RIGHT when nil", function()
      local node = make_thread_node({ diffSide = nil })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.are.equal("RIGHT", threads[1].side)
    end)

    it("handles ghost author (nil author)", function()
      local node = make_thread_node()
      node.comments = {
        nodes = {
          {
            id = "PRRC_1",
            author = nil,
            body = "Deleted user comment",
            createdAt = "2025-01-01T00:00:00Z",
            url = "https://example.com",
            commit = { oid = "abc123" },
          },
        },
      }
      local threads = graphql._parse_threads(make_response({ node }))
      assert.are.equal("ghost", threads[1].comments[1].author)
    end)

    it("parses multiple threads", function()
      local nodes = {
        make_thread_node({ id = "t1", path = "a.lua", line = 1 }),
        make_thread_node({ id = "t2", path = "b.lua", line = 5 }),
        make_thread_node({ id = "t3", path = "a.lua", line = 10 }),
      }
      local threads = graphql._parse_threads(make_response(nodes))
      assert.are.equal(3, #threads)
      assert.are.equal("t1", threads[1].id)
      assert.are.equal("t2", threads[2].id)
      assert.are.equal("t3", threads[3].id)
    end)

    it("preserves numeric line and start_line", function()
      local node = make_thread_node({ line = 15, startLine = 12 })
      local threads = graphql._parse_threads(make_response({ node }))
      assert.are.equal(15, threads[1].line)
      assert.are.equal(12, threads[1].start_line)
    end)
  end)
end)
