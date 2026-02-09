---@module 'luassert'

local config = require("gh-review.config")
local state = require("gh-review.state")

--- Helper: create a minimal PR metadata table
local function make_pr(overrides)
  return vim.tbl_deep_extend("force", {
    number = 42,
    title = "Test PR",
    author = { login = "testuser" },
    baseRefName = "main",
    headRefName = "feature-branch",
    url = "https://github.com/org/repo/pull/42",
    body = "PR description body",
    reviewDecision = "APPROVED",
  }, overrides or {})
end

--- Helper: create sample file data from REST API (as returned by gh.pr_files callback)
local function make_files()
  return {
    { path = "src/a.lua", status = "Added", additions = 10, deletions = 0 },
    { path = "src/b.lua", status = "Modified", additions = 5, deletions = 3, previousFilename = "src/old_b.lua" },
  }
end

--- Helper: create sample thread data (as returned by graphql.fetch_threads)
local function make_threads()
  return {
    {
      id = "thread1",
      path = "src/a.lua",
      line = 10,
      side = "RIGHT",
      is_resolved = false,
      is_outdated = false,
      comments = { { id = "c1", author = "reviewer", body = "fix this", created_at = "2024-01-15", url = "https://example.com" } },
    },
  }
end

--- Helper: create sample commits data (as returned by gh.pr_commits)
local function make_commits()
  return {
    {
      oid = "abc1234567890",
      commit = {
        messageHeadline = "first commit",
        authors = { { login = "dev1" } },
        committedDate = "2024-01-15T10:00:00Z",
      },
    },
    {
      oid = "def5678901234",
      commit = {
        messageHeadline = "second commit",
        authors = { { login = "dev2" } },
        committedDate = "2024-01-16T10:00:00Z",
      },
    },
  }
end

--- Helper: create sample PR comments
local function make_pr_comments()
  return {
    {
      author = { login = "commenter" },
      body = "Looks good!",
      createdAt = "2024-01-17T12:00:00Z",
      url = "https://example.com/comment/1",
    },
  }
end

describe("init", function()
  local gh, graphql, diagnostics, init

  before_each(function()
    config.setup()
    state.clear()

    -- Stub diagnostics before requiring init
    package.loaded["gh-review.ui.diagnostics"] = {
      setup = function() end,
      refresh_all = function() end,
      clear_all = function() end,
    }
    diagnostics = package.loaded["gh-review.ui.diagnostics"]

    -- Stub which-key integration
    package.loaded["gh-review.integrations.which_key"] = {
      register = function() end,
    }

    -- Stub diff_review
    package.loaded["gh-review.ui.diff_review"] = {
      get_file_path = function() return nil end,
      close = function() end,
      open = function() end,
      is_diff_active = function() return false end,
      get_work_win = function() return nil end,
    }

    -- Stub files UI
    package.loaded["gh-review.ui.files"] = {
      toggle = function() end,
      show = function() end,
    }

    -- Stub snacks (for close_snacks_picker)
    package.loaded["snacks"] = {
      picker = {
        get = function() return {} end,
      },
    }

    -- Stub trouble
    package.loaded["trouble"] = {
      is_open = function() return false end,
      open = function() end,
      close = function() end,
      focus = function() end,
      refresh = function() end,
    }

    -- Fresh require of gh, graphql, init each time
    package.loaded["gh-review.gh"] = nil
    package.loaded["gh-review.graphql"] = nil
    package.loaded["gh-review.init"] = nil

    gh = require("gh-review.gh")
    graphql = require("gh-review.graphql")
    init = require("gh-review.init")
  end)

  after_each(function()
    state.clear()
    -- Clean up stubs
    package.loaded["gh-review.ui.diagnostics"] = nil
    package.loaded["gh-review.integrations.which_key"] = nil
    package.loaded["gh-review.ui.diff_review"] = nil
    package.loaded["gh-review.ui.files"] = nil
    package.loaded["snacks"] = nil
    package.loaded["trouble"] = nil
  end)

  describe("_load_pr_data", function()
    --- Stub all 5 async data sources for a happy-path load
    local function stub_happy_path()
      gh.pr_view = function(_, cb)
        cb(nil, make_pr())
      end
      gh.repo_name = function(cb)
        cb(nil, "org/repo")
      end
      gh.pr_files = function(_, cb)
        cb(nil, make_files())
      end
      gh.pr_diff = function(_, cb)
        cb(nil, "")
      end
      gh.pr_comments = function(_, cb)
        cb(nil, make_pr_comments())
      end
      gh.pr_commits = function(_, cb)
        cb(nil, make_commits())
      end
      graphql.fetch_threads = function(_, _, _, cb)
        cb(nil, make_threads())
      end
      graphql.fetch_pr_id = function(_, _, _, cb)
        cb(nil, "PR_NODE_ID_123")
      end
    end

    it("populates state on happy path", function()
      stub_happy_path()

      local completed = false
      init._load_pr_data(42, function()
        completed = true
      end)
      vim.wait(200, function() return completed end)

      assert.is_true(completed)

      -- PR metadata
      local pr = state.get_pr()
      assert.is_not_nil(pr)
      assert.are.equal(42, pr.number)
      assert.are.equal("Test PR", pr.title)
      assert.are.equal("testuser", pr.author)
      assert.are.equal("main", pr.base_ref)
      assert.are.equal("feature-branch", pr.head_ref)
      assert.are.equal("org/repo", pr.repository)
      assert.are.equal("PR_NODE_ID_123", pr.node_id)

      -- Files
      local files = state.get_files()
      assert.are.equal(2, #files)
      assert.are.equal("src/a.lua", files[1].path)
      assert.are.equal("added", files[1].status)
      assert.are.equal("src/b.lua", files[2].path)
      assert.are.equal("src/old_b.lua", files[2].old_path)

      -- Threads
      local threads = state.get_threads()
      assert.are.equal(1, #threads)
      assert.are.equal("thread1", threads[1].id)

      -- Commits
      local commits = state.get_commits()
      assert.are.equal(2, #commits)
      assert.are.equal("abc1234", commits[1].sha)
      assert.are.equal("abc1234567890", commits[1].oid)
      assert.are.equal("first commit", commits[1].message)
      assert.are.equal("dev1", commits[1].author)
      assert.are.equal("2024-01-15T10:00:00Z", commits[1].date)

      -- PR comments
      local pr_comments = state.get_pr_comments()
      assert.are.equal(1, #pr_comments)
      assert.are.equal("commenter", pr_comments[1].author)
      assert.are.equal("Looks good!", pr_comments[1].body)
    end)

    it("calls diagnostics.refresh_all on success", function()
      stub_happy_path()

      local refresh_called = false
      diagnostics.refresh_all = function()
        refresh_called = true
      end

      local completed = false
      init._load_pr_data(42, function()
        completed = true
      end)
      vim.wait(200, function() return completed end)

      assert.is_true(refresh_called)
    end)

    it("collects errors from individual operations", function()
      -- All operations fail
      gh.pr_view = function(_, cb) cb("metadata error", nil) end
      gh.pr_files = function(_, cb) cb("files error", nil) end
      gh.pr_diff = function(_, cb) cb("diff error", nil) end
      gh.pr_comments = function(_, cb) cb("comments error", nil) end
      gh.pr_commits = function(_, cb) cb("commits error", nil) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      -- Since all ops fail, callback is NOT called (errors reported instead)
      init._load_pr_data(42)

      -- Wait for all callbacks to fire
      vim.wait(200, function()
        return #notifications > 0
      end)

      vim.notify = orig_notify

      -- Should have error notification
      local found_error = false
      for _, n in ipairs(notifications) do
        if n.msg:find("errors loading PR data") then
          found_error = true
          assert.is_truthy(n.msg:find("metadata"))
          assert.is_truthy(n.msg:find("files"))
          assert.is_truthy(n.msg:find("diff"))
          assert.is_truthy(n.msg:find("comments"))
          assert.is_truthy(n.msg:find("commits"))
        end
      end
      assert.is_true(found_error)
    end)

    it("handles metadata chain: pr_view error short-circuits", function()
      gh.pr_view = function(_, cb) cb("pr_view failed", nil) end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init._load_pr_data(42)
      vim.wait(200, function() return #notifications > 0 end)
      vim.notify = orig_notify

      local found_error = false
      for _, n in ipairs(notifications) do
        if n.msg:find("metadata: pr_view failed") then
          found_error = true
        end
      end
      assert.is_true(found_error)
    end)

    it("handles metadata chain: repo_name error short-circuits", function()
      gh.pr_view = function(_, cb) cb(nil, make_pr()) end
      gh.repo_name = function(cb) cb("repo error", nil) end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init._load_pr_data(42)
      vim.wait(200, function() return #notifications > 0 end)
      vim.notify = orig_notify

      local found_error = false
      for _, n in ipairs(notifications) do
        if n.msg:find("repo: repo error") then
          found_error = true
        end
      end
      assert.is_true(found_error)
    end)

    it("handles metadata chain: invalid repo format", function()
      gh.pr_view = function(_, cb) cb(nil, make_pr()) end
      gh.repo_name = function(cb) cb(nil, "invalidformat") end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init._load_pr_data(42)
      vim.wait(200, function() return #notifications > 0 end)
      vim.notify = orig_notify

      local found_error = false
      for _, n in ipairs(notifications) do
        if n.msg:find("invalid repo format") then
          found_error = true
        end
      end
      assert.is_true(found_error)
    end)

    it("handles empty pr_view response", function()
      gh.pr_view = function(_, cb) cb(nil, nil) end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init._load_pr_data(42)
      vim.wait(200, function() return #notifications > 0 end)
      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("metadata: empty response") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("parses commits with nested commit structure", function()
      stub_happy_path()

      -- Override commits with various field formats
      gh.pr_commits = function(_, cb)
        cb(nil, {
          -- Nested commit with authors array
          {
            oid = "aaa1111222233",
            commit = {
              messageHeadline = "headline msg",
              authors = { { login = "author1" } },
              committedDate = "2024-01-20T00:00:00Z",
            },
          },
          -- Flat commit (oid at top level)
          {
            oid = "bbb4444555566",
            commit = {
              message = "full message\nwith body",
              author = { login = "author2" },
              authoredDate = "2024-01-21T00:00:00Z",
            },
          },
          -- Missing author info
          {
            oid = "ccc7777888899",
            commit = {
              messageHeadline = "no author commit",
            },
          },
        })
      end

      local completed = false
      init._load_pr_data(42, function()
        completed = true
      end)
      vim.wait(200, function() return completed end)

      local commits = state.get_commits()
      assert.are.equal(3, #commits)

      -- First: authors array
      assert.are.equal("aaa1111", commits[1].sha)
      assert.are.equal("aaa1111222233", commits[1].oid)
      assert.are.equal("headline msg", commits[1].message)
      assert.are.equal("author1", commits[1].author)
      assert.are.equal("2024-01-20T00:00:00Z", commits[1].date)

      -- Second: message with newline, author.login fallback
      assert.are.equal("bbb4444", commits[2].sha)
      assert.are.equal("full message", commits[2].message) -- First line only
      assert.are.equal("author2", commits[2].author)
      assert.are.equal("2024-01-21T00:00:00Z", commits[2].date)

      -- Third: no author → "unknown"
      assert.are.equal("unknown", commits[3].author)
    end)

    it("parses PR comments with correct field mapping", function()
      stub_happy_path()

      gh.pr_comments = function(_, cb)
        cb(nil, {
          { author = { login = "reviewer" }, body = "Nice work", createdAt = "2024-02-01T10:00:00Z", url = "https://gh.com/c/1" },
          { body = "No author field", createdAt = "2024-02-02T10:00:00Z" },
        })
      end

      local completed = false
      init._load_pr_data(42, function()
        completed = true
      end)
      vim.wait(200, function() return completed end)

      local comments = state.get_pr_comments()
      assert.are.equal(2, #comments)
      assert.are.equal("reviewer", comments[1].author)
      assert.are.equal("Nice work", comments[1].body)
      assert.are.equal("2024-02-01T10:00:00Z", comments[1].created_at)
      assert.are.equal("https://gh.com/c/1", comments[1].url)

      -- Missing author
      assert.are.equal("unknown", comments[2].author)
    end)

    it("parses files with status lowercased and old_path mapped", function()
      stub_happy_path()

      gh.pr_files = function(_, cb)
        cb(nil, {
          { path = "x.lua", status = "ADDED", additions = 1, deletions = 0 },
          { path = "y.lua", status = "Modified", additions = 2, deletions = 1, previousFilename = "z.lua" },
          { path = "w.lua" }, -- missing status defaults to "modified"
        })
      end

      local completed = false
      init._load_pr_data(42, function()
        completed = true
      end)
      vim.wait(200, function() return completed end)

      local files = state.get_files()
      assert.are.equal(3, #files)
      assert.are.equal("added", files[1].status)
      assert.are.equal("modified", files[2].status)
      assert.are.equal("z.lua", files[2].old_path)
      assert.are.equal("modified", files[3].status)
      assert.are.equal(0, files[3].additions)
      assert.are.equal(0, files[3].deletions)
    end)

    it("handles threads error gracefully", function()
      gh.pr_view = function(_, cb) cb(nil, make_pr()) end
      gh.repo_name = function(cb) cb(nil, "org/repo") end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end
      graphql.fetch_threads = function(_, _, _, cb) cb("threads error", nil) end
      graphql.fetch_pr_id = function(_, _, _, cb) cb(nil, "ID") end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init._load_pr_data(42)
      vim.wait(200, function() return #notifications > 0 end)
      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("threads: threads error") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("handles pr_id error gracefully without crashing", function()
      gh.pr_view = function(_, cb) cb(nil, make_pr()) end
      gh.repo_name = function(cb) cb(nil, "org/repo") end
      gh.pr_files = function(_, cb) cb(nil, {}) end
      gh.pr_diff = function(_, cb) cb(nil, "") end
      gh.pr_comments = function(_, cb) cb(nil, {}) end
      gh.pr_commits = function(_, cb) cb(nil, {}) end
      graphql.fetch_threads = function(_, _, _, cb) cb(nil, {}) end
      graphql.fetch_pr_id = function(_, _, _, cb) cb("id fetch failed", nil) end

      -- Should still complete without crash — pr_id error is collected but
      -- the chain continues through fetch_threads to done()
      local completed = false
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
        if msg:find("errors loading PR data") or msg:find("loaded") then
          completed = true
        end
      end

      init._load_pr_data(42)
      vim.wait(200, function() return completed end)
      vim.notify = orig_notify

      -- The pr_id error should be in the error list
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("pr_id: id fetch failed") then
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)

  describe("_current_rel_path", function()
    it("returns nil and falls back to diff_review for empty buffer name", function()
      -- Create a scratch buffer with no name
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)

      local diff_review = package.loaded["gh-review.ui.diff_review"]
      diff_review.get_file_path = function() return "fallback/path.lua" end

      local result = init._current_rel_path()
      assert.are.equal("fallback/path.lua", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("strips CWD prefix from buffer path", function()
      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/main.lua")
      vim.api.nvim_set_current_buf(buf)

      local result = init._current_rel_path()
      assert.are.equal("src/main.lua", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("extracts path from ghreview://base/ URI", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "ghreview://base/src/file.lua")
      vim.api.nvim_set_current_buf(buf)

      local result = init._current_rel_path()
      assert.are.equal("src/file.lua", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("extracts path from ghreview://commit/SHA/ URI", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "ghreview://commit/abc1234/src/deep/file.lua")
      vim.api.nvim_set_current_buf(buf)

      local result = init._current_rel_path()
      assert.are.equal("src/deep/file.lua", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns path as-is when not under CWD", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "/some/other/path/file.lua")
      vim.api.nvim_set_current_buf(buf)

      local result = init._current_rel_path()
      assert.are.equal("/some/other/path/file.lua", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("select_commit", function()
    local orig_system
    local captured_cmds

    before_each(function()
      -- Set up state as if a PR is active
      state.set_pr({
        number = 42,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "feature",
        url = "https://github.com/org/repo/pull/42",
        body = "",
        review_decision = "",
        repository = "org/repo",
      })
      captured_cmds = {}
    end)

    after_each(function()
      if orig_system then
        vim.system = orig_system
        orig_system = nil
      end
    end)

    it("returns early with notification for nil commit", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init.select_commit(nil)
      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("invalid commit") then found = true end
      end
      assert.is_true(found)
    end)

    it("returns early for commit with empty oid", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init.select_commit({ sha = "abc", oid = "", message = "test", author = "dev" })
      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("invalid commit") then found = true end
      end
      assert.is_true(found)
    end)

    it("parses added/modified/deleted files from name-status", function()
      orig_system = vim.system
      local call_count = 0
      vim.system = function(cmd, opts)
        call_count = call_count + 1
        table.insert(captured_cmds, cmd)
        if call_count == 1 then
          -- name-status
          return {
            wait = function()
              return {
                code = 0,
                stdout = "A\tsrc/new.lua\nM\tsrc/existing.lua\nD\tsrc/removed.lua\n",
                stderr = "",
              }
            end,
          }
        else
          -- numstat
          return {
            wait = function()
              return {
                code = 0,
                stdout = "10\t0\tsrc/new.lua\n5\t3\tsrc/existing.lua\n0\t20\tsrc/removed.lua\n",
                stderr = "",
              }
            end,
          }
        end
      end

      -- Stub _refresh_views
      init._refresh_views = function() end

      init.select_commit({ sha = "abc1234", oid = "abc1234full", message = "test", author = "dev" })

      local files = state.get_commit_files()
      assert.are.equal(3, #files)

      -- Added file
      assert.are.equal("src/new.lua", files[1].path)
      assert.are.equal("added", files[1].status)
      assert.are.equal(10, files[1].additions)
      assert.are.equal(0, files[1].deletions)

      -- Modified file
      assert.are.equal("src/existing.lua", files[2].path)
      assert.are.equal("modified", files[2].status)
      assert.are.equal(5, files[2].additions)
      assert.are.equal(3, files[2].deletions)

      -- Deleted file
      assert.are.equal("src/removed.lua", files[3].path)
      assert.are.equal("deleted", files[3].status)
      assert.are.equal(0, files[3].additions)
      assert.are.equal(20, files[3].deletions)

      -- Verify active commit set
      local active = state.get_active_commit()
      assert.are.equal("abc1234", active.sha)
    end)

    it("parses renamed files with old_path", function()
      orig_system = vim.system
      local call_count = 0
      vim.system = function(cmd, opts)
        call_count = call_count + 1
        if call_count == 1 then
          return {
            wait = function()
              return {
                code = 0,
                stdout = "R100\told/name.lua\tnew/name.lua\n",
                stderr = "",
              }
            end,
          }
        else
          return {
            wait = function()
              return {
                code = 0,
                stdout = "2\t1\tnew/name.lua\n",
                stderr = "",
              }
            end,
          }
        end
      end

      init._refresh_views = function() end

      init.select_commit({ sha = "def5678", oid = "def5678full", message = "rename", author = "dev" })

      local files = state.get_commit_files()
      assert.are.equal(1, #files)
      assert.are.equal("new/name.lua", files[1].path)
      assert.are.equal("old/name.lua", files[1].old_path)
      assert.are.equal("renamed", files[1].status)
      assert.are.equal(2, files[1].additions)
      assert.are.equal(1, files[1].deletions)
    end)

    it("handles git diff-tree failure", function()
      orig_system = vim.system
      vim.system = function(cmd, opts)
        return {
          wait = function()
            return {
              code = 128,
              stdout = "",
              stderr = "fatal: bad object abc",
            }
          end,
        }
      end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      init.select_commit({ sha = "abc", oid = "abc1234", message = "test", author = "dev" })
      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("git diff%-tree failed") then found = true end
      end
      assert.is_true(found)
    end)

    it("merges numstat counts into files", function()
      orig_system = vim.system
      local call_count = 0
      vim.system = function(cmd, opts)
        call_count = call_count + 1
        if call_count == 1 then
          return {
            wait = function()
              return { code = 0, stdout = "M\tfile.lua\n", stderr = "" }
            end,
          }
        else
          return {
            wait = function()
              return { code = 0, stdout = "15\t7\tfile.lua\n", stderr = "" }
            end,
          }
        end
      end

      init._refresh_views = function() end

      init.select_commit({ sha = "aaa", oid = "aaa111", message = "test", author = "dev" })

      local files = state.get_commit_files()
      assert.are.equal(1, #files)
      assert.are.equal(15, files[1].additions)
      assert.are.equal(7, files[1].deletions)
    end)

    it("handles numstat with rename arrow syntax", function()
      orig_system = vim.system
      local call_count2 = 0
      vim.system = function(cmd, opts)
        call_count2 = call_count2 + 1
        if call_count2 == 1 then
          return {
            wait = function()
              return { code = 0, stdout = "R100\told.lua\tnew.lua\n", stderr = "" }
            end,
          }
        else
          return {
            wait = function()
              -- numstat shows rename with => syntax
              return { code = 0, stdout = "3\t1\told.lua => new.lua\n", stderr = "" }
            end,
          }
        end
      end

      init._refresh_views = function() end

      init.select_commit({ sha = "bbb", oid = "bbb222", message = "rename", author = "dev" })

      local files = state.get_commit_files()
      assert.are.equal(1, #files)
      assert.are.equal("new.lua", files[1].path)
      assert.are.equal(3, files[1].additions)
      assert.are.equal(1, files[1].deletions)
    end)
  end)

  describe("checkout", function()
    it("calls gh.checkout then _load_pr_data on success", function()
      local checkout_called = false
      local load_called = false
      gh.checkout = function(pr_number, cb)
        assert.are.equal(42, pr_number)
        checkout_called = true
        cb(nil)
      end
      init._load_pr_data = function(pr_number)
        assert.are.equal(42, pr_number)
        load_called = true
      end

      init.checkout(42)
      vim.wait(100, function() return load_called end)

      assert.is_true(checkout_called)
      assert.is_true(load_called)
    end)

    it("notifies and stops on checkout error", function()
      gh.checkout = function(_, cb)
        cb("branch not found")
      end

      local load_called = false
      init._load_pr_data = function() load_called = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.checkout(99)

      vim.notify = orig_notify
      assert.is_false(load_called)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("checkout failed") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("refresh", function()
    it("calls _load_pr_data when review is active", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local loaded_number
      init._load_pr_data = function(n, cb) loaded_number = n end

      init.refresh()

      assert.are.equal(42, loaded_number)
    end)

    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.refresh()

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("no active review") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("close", function()
    it("clears state and notifies", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      assert.is_true(state.is_active())

      -- Stub diffview
      package.loaded["gh-review.integrations.diffview"] = {
        close = function() end,
      }
      -- Stub minidiff
      package.loaded["gh-review.ui.minidiff"] = {
        detach_all = function() end,
      }

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.close()

      vim.notify = orig_notify
      package.loaded["gh-review.integrations.diffview"] = nil
      package.loaded["gh-review.ui.minidiff"] = nil

      assert.is_false(state.is_active())
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("review session closed") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("clear_commit", function()
    it("clears active commit and refreshes views", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_active_commit({ sha = "abc", oid = "abcfull", message = "test", author = "dev" })
      assert.is_not_nil(state.get_active_commit())

      local refreshed = false
      init._refresh_views = function() refreshed = true end

      init.clear_commit()

      assert.is_nil(state.get_active_commit())
      assert.is_true(refreshed)
    end)

    it("does nothing when no commit is active", function()
      local refreshed = false
      init._refresh_views = function() refreshed = true end

      init.clear_commit()

      assert.is_false(refreshed)
    end)
  end)

  describe("checkout_or_pick", function()
    it("calls checkout directly when number provided", function()
      local checked_out
      gh.checkout = function(n, cb)
        checked_out = n
        cb(nil)
      end
      init._load_pr_data = function() end

      init.checkout_or_pick(42)

      assert.are.equal(42, checked_out)
    end)

    it("opens picker when no number provided", function()
      local picker_shown = false
      package.loaded["gh-review.ui.pr_picker"] = {
        show = function() picker_shown = true end,
      }

      init.checkout_or_pick()

      package.loaded["gh-review.ui.pr_picker"] = nil

      assert.is_true(picker_shown)
    end)
  end)

  describe("guard functions (require_active)", function()
    it("files() notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.files()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("commits_panel() notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      -- Stub commits module
      package.loaded["gh-review.ui.commits"] = { toggle = function() end }
      init.commits_panel()
      package.loaded["gh-review.ui.commits"] = nil

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("description() notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      package.loaded["gh-review.ui.description"] = { show = function() end }
      init.description()
      package.loaded["gh-review.ui.description"] = nil

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("files() calls toggle when active", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local toggle_called = false
      local files_ui = package.loaded["gh-review.ui.files"]
      files_ui.toggle = function() toggle_called = true end

      init.files()

      assert.is_true(toggle_called)
    end)
  end)

  describe("_toggle_resolve", function()
    it("calls resolve_thread for unresolved thread", function()
      local captured_id
      graphql.resolve_thread = function(id, cb)
        captured_id = id
        cb(nil)
      end
      init.refresh = function() end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init._toggle_resolve({ id = "thread_1", is_resolved = false })

      vim.notify = orig_notify

      assert.are.equal("thread_1", captured_id)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("thread resolved") then found = true end
      end
      assert.is_true(found)
    end)

    it("calls unresolve_thread for resolved thread", function()
      local captured_id
      graphql.unresolve_thread = function(id, cb)
        captured_id = id
        cb(nil)
      end
      init.refresh = function() end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init._toggle_resolve({ id = "thread_2", is_resolved = true })

      vim.notify = orig_notify

      assert.are.equal("thread_2", captured_id)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("thread unresolved") then found = true end
      end
      assert.is_true(found)
    end)

    it("handles resolve error", function()
      graphql.resolve_thread = function(_, cb) cb("permission denied") end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init._toggle_resolve({ id = "t1", is_resolved = false })

      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("resolving failed") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("_reply_to_thread", function()
    it("notifies when no PR node_id", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      -- No node_id set

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init._reply_to_thread({ id = "t1", comments = { { body = "test" } } })

      vim.notify = orig_notify

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("PR node ID not available") then found = true end
      end
      assert.is_true(found)
    end)

    it("opens comment input with correct title and context", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
        node_id = "PR_ID_123",
      })

      local captured_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured_opts = opts end,
      }

      init._reply_to_thread({
        id = "thread_1",
        comments = {
          { body = "Please fix this issue", author = "reviewer" },
        },
      })

      package.loaded["gh-review.ui.comment_input"] = nil

      assert.is_not_nil(captured_opts)
      assert.is_truthy(captured_opts.title:find("Reply:"))
      assert.is_truthy(captured_opts.title:find("Please fix this issue"))
      assert.is_not_nil(captured_opts.context_lines)
      assert.is_function(captured_opts.on_submit)
    end)

    it("truncates long preview in title", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
        node_id = "PR_ID_123",
      })

      local captured_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured_opts = opts end,
      }

      local long_body = string.rep("a", 100)
      init._reply_to_thread({
        id = "thread_1",
        comments = { { body = long_body, author = "user" } },
      })

      package.loaded["gh-review.ui.comment_input"] = nil

      assert.is_truthy(captured_opts.title:find("%.%.%.$"))
    end)
  end)

  describe("review_current", function()
    it("warns when review already active", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_current()

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("already active") then found = true end
      end
      assert.is_true(found)
    end)

    it("shows error when no PR for current branch", function()
      gh.pr_view_current = function(cb) cb("no pull requests found", nil) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_current()

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("no PR for current branch") then found = true end
      end
      assert.is_true(found)
    end)

    it("calls _load_pr_data on success", function()
      local loaded_number
      init._load_pr_data = function(n) loaded_number = n end
      gh.pr_view_current = function(cb)
        cb(nil, { number = 77, title = "Test" })
      end

      init.review_current()
      vim.wait(100, function() return loaded_number ~= nil end)

      assert.are.equal(77, loaded_number)
    end)
  end)

  describe("new_thread", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.new_thread()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("notifies when no PR node_id", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.new_thread()

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("PR node ID not available") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("reply", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.reply()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)
  end)

  describe("resolve", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.resolve()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)
  end)

  describe("show_hover", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.show_hover()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)
  end)

  describe("toggle_overlay", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.toggle_overlay()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)
  end)

  describe("open_minidiff", function()
    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.open_minidiff()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)
  end)
end)
