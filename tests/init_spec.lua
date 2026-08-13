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
  local gh, graphql, diagnostics, init, util
  local orig_git_merge_base

  before_each(function()
    config.setup()
    state.clear()

    -- Stub util.git_merge_base so _load_pr_data doesn't shell out to git during tests
    util = require("gh-review.util")
    orig_git_merge_base = util.git_merge_base
    util.git_merge_base = function() return "merge_base_sha" end

    -- Stub diagnostics before requiring init
    package.loaded["gh-review.ui.diagnostics"] = {
      setup = function() end,
      refresh_all = function() end,
      refresh_buf = function() end,
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

    -- Stub files UI. display_order is pure ordering logic that cross-file
    -- navigation depends on, so keep the real implementation.
    local real_files = require("gh-review.ui.files")
    package.loaded["gh-review.ui.files"] = {
      open_or_close = function() end,
      focus = function() end,
      show = function() end,
      sync_selection = function() end,
      display_order = real_files.display_order,
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
    util.git_merge_base = orig_git_merge_base
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
      assert.are.equal("merge_base_sha", pr.base_sha)
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

    it("asks git for the changes of merge and root commits too", function()
      orig_system = vim.system
      vim.system = function(cmd)
        table.insert(captured_cmds, cmd)
        return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
      end
      init._refresh_views = function() end

      init.select_commit({ sha = "abc1234", oid = "abc1234full", message = "merge", author = "dev" })

      -- Plain `git diff-tree` prints nothing for a merge or a root commit, so
      -- without these the file list of such a commit would come back empty
      for _, cmd in ipairs(captured_cmds) do
        assert.is_truthy(vim.tbl_contains(cmd, "--root"))
        assert.is_truthy(vim.tbl_contains(cmd, "--diff-merges=first-parent"))
      end
      assert.are.equal(2, #captured_cmds)
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

  describe("next_stack_commit / prev_stack_commit", function()
    local vcs = require("gh-review.vcs")
    local orig_vcs = {}

    local function set_pr(head_sha)
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", head_sha = head_sha, url = "", body = "",
        review_decision = "", repository = "o/r",
      })
      state.set_commits({
        { sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" },
        { sha = "bbb2222", oid = "bbb2222full", message = "second", author = "dev" },
      })
    end

    --- Stub the jj graph: `commits` is what jj_adjacent reports back. Change ids
    --- resolve to the revision itself so assertions can stay on the anchor.
    ---@return table captured { rev, direction, resolved }
    local function stub_jj(commits)
      local captured = {}
      vcs.jj_root = function() return "/tmp/ws" end
      vcs.jj_change_id = function(rev, cb)
        captured.resolved = rev
        cb(nil, rev)
      end
      vcs.jj_adjacent = function(rev, direction, cb)
        captured.rev, captured.direction = rev, direction
        cb(nil, commits)
      end
      return captured
    end

    before_each(function()
      orig_vcs.jj_root = vcs.jj_root
      orig_vcs.jj_adjacent = vcs.jj_adjacent
      orig_vcs.jj_change_id = vcs.jj_change_id
      orig_vcs.jj_downstream_bookmarks = vcs.jj_downstream_bookmarks
      orig_vcs.head_rev = vcs.head_rev
    end)

    after_each(function()
      for name, fn in pairs(orig_vcs) do
        vcs[name] = fn
      end
      orig_vcs = {}
    end)

    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1]:find("no active review"))
    end)

    it("warns when the repo is not a jj workspace", function()
      set_pr("bbb2222full")
      vcs.jj_root = function() return nil end
      local spawned = false
      vcs.jj_adjacent = function() spawned = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(spawned)
      assert.is_truthy(notifications[1]:find("jj workspace"))
    end)

    it("filters to the child commit when it belongs to the loaded PR", function()
      set_pr("aaa1111full")
      state.set_active_commit({ sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" })
      local captured = stub_jj({ { commit_id = "bbb2222full", bookmarks = {}, description = "second" } })

      local selected
      init.select_commit = function(commit) selected = commit end
      local loaded = false
      init._load_pr_data = function() loaded = true end

      init.next_stack_commit()

      -- Anchored on the commit under review, walking upwards
      assert.are.equal("aaa1111full", captured.rev)
      assert.are.equal("children", captured.direction)
      assert.are.equal("bbb2222full", selected.oid)
      assert.is_false(loaded)
    end)

    it("walks from the change of a commit that was rewritten locally", function()
      set_pr("bbb2222full")
      state.set_active_commit({ sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" })
      -- The pushed oid is stale; its change id points at the commit that replaced it
      local asked, walked = nil, nil
      vcs.jj_root = function() return "/tmp/ws" end
      vcs.jj_change_id = function(rev, cb)
        asked = rev
        cb(nil, "vtwxtppqqmtknklz")
      end
      vcs.jj_adjacent = function(rev, _, cb)
        walked = rev
        cb(nil, { { commit_id = "bbb2222full", bookmarks = {}, description = "second" } })
      end
      local selected
      init.select_commit = function(commit) selected = commit end

      init.next_stack_commit()

      assert.are.equal("aaa1111full", asked)
      assert.are.equal("vtwxtppqqmtknklz", walked)
      assert.are.equal("bbb2222full", selected.oid)
    end)

    it("warns when the commit is not in the jj workspace at all", function()
      set_pr("bbb2222full")
      vcs.jj_root = function() return "/tmp/ws" end
      vcs.jj_change_id = function(_, cb) cb(nil, nil) end
      local walked = false
      vcs.jj_adjacent = function() walked = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(walked)
      assert.is_truthy(table.concat(notifications, "\n"):find("not in this jj workspace"))
    end)

    it("anchors on the PR head when the review is not commit-scoped", function()
      set_pr("bbb2222full")
      local captured = stub_jj({})
      local orig_notify = vim.notify
      vim.notify = function() end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.are.equal("bbb2222full", captured.rev)
    end)

    it("walks to the parent commit in the other direction", function()
      set_pr("bbb2222full")
      state.set_active_commit({ sha = "bbb2222", oid = "bbb2222full", message = "second", author = "dev" })
      local captured = stub_jj({ { commit_id = "aaa1111full", bookmarks = {}, description = "first" } })
      local selected
      init.select_commit = function(commit) selected = commit end

      init.prev_stack_commit()

      assert.are.equal("parents", captured.direction)
      assert.are.equal("aaa1111full", selected.oid)
    end)

    it("reports when the stack has no neighbour in that direction", function()
      set_pr("bbb2222full")
      stub_jj({})
      local selected = false
      init.select_commit = function() selected = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(selected)
      assert.is_truthy(table.concat(notifications, "\n"):find("no descendant"))
    end)

    it("loads the PR that owns the child commit and filters to it", function()
      set_pr("bbb2222full")
      stub_jj({ { commit_id = "ccc3333full", bookmarks = { "feat/two" }, description = "third" } })
      state.set_active_commit({ sha = "bbb2222", oid = "bbb2222full", message = "second", author = "dev" })

      local bookmark_rev
      vcs.jj_downstream_bookmarks = function(rev, cb)
        bookmark_rev = rev
        cb(nil, { "feat/two" })
      end
      local branches
      gh.pr_view_branch = function(list, cb)
        branches = list
        cb(nil, { number = 43, title = "Second PR" })
      end

      local loaded_number
      init._load_pr_data = function(number, cb)
        loaded_number = number
        -- The new PR's commits replace the old ones before the callback runs
        state.set_commits({ { sha = "ccc3333", oid = "ccc3333full", message = "third", author = "dev" } })
        cb()
      end
      local selected
      init.select_commit = function(commit) selected = commit end

      local orig_notify = vim.notify
      vim.notify = function() end
      init.next_stack_commit()
      vim.notify = orig_notify

      assert.are.equal("ccc3333full", bookmark_rev)
      assert.are.same({ "feat/two" }, branches)
      assert.are.equal(43, loaded_number)
      assert.are.equal("ccc3333full", selected.oid)
      -- The previous PR's commit filter must not leak into the new PR
      assert.is_nil(state.get_active_commit())
    end)

    it("shows the whole PR when the child is not among its commits", function()
      set_pr("bbb2222full")
      stub_jj({ { commit_id = "ccc3333full", bookmarks = {}, description = "third" } })
      vcs.jj_downstream_bookmarks = function(_, cb) cb(nil, { "feat/two" }) end
      gh.pr_view_branch = function(_, cb) cb(nil, { number = 43, title = "Second PR" }) end
      init._load_pr_data = function(_, cb) cb() end
      local selected = false
      init.select_commit = function() selected = true end
      local refreshed = false
      init._refresh_views = function() refreshed = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(selected)
      assert.is_true(refreshed)
      assert.is_truthy(table.concat(notifications, "\n"):find("not part of it"))
    end)

    it("warns when the child commit has no bookmark to identify a PR by", function()
      set_pr("bbb2222full")
      stub_jj({ { commit_id = "ccc3333full", bookmarks = {}, description = "third" } })
      vcs.jj_downstream_bookmarks = function(_, cb) cb(nil, {}) end
      local looked_up = false
      gh.pr_view_branch = function() looked_up = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(looked_up)
      assert.is_truthy(table.concat(notifications, "\n"):find("no bookmark"))
    end)

    it("does not reload the PR already loaded", function()
      set_pr("bbb2222full")
      stub_jj({ { commit_id = "ccc3333full", bookmarks = { "f" }, description = "unpushed" } })
      vcs.jj_downstream_bookmarks = function(_, cb) cb(nil, { "f" }) end
      gh.pr_view_branch = function(_, cb) cb(nil, { number = 42, title = "T" }) end
      local loaded = false
      init._load_pr_data = function() loaded = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_stack_commit()

      vim.notify = orig_notify
      assert.is_false(loaded)
      assert.is_truthy(table.concat(notifications, "\n"):find("unpushed"))
    end)

    it("asks which neighbour to follow when the stack forks", function()
      set_pr("bbb2222full")
      stub_jj({
        { commit_id = "ccc3333full", bookmarks = { "feat/a" }, description = "branch a" },
        { commit_id = "ddd4444full", bookmarks = {}, description = "branch b" },
      })

      local choices, formatted
      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        choices = items
        formatted = opts.format_item(items[1])
        on_choice(items[2])
      end
      state.set_commits({ { sha = "ddd4444", oid = "ddd4444full", message = "branch b", author = "dev" } })
      local selected
      init.select_commit = function(commit) selected = commit end

      init.next_stack_commit()

      vim.ui.select = orig_select
      assert.are.equal(2, #choices)
      assert.is_truthy(formatted:find("feat/a", 1, true))
      assert.are.equal("ddd4444full", selected.oid)
    end)
  end)

  describe("stack_panel", function()
    local vcs = require("gh-review.vcs")
    local orig_vcs = {}
    local shown

    --- Stub the stack picker UI; `closed` decides whether one was already open.
    local function stub_ui(closed)
      shown = nil
      package.loaded["gh-review.ui.stack"] = {
        close = function() return closed == true end,
        show = function(commits, opts) shown = { commits = commits, opts = opts } end,
      }
    end

    before_each(function()
      orig_vcs.jj_root = vcs.jj_root
      orig_vcs.jj_stack = vcs.jj_stack
      orig_vcs.head_rev = vcs.head_rev
      orig_vcs.jj_change_id = vcs.jj_change_id
      orig_vcs.jj_change_ids = vcs.jj_change_ids
      stub_ui(false)
      vcs.jj_root = function() return "/tmp/ws" end
      -- Change ids are derived from the revision so assertions stay readable
      vcs.jj_change_id = function(rev, cb) cb(nil, "change-" .. rev) end
      vcs.jj_change_ids = function(revs, cb)
        local ids = {}
        for _, rev in ipairs(revs) do
          table.insert(ids, "change-" .. rev)
        end
        cb(nil, ids)
      end
    end)

    after_each(function()
      for name, fn in pairs(orig_vcs) do
        vcs[name] = fn
      end
      orig_vcs = {}
      package.loaded["gh-review.ui.stack"] = nil
    end)

    it("closes an open picker instead of reloading the stack", function()
      stub_ui(true)
      local queried = false
      vcs.jj_stack = function() queried = true end

      init.stack_panel()

      assert.is_false(queried)
      assert.is_nil(shown)
    end)

    it("warns when the repo is not a jj workspace", function()
      vcs.jj_root = function() return nil end
      local queried = false
      vcs.jj_stack = function() queried = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.stack_panel()

      vim.notify = orig_notify
      assert.is_false(queried)
      assert.is_truthy(notifications[1]:find("jj workspace"))
    end)

    it("anchors on the commit under review, the PR head and its branch", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m", head_ref = "feat/one",
        head_sha = "bbb2222full", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_active_commit({ sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" })
      local asked
      vcs.jj_stack = function(anchor, cb)
        asked = anchor
        cb(nil, { { commit_id = "aaa1111full", bookmarks = {}, description = "first" } }, false)
      end

      init.stack_panel()

      -- The head branch must be in there: anchoring on the pushed oid alone
      -- misses the descendants once the commit has been rewritten locally
      assert.are.same({ "aaa1111full", "bbb2222full" }, asked.revs)
      assert.are.same({ "feat/one" }, asked.bookmarks)
      assert.are.equal(1, #shown.commits)
      assert.are.equal("aaa1111full", shown.opts.current_oid)
      assert.is_false(shown.opts.truncated)
    end)

    it("hands the picker the changes of the commit under review and of the PR", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m", head_ref = "feat/one",
        head_sha = "bbb2222full", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_commits({
        { sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" },
        { sha = "bbb2222", oid = "bbb2222full", message = "second", author = "dev" },
      })
      state.set_active_commit({ sha = "aaa1111", oid = "aaa1111full", message = "first", author = "dev" })
      local resolved
      vcs.jj_change_ids = function(revs, cb)
        resolved = revs
        cb(nil, { "change-aaa1111full", "change-bbb2222full" })
      end
      vcs.jj_stack = function(_, cb)
        cb(nil, { { commit_id = "zzz", change_id = "change-aaa1111full", bookmarks = {}, description = "first" } }, false)
      end

      init.stack_panel()

      -- Every PR commit is resolved, so a rewritten stack still gets its badges
      assert.are.same({ "aaa1111full", "bbb2222full" }, resolved)
      assert.are.equal("change-aaa1111full", shown.opts.current_change_id)
      assert.are.same(
        { ["change-aaa1111full"] = true, ["change-bbb2222full"] = true },
        shown.opts.pr_change_ids
      )
    end)

    it("still opens the picker when the changes cannot be resolved", function()
      vcs.head_rev = function() return "wwww9999" end
      vcs.jj_change_id = function(_, cb) cb("boom", nil) end
      vcs.jj_change_ids = function(_, cb) cb("boom", nil) end
      vcs.jj_stack = function(_, cb)
        cb(nil, { { commit_id = "wwww9999", change_id = "cccc", bookmarks = {}, description = "wip" } }, false)
      end

      init.stack_panel()

      assert.are.equal(1, #shown.commits)
      assert.is_nil(shown.opts.current_change_id)
      assert.are.same({}, shown.opts.pr_change_ids)
    end)

    it("works without an active review, anchoring on the working copy", function()
      vcs.head_rev = function() return "wwww9999" end
      local asked
      vcs.jj_stack = function(anchor, cb)
        asked = anchor
        cb(nil, { { commit_id = "wwww9999", bookmarks = { "feat/a" }, description = "wip" } }, true)
      end

      init.stack_panel()

      assert.are.same({ "wwww9999" }, asked.revs)
      assert.are.same({}, asked.bookmarks)
      assert.is_true(shown.opts.truncated)
    end)

    it("errors when the current revision cannot be resolved", function()
      vcs.head_rev = function() return nil end
      local queried = false
      vcs.jj_stack = function() queried = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.stack_panel()

      vim.notify = orig_notify
      assert.is_false(queried)
      assert.is_truthy(notifications[1]:find("jj revision"))
    end)

    it("reports an empty stack instead of opening the picker", function()
      vcs.head_rev = function() return "wwww9999" end
      vcs.jj_stack = function(_, cb) cb(nil, {}, false) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.stack_panel()

      vim.notify = orig_notify
      assert.is_nil(shown)
      assert.is_truthy(notifications[1]:find("no commits"))
    end)

    it("surfaces jj failures", function()
      vcs.head_rev = function() return "wwww9999" end
      vcs.jj_stack = function(_, cb) cb("bad revset") end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.stack_panel()

      vim.notify = orig_notify
      assert.is_nil(shown)
      assert.is_truthy(notifications[1]:find("bad revset"))
    end)

    it("routes a selection through the shared stack navigation", function()
      vcs.head_rev = function() return "wwww9999" end
      local picked = { commit_id = "ccc3333full", bookmarks = {}, description = "third" }
      vcs.jj_stack = function(_, cb) cb(nil, { picked }, false) end
      local navigated
      init._goto_stack_commit = function(commit) navigated = commit end

      init.stack_panel()
      shown.opts.on_select(picked)

      assert.are.equal("ccc3333full", navigated.commit_id)
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

    it("files() calls open_or_close when active", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local called = false
      local files_ui = package.loaded["gh-review.ui.files"]
      files_ui.open_or_close = function() called = true end

      init.files()

      assert.is_true(called)
    end)

    it("files_focus() calls focus when active", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })

      local called = false
      local files_ui = package.loaded["gh-review.ui.files"]
      files_ui.focus = function() called = true end

      init.files_focus()

      assert.is_true(called)
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

  describe("new_thread_direct", function()
    --- Active PR with everything a direct comment needs. `head_sha` is passed
    --- explicitly because vim.tbl_extend cannot override a key back to nil.
    ---@param head_sha? string
    local function set_pr(head_sha)
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", head_sha = head_sha, url = "", body = "",
        review_decision = "", repository = "o/r",
      })
    end

    local orig_rel_path

    before_each(function()
      orig_rel_path = init._current_rel_path
      init._current_rel_path = function() return "src/a.lua" end
    end)

    after_each(function()
      init._current_rel_path = orig_rel_path
      package.loaded["gh-review.ui.comment_input"] = nil
    end)

    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.new_thread_direct()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("notifies when the PR head commit is unknown", function()
      set_pr(nil)

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.new_thread_direct(5)

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("head commit not available") then found = true end
      end
      assert.is_true(found)
    end)

    it("posts the comment immediately instead of creating a pending thread", function()
      set_pr("HEADSHA")

      local captured_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured_opts = opts end,
      }

      local rest_args, thread_created = nil, false
      gh.pr_add_review_comment = function(pr_number, opts, cb)
        rest_args = { pr_number = pr_number, opts = opts }
        cb(nil)
      end
      graphql.create_thread = function() thread_created = true end
      init.refresh = function() end

      init.new_thread_direct(12)
      assert.is_truthy(captured_opts.title:find("Direct Comment: src/a.lua:12", 1, true))
      captured_opts.on_submit("looks wrong")

      assert.is_false(thread_created)
      assert.are.equal(42, rest_args.pr_number)
      assert.are.equal("o/r", rest_args.opts.repo)
      assert.are.equal("HEADSHA", rest_args.opts.commit_id)
      assert.are.equal("src/a.lua", rest_args.opts.path)
      assert.are.equal("looks wrong", rest_args.opts.body)
      assert.are.equal(12, rest_args.opts.line)
      assert.are.equal(12, rest_args.opts.start_line)
      assert.are.equal("RIGHT", rest_args.opts.side)
    end)

    it("passes a visual range through as start_line/line", function()
      set_pr("HEADSHA")

      local captured_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured_opts = opts end,
      }
      local rest_opts
      gh.pr_add_review_comment = function(_, opts, cb)
        rest_opts = opts
        cb(nil)
      end
      init.refresh = function() end

      init.new_thread_direct(7, 9)
      assert.is_truthy(captured_opts.title:find("src/a.lua:7-9", 1, true))
      captured_opts.on_submit("range comment")

      assert.are.equal(7, rest_opts.start_line)
      assert.are.equal(9, rest_opts.line)
    end)

    it("reports a failed post and does not refresh", function()
      set_pr("HEADSHA")

      local captured_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured_opts = opts end,
      }
      gh.pr_add_review_comment = function(_, _, cb) cb("line must be part of the diff") end
      local refreshed = false
      init.refresh = function() refreshed = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.new_thread_direct(3)
      captured_opts.on_submit("b")

      vim.notify = orig_notify
      assert.is_false(refreshed)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("failed to post comment") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("pending_review / submit_review", function()
    local function set_pr()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
    end

    local function make_pending()
      return {
        id = "PRR_1",
        total_count = 2,
        comments = {
          { path = "src/a.lua", line = 5, body = "nit" },
          { path = "src/b.lua", line = 8, body = "why?" },
        },
      }
    end

    after_each(function()
      package.loaded["gh-review.ui.review_submit"] = nil
      package.loaded["gh-review.ui.comment_input"] = nil
    end)

    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.pending_review()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("shows the panel with the pending review", function()
      set_pr()
      local captured_owner, captured_repo, captured_number
      graphql.fetch_pending_review = function(owner, repo, number, cb)
        captured_owner, captured_repo, captured_number = owner, repo, number
        cb(nil, make_pending())
      end

      local shown
      package.loaded["gh-review.ui.review_submit"] = {
        show = function(review) shown = review end,
      }

      init.pending_review()

      assert.are.equal("o", captured_owner)
      assert.are.equal("r", captured_repo)
      assert.are.equal(42, captured_number)
      assert.are.equal("PRR_1", shown.id)
    end)

    it("reports when nothing is pending instead of opening the panel", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, nil) end

      local opened = false
      package.loaded["gh-review.ui.review_submit"] = {
        show = function() opened = true end,
      }

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.pending_review()

      vim.notify = orig_notify
      assert.is_false(opened)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("no unsubmitted comments") then found = true end
      end
      assert.is_true(found)
    end)

    it("treats an empty pending review as nothing pending", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb)
        cb(nil, { id = "PRR_1", comments = {}, total_count = 0 })
      end

      local opened = false
      package.loaded["gh-review.ui.review_submit"] = {
        show = function() opened = true end,
      }
      local orig_notify = vim.notify
      vim.notify = function() end

      init.pending_review()

      vim.notify = orig_notify
      assert.is_false(opened)
    end)

    it("submits the review with the event chosen in the panel", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, make_pending()) end

      local panel_opts
      package.loaded["gh-review.ui.review_submit"] = {
        show = function(_, opts) panel_opts = opts end,
      }
      local input_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) input_opts = opts end,
      }
      local submitted
      graphql.submit_review = function(review_id, event, body, cb)
        submitted = { review_id = review_id, event = event, body = body }
        cb(nil, { state = "APPROVED" })
      end
      init.refresh = function() end

      init.pending_review()
      panel_opts.on_submit("APPROVE")

      assert.is_truthy(input_opts.title:find("Approve", 1, true))
      assert.is_truthy(input_opts.title:find("2 comments", 1, true))
      -- Approving without a summary is allowed
      assert.is_true(input_opts.allow_empty)
      input_opts.on_submit("")

      assert.are.equal("PRR_1", submitted.review_id)
      assert.are.equal("APPROVE", submitted.event)
      assert.are.equal("", submitted.body)
    end)

    it("requires a summary for events other than approve", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, make_pending()) end

      local panel_opts
      package.loaded["gh-review.ui.review_submit"] = {
        show = function(_, opts) panel_opts = opts end,
      }
      local input_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) input_opts = opts end,
      }

      init.pending_review()
      panel_opts.on_submit("REQUEST_CHANGES")

      assert.is_falsy(input_opts.allow_empty)
      assert.is_truthy(input_opts.title:find("Request changes", 1, true))
    end)

    it("jumps to a comment from the panel", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, make_pending()) end

      local panel_opts
      package.loaded["gh-review.ui.review_submit"] = {
        show = function(_, opts) panel_opts = opts end,
      }
      local opened
      init._open_file = function(path, line) opened = { path = path, line = line } end

      init.pending_review()
      panel_opts.on_jump({ path = "src/b.lua", line = 8 })

      assert.are.same({ path = "src/b.lua", line = 8 }, opened)
    end)

    it("maps command arguments to review events", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, make_pending()) end
      local input_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) input_opts = opts end,
      }
      local events = {}
      graphql.submit_review = function(_, event, _, cb)
        table.insert(events, event)
        cb(nil, {})
      end
      init.refresh = function() end

      -- `false` stands in for "no argument" so ipairs doesn't stop at a nil
      for _, arg in ipairs({ false, "comment", "approve", "request-changes" }) do
        init.submit_review(arg or nil)
        input_opts.on_submit("summary")
      end

      assert.are.same({ "COMMENT", "COMMENT", "APPROVE", "REQUEST_CHANGES" }, events)
    end)

    it("rejects an unknown review event", function()
      set_pr()
      local fetched = false
      graphql.fetch_pending_review = function(_, _, _, cb)
        fetched = true
        cb(nil, make_pending())
      end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.submit_review("merge")

      vim.notify = orig_notify
      assert.is_false(fetched)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("unknown review event") then found = true end
      end
      assert.is_true(found)
    end)

    it("reports a failed submit and does not refresh", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, make_pending()) end
      graphql.submit_review = function(_, _, _, cb) cb("Can not approve your own pull request", nil) end
      local input_opts
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) input_opts = opts end,
      }
      local refreshed = false
      init.refresh = function() refreshed = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.submit_review("approve")
      input_opts.on_submit("")

      vim.notify = orig_notify
      assert.is_false(refreshed)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("submit failed") then found = true end
      end
      assert.is_true(found)
    end)

    it("reports a failed pending-review fetch", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb("bad credentials", nil) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.pending_review()

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("failed to fetch pending review") then found = true end
      end
      assert.is_true(found)
    end)
  end)

  describe("review_pr", function()
    local function set_pr()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m", head_ref = "f",
        url = "", body = "", review_decision = "", repository = "o/r", node_id = "PR_1",
      })
    end

    --- Stub the comment input and return a getter for the opts it was opened with
    local function stub_input()
      local captured
      package.loaded["gh-review.ui.comment_input"] = {
        open = function(opts) captured = opts end,
      }
      return function() return captured end
    end

    after_each(function()
      package.loaded["gh-review.ui.comment_input"] = nil
    end)

    it("notifies when no active review", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_pr("approve")

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("creates a fresh review when nothing is pending", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, nil) end
      local input = stub_input()
      local created
      graphql.create_review = function(pr_id, event, body, cb)
        created = { pr_id = pr_id, event = event, body = body }
        cb(nil, { state = "APPROVED" })
      end
      local submitted = false
      graphql.submit_review = function() submitted = true end
      init.refresh = function() end

      init.review_pr("approve")

      local opts = input()
      assert.is_truthy(opts.title:find("Review PR #42", 1, true))
      assert.is_truthy(opts.title:find("Approve", 1, true))
      -- Nothing pending, so no mention of comments being published along with it
      assert.is_nil(opts.title:find("pending comment", 1, true))
      assert.is_true(opts.allow_empty)

      opts.on_submit("")

      assert.is_false(submitted)
      assert.are.same({ pr_id = "PR_1", event = "APPROVE", body = "" }, created)
    end)

    it("submits the pending review instead of creating a second one", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb)
        cb(nil, { id = "PRR_1", total_count = 1, comments = { { path = "src/a.lua", line = 5, body = "nit" } } })
      end
      local input = stub_input()
      local created = false
      graphql.create_review = function() created = true end
      local submitted
      graphql.submit_review = function(review_id, event, body, cb)
        submitted = { review_id = review_id, event = event, body = body }
        cb(nil, {})
      end
      init.refresh = function() end

      init.review_pr("request-changes")

      local opts = input()
      assert.is_truthy(opts.title:find("Request changes", 1, true))
      assert.is_truthy(opts.title:find("also publishes 1 pending comment", 1, true))
      -- GitHub rejects a bodyless "request changes"
      assert.is_falsy(opts.allow_empty)

      opts.on_submit("needs work")

      assert.is_false(created)
      assert.are.same({ review_id = "PRR_1", event = "REQUEST_CHANGES", body = "needs work" }, submitted)
    end)

    it("asks which verdict to give when no event is passed", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, nil) end
      local input = stub_input()
      local events = {}
      graphql.create_review = function(_, event, _, cb)
        table.insert(events, event)
        cb(nil, {})
      end
      init.refresh = function() end

      local captured_items, captured_format
      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        captured_items, captured_format = items, opts.format_item
        on_choice("COMMENT")
      end

      init.review_pr()
      vim.ui.select = orig_select

      assert.are.same({ "APPROVE", "COMMENT", "REQUEST_CHANGES" }, captured_items)
      assert.are.equal("Request changes", captured_format("REQUEST_CHANGES"))
      input().on_submit("some thoughts")
      assert.are.same({ "COMMENT" }, events)
    end)

    it("does nothing when the verdict picker is dismissed", function()
      set_pr()
      local fetched = false
      graphql.fetch_pending_review = function(_, _, _, cb)
        fetched = true
        cb(nil, nil)
      end

      local orig_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice) on_choice(nil) end

      init.review_pr()
      vim.ui.select = orig_select

      assert.is_false(fetched)
    end)

    it("rejects an unknown review event", function()
      set_pr()
      local fetched = false
      graphql.fetch_pending_review = function(_, _, _, cb)
        fetched = true
        cb(nil, nil)
      end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_pr("merge")

      vim.notify = orig_notify
      assert.is_false(fetched)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("unknown review event") then found = true end
      end
      assert.is_true(found)
    end)

    it("reports a failed submit and does not refresh", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb(nil, nil) end
      graphql.create_review = function(_, _, _, cb) cb("Can not approve your own pull request", nil) end
      local input = stub_input()
      local refreshed = false
      init.refresh = function() refreshed = true end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_pr("approve")
      input().on_submit("")

      vim.notify = orig_notify
      assert.is_false(refreshed)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("submit failed") then found = true end
      end
      assert.is_true(found)
    end)

    it("reports a failed pending-review fetch without opening the input", function()
      set_pr()
      graphql.fetch_pending_review = function(_, _, _, cb) cb("bad credentials", nil) end
      local input = stub_input()

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_pr("comment")

      vim.notify = orig_notify
      assert.is_nil(input())
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("failed to fetch pending review") then found = true end
      end
      assert.is_true(found)
    end)

    it("reports a missing PR node ID", function()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "m", head_ref = "f",
        url = "", body = "", review_decision = "", repository = "o/r",
      })
      local fetched = false
      graphql.fetch_pending_review = function(_, _, _, cb)
        fetched = true
        cb(nil, nil)
      end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.review_pr("approve")

      vim.notify = orig_notify
      assert.is_false(fetched)
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("node ID not available") then found = true end
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

  describe("_open_file", function()
    local diff_review_calls, minidiff_calls

    local function cleanup_test_buffers()
      local cwd = vim.fn.getcwd()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local name = vim.api.nvim_buf_get_name(buf)
          if name == cwd .. "/src/a.lua" or name:find("^ghreview://") then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      end
    end

    before_each(function()
      cleanup_test_buffers()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "main", base_sha = "base123",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_files({
        { path = "src/a.lua", status = "modified", additions = 1, deletions = 0 },
        { path = "src/gone.lua", status = "deleted", additions = 0, deletions = 10 },
      })

      diff_review_calls = {}
      minidiff_calls = {}

      package.loaded["gh-review.ui.diff_review"] = {
        get_file_path = function() return nil end,
        close = function() table.insert(diff_review_calls, { fn = "close" }) end,
        open = function(path, line)
          table.insert(diff_review_calls, { fn = "open", path = path, line = line })
        end,
        is_diff_active = function() return false end,
        get_work_win = function() return nil end,
      }
      package.loaded["gh-review.ui.minidiff"] = {
        attach = function(buf, opts)
          table.insert(minidiff_calls, { fn = "attach", buf = buf, opts = opts })
        end,
        set_overlay = function(buf, enable)
          table.insert(minidiff_calls, { fn = "set_overlay", buf = buf, enable = enable })
        end,
        detach_all = function() end,
      }
    end)

    after_each(cleanup_test_buffers)

    it("calls diff_review.open in split mode", function()
      state.set_view_mode("split")
      init._open_file("src/a.lua", 5)

      local found = false
      for _, c in ipairs(diff_review_calls) do
        if c.fn == "open" and c.path == "src/a.lua" and c.line == 5 then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("opens an inline overlay in inline mode", function()
      state.set_view_mode("inline")

      local cwd = vim.fn.getcwd()
      local test_file = cwd .. "/src/a.lua"
      vim.fn.mkdir(cwd .. "/src", "p")
      vim.fn.writefile({ "line1", "line2" }, test_file)

      init._open_file("src/a.lua", 1)

      local attached, overlay_on = false, false
      for _, c in ipairs(minidiff_calls) do
        if c.fn == "attach" then
          attached = true
          assert.are.equal("src/a.lua", c.opts and c.opts.rel_path)
        end
        if c.fn == "set_overlay" and c.enable == true then
          overlay_on = true
        end
      end
      assert.is_true(attached)
      assert.is_true(overlay_on)

      vim.fn.delete(test_file)
      vim.fn.delete(cwd .. "/src", "d")
    end)

    it("falls back to split with notify when inline requested for deleted file", function()
      state.set_view_mode("inline")

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init._open_file("src/gone.lua", 1)

      vim.notify = orig_notify

      local opened_split = false
      for _, c in ipairs(diff_review_calls) do
        if c.fn == "open" and c.path == "src/gone.lua" then opened_split = true end
      end
      assert.is_true(opened_split)

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("inline view unavailable for deleted files") then found = true end
      end
      assert.is_true(found)
    end)

    it("uses a scratch buffer for inline view of a commit-scoped file", function()
      state.set_view_mode("inline")
      state.set_active_commit({ sha = "abc12345", oid = "abc12345full", message = "m", author = "d" })
      state.set_commit_files({ { path = "src/a.lua", status = "modified", additions = 1, deletions = 0 } })

      local util = require("gh-review.util")
      local orig_git_show = util.git_show_lines
      util.git_show_lines = function(ref)
        assert.is_truthy(ref:find("abc12345full:src/a.lua"))
        return { "commit line 1" }
      end

      init._open_file("src/a.lua", 1)

      util.git_show_lines = orig_git_show

      -- The scratch buffer should be current and named ghreview://commit/...
      local cur_name = vim.api.nvim_buf_get_name(0)
      assert.is_truthy(cur_name:find("^ghreview://commit/abc12345/src/a.lua$"))

      local attached = false
      for _, c in ipairs(minidiff_calls) do
        if c.fn == "attach" and c.opts and c.opts.rel_path == "src/a.lua" then
          attached = true
        end
      end
      assert.is_true(attached)

      -- Clean up the scratch buffer
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local name = vim.api.nvim_buf_get_name(buf)
          if name:find("^ghreview://commit/") then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end
      end
    end)
  end)

  describe("toggle_view", function()
    local function cleanup_test_buffers()
      local cwd = vim.fn.getcwd()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local name = vim.api.nvim_buf_get_name(buf)
          if name == cwd .. "/src/a.lua" or name:find("^ghreview://") then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      end
    end

    before_each(function()
      cleanup_test_buffers()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "main", base_sha = "base123",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_files({ { path = "src/a.lua", status = "modified", additions = 1, deletions = 0 } })
      state.set_view_mode("split")
    end)

    after_each(cleanup_test_buffers)

    it("notifies when no active review", function()
      state.clear()

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.toggle_view()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("flips split → inline and reopens the current file", function()
      local opened
      init._open_file = function(path, line) opened = { path = path, line = line } end

      -- Set up a current buffer that looks like a PR file
      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/a.lua")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      init.toggle_view()

      vim.notify = orig_notify

      assert.are.equal("inline", state.get_view_mode())
      assert.is_not_nil(opened)
      assert.are.equal("src/a.lua", opened.path)
      assert.are.equal(2, opened.line)

      local notified = false
      for _, n in ipairs(notifications) do
        if n.msg:find("view mode → inline") then notified = true end
      end
      assert.is_true(notified)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("flips inline → split", function()
      state.set_view_mode("inline")
      local opened
      init._open_file = function(path, line) opened = { path = path, line = line } end

      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/a.lua")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })

      init.toggle_view()

      assert.are.equal("split", state.get_view_mode())
      assert.are.equal("src/a.lua", opened.path)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses diff_review's current file and cursor when in split view", function()
      local opened
      init._open_file = function(path, line) opened = { path = path, line = line } end

      -- Stub diff_review to look like an active split session
      local dr = package.loaded["gh-review.ui.diff_review"]
      dr.is_diff_active = function() return true end
      dr.get_file_path = function() return "src/a.lua" end

      -- Create a window whose cursor we'll be on
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local win = vim.api.nvim_get_current_win()
      dr.get_work_win = function() return win end

      init.toggle_view()

      assert.are.equal("src/a.lua", opened.path)
      assert.are.equal(3, opened.line)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("next_file / prev_file", function()
    local function cleanup_test_buffers()
      local cwd = vim.fn.getcwd()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local name = vim.api.nvim_buf_get_name(buf)
          if name:find(cwd .. "/src/") or name:find("^ghreview://") then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      end
    end

    before_each(function()
      cleanup_test_buffers()
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "main",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_files({
        { path = "src/a.lua", status = "modified" },
        { path = "src/b.lua", status = "modified" },
        { path = "src/c.lua", status = "modified" },
      })
    end)

    after_each(cleanup_test_buffers)

    it("advances from current inline-view buffer to the next PR file", function()
      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/b.lua")
      vim.api.nvim_set_current_buf(buf)

      local opened
      init._open_file = function(path) opened = path end

      init.next_file()
      assert.are.equal("src/c.lua", opened)

      init.prev_file()
      -- Current buf is still src/b.lua, so prev_file goes to src/a.lua
      assert.are.equal("src/a.lua", opened)
    end)

    it("jumps to first file when not sitting on any PR file", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "/tmp/unrelated.lua")
      vim.api.nvim_set_current_buf(buf)

      local opened
      init._open_file = function(path) opened = path end

      init.next_file()
      assert.are.equal("src/a.lua", opened)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("silent no-op when no PR is active", function()
      state.clear()

      local opened
      init._open_file = function(path) opened = path end

      init.next_file()
      init.prev_file()
      assert.is_nil(opened)
    end)

    it("follows the sidebar order, not the order files were loaded in", function()
      local cwd = vim.fn.getcwd()
      -- Sidebar shows directories first: src/x.lua, then top.lua.
      state.set_files({
        { path = "top.lua", status = "modified" },
        { path = "src/x.lua", status = "modified" },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/x.lua")
      vim.api.nvim_set_current_buf(buf)

      local opened
      init._open_file = function(path) opened = path end

      init.next_file()
      assert.are.equal("top.lua", opened)
    end)

    it("notifies at the last file", function()
      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, cwd .. "/src/c.lua")
      vim.api.nvim_set_current_buf(buf)

      local opened
      init._open_file = function(path) opened = path end
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      init.next_file()
      vim.notify = orig_notify

      assert.is_nil(opened)
      local warned = false
      for _, m in ipairs(notifications) do
        if m:find("last file") then warned = true end
      end
      assert.is_true(warned)
    end)
  end)

  describe("next_diff / prev_diff crossing files", function()
    local orig_minidiff
    local goto_calls
    local bufs

    --- Put the cursor on a PR file so _current_rel_path() resolves to it.
    --- Reuses a buffer of that name if an earlier test left one behind.
    ---@param rel string
    local function sit_on(rel)
      local name = vim.fn.getcwd() .. "/" .. rel
      local buf = vim.fn.bufnr(name)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, name)
      end
      vim.api.nvim_set_current_buf(buf)
      table.insert(bufs, buf)
      return buf
    end

    --- Stub mini.diff. goto_hunk records the direction and never moves the
    --- cursor (so navigate_diff treats the current file as exhausted), and
    --- hunks only appear after `hunks_after` polls — the real plugin computes
    --- them on a timer, several event-loop ticks after the buffer is attached.
    ---@param hunks_after number
    local function stub_minidiff(hunks_after)
      local polls = 0
      package.loaded["mini.diff"] = {
        goto_hunk = function(dir) table.insert(goto_calls, dir) end,
        get_buf_data = function()
          polls = polls + 1
          if polls < hunks_after then return { hunks = {} } end
          return { hunks = { { buf_start = 5, buf_count = 2 } } }
        end,
      }
    end

    before_each(function()
      orig_minidiff = package.loaded["mini.diff"]
      goto_calls = {}
      bufs = {}
      state.set_pr({
        number = 42, title = "T", author = "a", base_ref = "main",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_files({
        { path = "src/a.lua", status = "modified" },
        { path = "src/b.lua", status = "modified" },
      })
      state.set_view_mode("inline")
    end)

    after_each(function()
      package.loaded["mini.diff"] = orig_minidiff
      for _, buf in ipairs(bufs) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end)

    it("lands on the next file's first hunk once mini.diff has hunks", function()
      stub_minidiff(3)
      sit_on("src/a.lua")

      local opened
      init._open_file = function(path) opened = path end

      init.next_diff()
      assert.are.equal("src/b.lua", opened)
      vim.wait(500, function() return #goto_calls >= 2 end)
      assert.are.same({ "next", "first" }, goto_calls)
    end)

    it("lands on the previous file's last hunk", function()
      stub_minidiff(1)
      sit_on("src/b.lua")

      local opened
      init._open_file = function(path) opened = path end

      init.prev_diff()
      assert.are.equal("src/a.lua", opened)
      vim.wait(500, function() return #goto_calls >= 2 end)
      assert.are.same({ "prev", "last" }, goto_calls)
    end)

    it("opens an added file at the top instead of hunting for hunks", function()
      state.set_files({
        { path = "src/a.lua", status = "modified" },
        { path = "src/added.lua", status = "added" },
      })
      stub_minidiff(1)
      local buf = sit_on("src/a.lua")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      local opened
      init._open_file = function(path) opened = path end

      init.next_diff()
      assert.are.equal("src/added.lua", opened)
      assert.are.same({ "next" }, goto_calls)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("stops waiting for hunks when the user moves to another buffer", function()
      local elsewhere = vim.api.nvim_create_buf(false, true)
      table.insert(bufs, elsewhere)

      local polls = 0
      package.loaded["mini.diff"] = {
        goto_hunk = function(dir) table.insert(goto_calls, dir) end,
        get_buf_data = function()
          polls = polls + 1
          -- User navigates away while we're still waiting for the diff.
          vim.api.nvim_set_current_buf(elsewhere)
          return { hunks = {} }
        end,
      }
      sit_on("src/a.lua")
      init._open_file = function() end

      init.next_diff()
      vim.wait(100)
      assert.are.equal(1, polls)
      assert.are.same({ "next" }, goto_calls)
    end)
  end)
end)
