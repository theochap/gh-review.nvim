---@module 'luassert'

local config = require("gh-review.config")

--- Stub vim.system to intercept CLI calls
---@param responses table[] List of { code, stdout, stderr } to return in order
---@param capture table[] Mutable list to capture calls into
---@return function restore Original vim.system
local function stub_vim_system(responses, capture)
  local orig = vim.system
  local call_idx = 0
  vim.system = function(cmd, opts, callback)
    call_idx = call_idx + 1
    table.insert(capture, { cmd = cmd, opts = opts })
    local resp = responses[call_idx] or responses[#responses]
    if callback then
      -- Async path: invoke callback immediately (simulates vim.schedule)
      callback(resp)
      return nil
    else
      -- Sync path: return object with :wait()
      return {
        wait = function()
          return resp
        end,
      }
    end
  end
  return orig
end

local function restore_vim_system(orig)
  vim.system = orig
end

describe("gh", function()
  local gh
  local captured
  local orig_system

  before_each(function()
    config.setup()
    captured = {}
    -- Fresh require each time
    package.loaded["gh-review.gh"] = nil
  end)

  after_each(function()
    if orig_system then
      restore_vim_system(orig_system)
      orig_system = nil
    end
  end)

  describe("run", function()
    it("constructs command with gh_cmd prepended", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "ok\n", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.run({ "pr", "view", "42" }, function()
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal(1, #captured)
      assert.are.same({ "gh", "pr", "view", "42" }, captured[1].cmd)
    end)

    it("calls callback with nil err and stdout on success", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "hello world", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err, result_out
      local done = false
      gh.run({ "test" }, function(err, output)
        result_err = err
        result_out = output
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_nil(result_err)
      assert.are.equal("hello world", result_out)
    end)

    it("calls callback with stderr on failure", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "permission denied" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err, result_out
      local done = false
      gh.run({ "test" }, function(err, output)
        result_err = err
        result_out = output
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("permission denied", result_err)
      assert.is_nil(result_out)
    end)

    it("uses fallback error message when stderr is nil", function()
      orig_system = stub_vim_system({
        { code = 42, stdout = "", stderr = nil },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.run({ "test" }, function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("gh exited with code 42", result_err)
    end)

    it("passes cwd option through", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.run({ "test" }, function() done = true end, { cwd = "/tmp/myrepo" })
      vim.wait(100, function() return done end)

      assert.are.equal("/tmp/myrepo", captured[1].opts.cwd)
    end)

    it("sets cwd to nil when no opts provided", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.run({ "test" }, function() done = true end)
      vim.wait(100, function() return done end)

      assert.is_nil(captured[1].opts.cwd)
    end)

    it("respects custom gh_cmd from config", function()
      config.setup({ gh_cmd = "/usr/local/bin/gh" })
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.run({ "pr", "list" }, function() done = true end)
      vim.wait(100, function() return done end)

      assert.are.equal("/usr/local/bin/gh", captured[1].cmd[1])
    end)
  end)

  describe("run_json", function()
    it("decodes JSON response on success", function()
      local json_str = vim.json.encode({ count = 42, items = { "a", "b" } })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err, result_data
      local done = false
      gh.run_json({ "api", "test" }, function(err, data)
        result_err = err
        result_data = data
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_nil(result_err)
      assert.are.equal(42, result_data.count)
      assert.are.same({ "a", "b" }, result_data.items)
    end)

    it("passes through error from run", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "not found" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err, result_data
      local done = false
      gh.run_json({ "api", "test" }, function(err, data)
        result_err = err
        result_data = data
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("not found", result_err)
      assert.is_nil(result_data)
    end)

    it("returns JSON decode error on invalid JSON", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "not valid json {{", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err, result_data
      local done = false
      gh.run_json({ "api", "test" }, function(err, data)
        result_err = err
        result_data = data
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_truthy(result_err:find("JSON decode error:"))
      assert.is_nil(result_data)
    end)
  end)

  describe("run_sync", function()
    it("returns stdout on success", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "sync output", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local output, err = gh.run_sync({ "status" })

      assert.are.equal("sync output", output)
      assert.is_nil(err)
    end)

    it("returns error on failure", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "auth required" },
      }, captured)
      gh = require("gh-review.gh")

      local output, err = gh.run_sync({ "status" })

      assert.is_nil(output)
      assert.are.equal("auth required", err)
    end)

    it("uses fallback error when stderr is nil", function()
      orig_system = stub_vim_system({
        { code = 5, stdout = "", stderr = nil },
      }, captured)
      gh = require("gh-review.gh")

      local output, err = gh.run_sync({ "status" })

      assert.is_nil(output)
      assert.are.equal("gh exited with code 5", err)
    end)

    it("passes cwd option through", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      gh.run_sync({ "status" }, { cwd = "/tmp" })

      assert.are.equal("/tmp", captured[1].opts.cwd)
    end)
  end)

  describe("checkout", function()
    it("passes correct args to run", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      -- Force the non-jj branch so we only expect one vim.system call.
      local util = require("gh-review.util")
      local orig_find = util.find_jj_root
      util.find_jj_root = function() return nil end
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.checkout(123, function(err)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)
      util.find_jj_root = orig_find

      assert.is_nil(result_err)
      assert.are.equal(1, #captured)
      assert.are.same({ "gh", "pr", "checkout", "123" }, captured[1].cmd)
    end)

    it("runs jj git import after checkout in a colocated jj repo", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" }, -- gh pr checkout
        { code = 0, stdout = "", stderr = "" }, -- jj git import
      }, captured)
      local util = require("gh-review.util")
      local orig_find = util.find_jj_root
      util.find_jj_root = function() return "/fake/jj/root" end
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.checkout(456, function(err)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)
      util.find_jj_root = orig_find

      assert.is_nil(result_err)
      assert.are.equal(2, #captured)
      assert.are.same({ "gh", "pr", "checkout", "456" }, captured[1].cmd)
      assert.are.same({ "jj", "git", "import" }, captured[2].cmd)
      assert.are.equal("/fake/jj/root", captured[2].opts.cwd)
    end)

    it("still completes when jj import fails (warns, does not error)", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },               -- gh pr checkout
        { code = 1, stdout = "", stderr = "import failed\n" },-- jj git import
      }, captured)
      local util = require("gh-review.util")
      local orig_find = util.find_jj_root
      util.find_jj_root = function() return "/fake/jj/root" end
      gh = require("gh-review.gh")

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      local result_err
      local done = false
      gh.checkout(789, function(err)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)
      util.find_jj_root = orig_find
      vim.notify = orig_notify

      assert.is_nil(result_err)
      assert.is_true(#notifications >= 1)
      local warned = false
      for _, n in ipairs(notifications) do
        if n.msg:find("jj git import failed") then warned = true end
      end
      assert.is_true(warned)
    end)

    it("propagates gh checkout error and skips jj import", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "pr not found\n" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.checkout(999, function(err)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_truthy(result_err and result_err:find("pr not found"))
      assert.are.equal(1, #captured)
    end)

    -- A secondary jj workspace has no git worktree, so `gh pr checkout` cannot
    -- run there at all; the jj-native equivalent is used instead.
    describe("in a jj workspace without a git worktree", function()
      local vcs = require("gh-review.vcs")
      local orig_context, orig_jj_checkout

      before_each(function()
        orig_context = vcs.context
        orig_jj_checkout = vcs.jj_checkout
        vcs.context = function() return { kind = "jj", root = "/ws", jj_root = "/ws" } end
      end)

      after_each(function()
        vcs.context = orig_context
        vcs.jj_checkout = orig_jj_checkout
      end)

      it("resolves the head branch and checks it out with jj", function()
        orig_system = stub_vim_system({
          { code = 0, stdout = vim.json.encode({ headRefName = "feat/x" }), stderr = "" },
        }, captured)
        gh = require("gh-review.gh")

        local checked_out
        vcs.jj_checkout = function(branch, cb)
          checked_out = branch
          cb(nil)
        end

        local result_err
        local done = false
        gh.checkout(42, function(err)
          result_err = err
          done = true
        end)
        vim.wait(100, function() return done end)

        assert.is_nil(result_err)
        assert.are.equal("feat/x", checked_out)
        -- Only the metadata lookup goes through gh; no `gh pr checkout`
        assert.are.equal(1, #captured)
        assert.are.same({ "gh", "pr", "view", "42", "--json", "headRefName" }, captured[1].cmd)
      end)

      it("errors when the head branch cannot be resolved", function()
        orig_system = stub_vim_system({
          { code = 0, stdout = vim.json.encode({}), stderr = "" },
        }, captured)
        gh = require("gh-review.gh")

        local called = false
        vcs.jj_checkout = function() called = true end

        local result_err
        local done = false
        gh.checkout(42, function(err)
          result_err = err
          done = true
        end)
        vim.wait(100, function() return done end)

        assert.is_false(called)
        assert.is_truthy(result_err and result_err:find("head branch"))
      end)
    end)
  end)

  describe("pr_view", function()
    it("passes correct args with fields", function()
      local json_str = vim.json.encode({ number = 42, title = "Test" })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_data
      local done = false
      gh.pr_view(42, function(_, data)
        result_data = data
        done = true
      end)
      vim.wait(100, function() return done end)

      local cmd = captured[1].cmd
      assert.are.equal("pr", cmd[2])
      assert.are.equal("view", cmd[3])
      assert.are.equal("42", cmd[4])
      assert.are.equal("--json", cmd[5])
      assert.is_truthy(cmd[6]:find("number"))
      assert.is_truthy(cmd[6]:find("title"))
      -- Needed as the commit_id for immediately-posted inline comments
      assert.is_truthy(cmd[6]:find("headRefOid"))
      assert.are.equal(42, result_data.number)
    end)
  end)

  describe("pr_diff", function()
    it("passes correct args and returns diff text", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "diff --git a/f b/f\n", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_output
      local done = false
      gh.pr_diff(10, function(_, output)
        result_output = output
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.same({ "gh", "pr", "diff", "10" }, captured[1].cmd)
      assert.are.equal("diff --git a/f b/f\n", result_output)
    end)
  end)

  describe("pr_comments", function()
    it("extracts comments from response data", function()
      local json_str = vim.json.encode({
        comments = {
          { body = "lgtm", author = { login = "rev" } },
        },
      })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_comments
      local done = false
      gh.pr_comments(5, function(_, comments)
        result_comments = comments
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal(1, #result_comments)
      assert.are.equal("lgtm", result_comments[1].body)
    end)

    it("returns empty table when no comments field", function()
      local json_str = vim.json.encode({})
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_comments
      local done = false
      gh.pr_comments(5, function(_, comments)
        result_comments = comments
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.same({}, result_comments)
    end)
  end)

  describe("pr_commits", function()
    it("extracts commits from response data", function()
      local json_str = vim.json.encode({
        commits = {
          { commit = { messageHeadline = "fix", oid = "abc" } },
        },
      })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_commits
      local done = false
      gh.pr_commits(7, function(_, commits)
        result_commits = commits
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal(1, #result_commits)
    end)
  end)

  describe("pr_view_current", function()
    it("does not include PR number in args", function()
      local json_str = vim.json.encode({ number = 1, title = "test" })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.pr_view_current(function() done = true end)
      vim.wait(100, function() return done end)

      local cmd = captured[1].cmd
      assert.are.equal("pr", cmd[2])
      assert.are.equal("view", cmd[3])
      assert.are.equal("--json", cmd[4])
      -- No number argument before --json
    end)

    -- Under jj, git HEAD is detached and `gh pr view` with no argument fails,
    -- so the PR is looked up by each jj bookmark instead.
    describe("with jj bookmark candidates", function()
      local vcs = require("gh-review.vcs")
      local orig_candidates

      before_each(function()
        orig_candidates = vcs.pr_branch_candidates_async
      end)

      after_each(function()
        vcs.pr_branch_candidates_async = orig_candidates
      end)

      it("looks the PR up by bookmark name", function()
        vcs.pr_branch_candidates_async = function(cb) cb({ "feat/x" }) end
        orig_system = stub_vim_system({
          { code = 0, stdout = vim.json.encode({ number = 7, title = "t" }), stderr = "" },
        }, captured)
        gh = require("gh-review.gh")

        local result, done = nil, false
        gh.pr_view_current(function(_, data)
          result = data
          done = true
        end)
        vim.wait(100, function() return done end)

        assert.are.equal(7, result.number)
        assert.are.equal("feat/x", captured[1].cmd[4])
        assert.are.equal("--json", captured[1].cmd[5])
      end)

      it("tries the next bookmark when the first has no PR", function()
        vcs.pr_branch_candidates_async = function(cb) cb({ "push-abc", "feat/x" }) end
        orig_system = stub_vim_system({
          { code = 1, stdout = "", stderr = "no pull requests found" },
          { code = 0, stdout = vim.json.encode({ number = 9 }), stderr = "" },
        }, captured)
        gh = require("gh-review.gh")

        local result, done = nil, false
        gh.pr_view_current(function(_, data)
          result = data
          done = true
        end)
        vim.wait(100, function() return done end)

        assert.are.equal(9, result.number)
        assert.are.equal(2, #captured)
        assert.are.equal("push-abc", captured[1].cmd[4])
        assert.are.equal("feat/x", captured[2].cmd[4])
      end)

      it("reports the bookmarks it tried when none has a PR", function()
        vcs.pr_branch_candidates_async = function(cb) cb({ "a", "b" }) end
        orig_system = stub_vim_system({
          { code = 1, stdout = "", stderr = "no pull requests found" },
        }, captured)
        gh = require("gh-review.gh")

        local err, done = nil, false
        gh.pr_view_current(function(e)
          err = e
          done = true
        end)
        vim.wait(100, function() return done end)

        assert.are.equal(2, #captured)
        assert.is_truthy(err and err:find("a, b", 1, true))
      end)
    end)
  end)

  describe("pr_view_branch", function()
    it("returns the first branch that resolves to a PR", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "no pull requests found" },
        { code = 0, stdout = vim.json.encode({ number = 12, title = "stacked" }), stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result, err, done = nil, nil, false
      gh.pr_view_branch({ "main", "feat/two" }, function(e, data)
        err, result, done = e, data, true
      end)
      vim.wait(100, function() return done end)

      assert.is_nil(err)
      assert.are.equal(12, result.number)
      assert.are.equal(2, #captured)
      assert.are.equal("main", captured[1].cmd[4])
      assert.are.equal("feat/two", captured[2].cmd[4])
      -- The head SHA is needed to post immediate comments on the loaded PR
      assert.is_truthy(captured[2].cmd[6]:find("headRefOid", 1, true))
    end)

    it("reports the branches it tried when none has a PR", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "no pull requests found" },
      }, captured)
      gh = require("gh-review.gh")

      local err, done = nil, false
      gh.pr_view_branch({ "a", "b" }, function(e)
        err, done = e, true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal(2, #captured)
      assert.is_truthy(err and err:find("a, b", 1, true))
    end)

    it("errors without calling gh when there is no branch to try", function()
      orig_system = stub_vim_system({ { code = 0, stdout = "", stderr = "" } }, captured)
      gh = require("gh-review.gh")

      local err
      gh.pr_view_branch({}, function(e) err = e end)

      assert.is_truthy(err)
      assert.are.equal(0, #captured)
    end)
  end)

  describe("pr_add_comment", function()
    it("passes correct args with body", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.pr_add_comment(99, "Great work!", function() done = true end)
      vim.wait(100, function() return done end)

      local cmd = captured[1].cmd
      assert.are.equal("pr", cmd[2])
      assert.are.equal("comment", cmd[3])
      assert.are.equal("99", cmd[4])
      assert.are.equal("--body", cmd[5])
      assert.are.equal("Great work!", cmd[6])
    end)
  end)

  describe("pr_add_review_comment", function()
    --- Map of the -f/-F key=value pairs in a gh api call.
    ---@param cmd string[]
    ---@return table<string, string>
    local function fields(cmd)
      local out = {}
      for i, v in ipairs(cmd) do
        if v == "-f" or v == "-F" then
          local key, val = (cmd[i + 1] or ""):match("^([^=]+)=(.*)$")
          if key then out[key] = val end
        end
      end
      return out
    end

    it("posts to the REST comments endpoint with a single line", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "{}", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local err, done = "unset", false
      gh.pr_add_review_comment(42, {
        repo = "owner/repo",
        body = "nit: typo",
        commit_id = "deadbeef",
        path = "src/a.lua",
        line = 12,
        start_line = 12,
      }, function(e)
        err = e
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_nil(err)
      -- No repo lookup needed when the caller already knows it.
      assert.are.equal(1, #captured)
      local cmd = captured[1].cmd
      assert.are.same({ "gh", "api", "--method", "POST", "repos/owner/repo/pulls/42/comments" },
        { cmd[1], cmd[2], cmd[3], cmd[4], cmd[5] })

      local f = fields(cmd)
      assert.are.equal("nit: typo", f.body)
      assert.are.equal("deadbeef", f.commit_id)
      assert.are.equal("src/a.lua", f.path)
      assert.are.equal("RIGHT", f.side)
      assert.are.equal("12", f.line)
      -- start_line == line is not a range, so GitHub must not be sent one
      assert.is_nil(f.start_line)
      assert.is_nil(f.start_side)
    end)

    it("sends a range for multi-line comments", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "{}", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.pr_add_review_comment(7, {
        repo = "o/r",
        body = "b",
        commit_id = "sha",
        path = "p",
        line = 20,
        start_line = 18,
      }, function() done = true end)
      vim.wait(100, function() return done end)

      local f = fields(captured[1].cmd)
      assert.are.equal("18", f.start_line)
      assert.are.equal("RIGHT", f.start_side)
      assert.are.equal("20", f.line)
    end)

    it("looks up the repo when it was not provided", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "owner/repo\n", stderr = "" }, -- repo_name
        { code = 0, stdout = "{}", stderr = "" },           -- POST
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.pr_add_review_comment(1, {
        body = "b", commit_id = "sha", path = "p", line = 1,
      }, function() done = true end)
      vim.wait(100, function() return done end)

      assert.are.equal(2, #captured)
      assert.are.equal("repos/owner/repo/pulls/1/comments", captured[2].cmd[5])
    end)

    it("propagates a failed post", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "line must be part of the diff" },
      }, captured)
      gh = require("gh-review.gh")

      local err, done = nil, false
      gh.pr_add_review_comment(1, {
        repo = "o/r", body = "b", commit_id = "sha", path = "p", line = 1,
      }, function(e)
        err = e
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_truthy(err and err:find("part of the diff", 1, true))
    end)
  end)

  describe("pr_list", function()
    it("passes correct args with limit", function()
      local json_str = vim.json.encode({})
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.pr_list(function() done = true end)
      vim.wait(100, function() return done end)

      local cmd = captured[1].cmd
      assert.are.equal("pr", cmd[2])
      assert.are.equal("list", cmd[3])
      assert.are.equal("--json", cmd[4])
      assert.are.equal("--limit", cmd[6])
      assert.are.equal("50", cmd[7])
    end)
  end)

  describe("repo_name", function()
    it("trims output and returns repo name", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = "  owner/repo  \n", stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_repo
      local done = false
      gh.repo_name(function(_, repo)
        result_repo = repo
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("owner/repo", result_repo)
    end)

    it("passes error through on failure", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "not a repo" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.repo_name(function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("not a repo", result_err)
    end)
  end)

  describe("pr_files", function()
    it("maps REST API fields correctly", function()
      -- pr_files calls repo_name first, then run_json
      -- Call 1: repo_name → run → success with "owner/repo"
      -- Call 2: run_json → run → success with file list JSON
      local file_data = vim.json.encode({
        { filename = "src/a.lua", status = "added", additions = 10, deletions = 0, previous_filename = nil },
        { filename = "src/b.lua", status = "removed", additions = 0, deletions = 5, previous_filename = nil },
        { filename = "src/c.lua", status = "modified", additions = 3, deletions = 2 },
        { filename = "src/new.lua", status = "renamed", additions = 1, deletions = 1, previous_filename = "src/old.lua" },
      })
      orig_system = stub_vim_system({
        -- First call: repo_name
        { code = 0, stdout = "owner/repo\n", stderr = "" },
        -- Second call: REST API files
        { code = 0, stdout = file_data, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_files
      local done = false
      gh.pr_files(42, function(err, files)
        assert.is_nil(err)
        result_files = files
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal(4, #result_files)

      -- added stays as "added"
      assert.are.equal("src/a.lua", result_files[1].path)
      assert.are.equal("added", result_files[1].status)
      assert.are.equal(10, result_files[1].additions)

      -- "removed" maps to "deleted"
      assert.are.equal("src/b.lua", result_files[2].path)
      assert.are.equal("deleted", result_files[2].status)

      -- "modified" passes through
      assert.are.equal("modified", result_files[3].status)

      -- renamed with previousFilename
      assert.are.equal("src/new.lua", result_files[4].path)
      assert.are.equal("src/old.lua", result_files[4].previousFilename)
    end)

    it("propagates repo_name error", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "no repo" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.pr_files(1, function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("no repo", result_err)
    end)

    it("propagates REST API error", function()
      local call_count = 0
      local orig = vim.system
      vim.system = function(cmd, opts, callback)
        call_count = call_count + 1
        if call_count == 1 then
          -- repo_name succeeds
          callback({ code = 0, stdout = "owner/repo\n", stderr = "" })
        else
          -- REST API fails
          callback({ code = 1, stdout = "", stderr = "rate limited" })
        end
        return nil
      end
      orig_system = orig

      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.pr_files(1, function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("rate limited", result_err)
    end)
  end)

  describe("graphql", function()
    --- Collect the values passed with a given flag, e.g. flag_values(cmd, "-f").
    ---@param cmd string[]
    ---@param flag string
    ---@return table<string, true>
    local function flag_values(cmd, flag)
      local found = {}
      for i, v in ipairs(cmd) do
        if v == flag then found[cmd[i + 1]] = true end
      end
      return found
    end

    it("sends strings as raw fields and numbers as typed fields", function()
      local json_str = vim.json.encode({ data = { result = true } })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.graphql("query { viewer { login } }", { owner = "me", number = 5 }, function()
        done = true
      end)
      vim.wait(100, function() return done end)

      local cmd = captured[1].cmd
      assert.are.equal("api", cmd[2])
      assert.are.equal("graphql", cmd[3])
      -- Numbers are typed (-F); strings must stay raw (-f) so a numeric-looking
      -- body like "42" isn't coerced into an Int.
      assert.is_true(flag_values(cmd, "-F")["number=5"])
      assert.is_true(flag_values(cmd, "-f")["owner=me"])
      assert.is_nil(flag_values(cmd, "-F")["owner=me"])

      -- Should have -f query=...
      local has_query = false
      for i, v in ipairs(cmd) do
        if v == "-f" and cmd[i + 1] and cmd[i + 1]:find("^query=") then
          has_query = true
        end
      end
      assert.is_true(has_query)
    end)

    it("keeps a numeric-looking string body a string", function()
      orig_system = stub_vim_system({
        { code = 0, stdout = vim.json.encode({ data = {} }), stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local done = false
      gh.graphql("mutation { x }", { body = "42" }, function() done = true end)
      vim.wait(100, function() return done end)

      assert.is_true(flag_values(captured[1].cmd, "-f")["body=42"])
    end)

    it("returns data.data on success", function()
      local json_str = vim.json.encode({ data = { viewer = { login = "me" } } })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_data
      local done = false
      gh.graphql("query { viewer { login } }", {}, function(err, data)
        assert.is_nil(err)
        result_data = data
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("me", result_data.viewer.login)
    end)

    it("converts data.errors to error string", function()
      local json_str = vim.json.encode({
        data = nil,
        errors = {
          { message = "field not found" },
          { message = "access denied" },
        },
      })
      orig_system = stub_vim_system({
        { code = 0, stdout = json_str, stderr = "" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.graphql("query { bad }", {}, function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_truthy(result_err:find("GraphQL errors:"))
      assert.is_truthy(result_err:find("field not found"))
      assert.is_truthy(result_err:find("access denied"))
    end)

    it("passes through run error", function()
      orig_system = stub_vim_system({
        { code = 1, stdout = "", stderr = "network error" },
      }, captured)
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.graphql("query { x }", {}, function(err, _)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.are.equal("network error", result_err)
    end)
  end)
end)
