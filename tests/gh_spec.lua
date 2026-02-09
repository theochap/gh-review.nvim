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
      gh = require("gh-review.gh")

      local result_err
      local done = false
      gh.checkout(123, function(err)
        result_err = err
        done = true
      end)
      vim.wait(100, function() return done end)

      assert.is_nil(result_err)
      assert.are.same({ "gh", "pr", "checkout", "123" }, captured[1].cmd)
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
    it("constructs -F args from variables", function()
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
      -- Find -F arguments
      local f_args = {}
      for i, v in ipairs(cmd) do
        if v == "-F" then
          table.insert(f_args, cmd[i + 1])
        end
      end
      -- Should have owner=me and number=5
      local found_owner, found_number = false, false
      for _, arg in ipairs(f_args) do
        if arg == "owner=me" then found_owner = true end
        if arg == "number=5" then found_number = true end
      end
      assert.is_true(found_owner)
      assert.is_true(found_number)

      -- Should have -f query=...
      local has_query = false
      for i, v in ipairs(cmd) do
        if v == "-f" and cmd[i + 1] and cmd[i + 1]:find("^query=") then
          has_query = true
        end
      end
      assert.is_true(has_query)
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
