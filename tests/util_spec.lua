---@module 'luassert'

local config = require("gh-review.config")
local util = require("gh-review.util")

describe("util", function()
  before_each(function()
    config.setup()
  end)

  describe("format_time", function()
    it("extracts date from ISO 8601 timestamp", function()
      assert.are.equal("2024-01-15", util.format_time("2024-01-15T10:30:00Z"))
    end)

    it("extracts date without time zone", function()
      assert.are.equal("2023-12-01", util.format_time("2023-12-01T00:00:00"))
    end)

    it("returns input on bad format", function()
      assert.are.equal("not-a-date", util.format_time("not-a-date"))
    end)

    it("returns input for empty string", function()
      assert.are.equal("", util.format_time(""))
    end)
  end)

  describe("review_icon", function()
    it("returns approved icon", function()
      local icons = config.get().icons
      assert.are.equal(icons.approved, util.review_icon("APPROVED"))
    end)

    it("returns changes_requested icon", function()
      local icons = config.get().icons
      assert.are.equal(icons.changes_requested, util.review_icon("CHANGES_REQUESTED"))
    end)

    it("returns review_required icon", function()
      local icons = config.get().icons
      assert.are.equal(icons.review_required, util.review_icon("REVIEW_REQUIRED"))
    end)

    it("returns empty string for nil", function()
      assert.are.equal("", util.review_icon(nil))
    end)

    it("returns empty string for empty string", function()
      assert.are.equal("", util.review_icon(""))
    end)

    it("returns empty string for unknown decision", function()
      assert.are.equal("", util.review_icon("UNKNOWN"))
    end)
  end)

  describe("build_thread_context", function()
    it("builds context from single comment", function()
      local comments = {
        { author = "alice", body = "looks good" },
      }
      local result = util.build_thread_context(comments)
      -- gmatch("[^\n]*") produces trailing empty match
      assert.are.same({
        "@alice:",
        "  looks good",
        "  ",
      }, result)
    end)

    it("builds context from multiple comments with separator", function()
      local comments = {
        { author = "alice", body = "first" },
        { author = "bob", body = "second" },
      }
      local result = util.build_thread_context(comments)
      assert.are.same({
        "@alice:",
        "  first",
        "  ",
        "",
        "@bob:",
        "  second",
        "  ",
      }, result)
    end)

    it("handles multiline body", function()
      local comments = {
        { author = "alice", body = "line1\nline2" },
      }
      local result = util.build_thread_context(comments)
      assert.are.same({
        "@alice:",
        "  line1",
        "  ",
        "  line2",
        "  ",
      }, result)
    end)

    it("handles empty body", function()
      local comments = {
        { author = "alice", body = "" },
      }
      local result = util.build_thread_context(comments)
      assert.are.same({
        "@alice:",
        "  ",
      }, result)
    end)

    it("returns empty table for empty comments", function()
      assert.are.same({}, util.build_thread_context({}))
    end)
  end)

  describe("git_show_lines", function()
    it("returns lines from successful git show", function()
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        assert.are.equal("git", cmd[1])
        assert.are.equal("show", cmd[2])
        return {
          wait = function()
            return { code = 0, stdout = "line 1\nline 2\nline 3\n" }
          end,
        }
      end

      local lines = util.git_show_lines("main:file.lua", "/tmp/repo")
      vim.system = orig_system

      assert.are.equal(3, #lines)
      assert.are.equal("line 1", lines[1])
      assert.are.equal("line 3", lines[3])
    end)

    it("returns empty table on failure", function()
      local orig_system = vim.system
      vim.system = function()
        return { wait = function() return { code = 128, stderr = "fatal" } end }
      end

      local lines = util.git_show_lines("main:missing.lua", "/tmp")
      vim.system = orig_system

      assert.are.same({}, lines)
    end)

    it("returns empty table when stdout is nil", function()
      local orig_system = vim.system
      vim.system = function()
        return { wait = function() return { code = 0, stdout = nil } end }
      end

      local lines = util.git_show_lines("main:file.lua", "/tmp")
      vim.system = orig_system

      assert.are.same({}, lines)
    end)

    it("strips trailing blank line", function()
      local orig_system = vim.system
      vim.system = function()
        return { wait = function() return { code = 0, stdout = "content\n" } end }
      end

      local lines = util.git_show_lines("ref:f", "/tmp")
      vim.system = orig_system

      assert.are.equal(1, #lines)
      assert.are.equal("content", lines[1])
    end)
  end)

  describe("git_merge_base", function()
    it("returns sha on success with origin/<ref>", function()
      local calls = {}
      local orig_system = vim.system
      vim.system = function(cmd)
        table.insert(calls, cmd)
        return {
          wait = function()
            return { code = 0, stdout = "abcdef1234567890\n" }
          end,
        }
      end

      local sha = util.git_merge_base("main", "/tmp/repo")
      vim.system = orig_system

      assert.are.equal("abcdef1234567890", sha)
      -- First try is origin/<ref>; fallback should not run on success
      assert.are.equal(1, #calls)
      assert.are.same({ "git", "merge-base", "origin/main", "HEAD" }, calls[1])
    end)

    it("falls back to plain ref when origin/<ref> fails", function()
      local calls = {}
      local orig_system = vim.system
      vim.system = function(cmd)
        table.insert(calls, cmd)
        local attempt = #calls
        return {
          wait = function()
            if attempt == 1 then
              return { code = 128, stderr = "unknown ref" }
            end
            return { code = 0, stdout = "deadbeef\n" }
          end,
        }
      end

      local sha = util.git_merge_base("feature", "/tmp/repo")
      vim.system = orig_system

      assert.are.equal("deadbeef", sha)
      assert.are.equal(2, #calls)
      assert.are.same({ "git", "merge-base", "origin/feature", "HEAD" }, calls[1])
      assert.are.same({ "git", "merge-base", "feature", "HEAD" }, calls[2])
    end)

    it("returns nil when both attempts fail", function()
      local orig_system = vim.system
      vim.system = function()
        return { wait = function() return { code = 128, stderr = "no" } end }
      end

      local sha = util.git_merge_base("nope", "/tmp/repo")
      vim.system = orig_system

      assert.is_nil(sha)
    end)

    it("treats empty stdout as failure and falls back", function()
      local calls = {}
      local orig_system = vim.system
      vim.system = function(cmd)
        table.insert(calls, cmd)
        local attempt = #calls
        return {
          wait = function()
            if attempt == 1 then
              return { code = 0, stdout = "\n" }
            end
            return { code = 0, stdout = "cafebabe\n" }
          end,
        }
      end

      local sha = util.git_merge_base("main", "/tmp/repo")
      vim.system = orig_system

      assert.are.equal("cafebabe", sha)
      assert.are.equal(2, #calls)
    end)
  end)

  describe("find_jj_root", function()
    local tmpdir
    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/.jj", "p")
      vim.fn.mkdir(tmpdir .. "/nested/deep", "p")
    end)
    after_each(function()
      vim.fn.delete(tmpdir, "rf")
    end)

    it("returns the directory containing .jj", function()
      assert.are.equal(tmpdir, util.find_jj_root(tmpdir))
    end)

    it("walks up from a nested subdirectory", function()
      assert.are.equal(tmpdir, util.find_jj_root(tmpdir .. "/nested/deep"))
    end)

    it("returns nil outside any jj repo", function()
      local outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      assert.is_nil(util.find_jj_root(outside))
      vim.fn.delete(outside, "rf")
    end)
  end)

  describe("jj_git_import_async", function()
    it("invokes jj git import with cwd and reports success", function()
      local captured
      local orig_system = vim.system
      vim.system = function(cmd, opts, cb)
        captured = { cmd = cmd, opts = opts }
        cb({ code = 0, stdout = "", stderr = "" })
        return nil
      end

      local done, err
      util.jj_git_import_async("/fake/root", function(e)
        err = e
        done = true
      end)
      vim.wait(100, function() return done end)
      vim.system = orig_system

      assert.is_true(done)
      assert.is_nil(err)
      assert.are.same({ "jj", "git", "import" }, captured.cmd)
      assert.are.equal("/fake/root", captured.opts.cwd)
    end)

    it("surfaces stderr on failure", function()
      local orig_system = vim.system
      vim.system = function(cmd, opts, cb)
        cb({ code = 1, stdout = "", stderr = "not a jj repo\n" })
        return nil
      end

      local done, err
      util.jj_git_import_async("/fake/root", function(e)
        err = e
        done = true
      end)
      vim.wait(100, function() return done end)
      vim.system = orig_system

      assert.is_true(done)
      assert.is_truthy(err and err:find("not a jj repo"))
    end)
  end)

  describe("ignore_whitespace toggle", function()
    local saved_diffopt
    local saved_vim_diff

    before_each(function()
      saved_diffopt = vim.o.diffopt
      saved_vim_diff = vim.diff
    end)

    after_each(function()
      -- Restore even if a test forgot
      if util.ignore_whitespace_active() then
        util.disable_ignore_whitespace()
      end
      vim.o.diffopt = saved_diffopt
      vim.diff = saved_vim_diff
    end)

    it("starts inactive", function()
      assert.is_false(util.ignore_whitespace_active())
    end)

    it("appends iwhiteall and iblank to diffopt on enable", function()
      vim.o.diffopt = "internal,filler,closeoff"
      util.enable_ignore_whitespace()
      assert.is_not_nil(vim.o.diffopt:match("iwhiteall"))
      assert.is_not_nil(vim.o.diffopt:match("iblank"))
      assert.is_true(util.ignore_whitespace_active())
    end)

    it("does not duplicate entries when already present", function()
      vim.o.diffopt = "internal,iwhiteall,iblank"
      util.enable_ignore_whitespace()
      local count = 0
      for _ in vim.o.diffopt:gmatch("iwhiteall") do count = count + 1 end
      assert.are.equal(1, count)
    end)

    it("restores diffopt on disable", function()
      vim.o.diffopt = "internal,filler,closeoff"
      util.enable_ignore_whitespace()
      util.disable_ignore_whitespace()
      assert.are.equal("internal,filler,closeoff", vim.o.diffopt)
      assert.is_false(util.ignore_whitespace_active())
    end)

    it("enable is idempotent", function()
      vim.o.diffopt = "internal,filler"
      util.enable_ignore_whitespace()
      local snap = vim.o.diffopt
      util.enable_ignore_whitespace()
      assert.are.equal(snap, vim.o.diffopt)
      util.disable_ignore_whitespace()
      assert.are.equal("internal,filler", vim.o.diffopt)
    end)

    it("disable is a no-op when not active", function()
      vim.o.diffopt = "internal,filler"
      util.disable_ignore_whitespace()
      assert.are.equal("internal,filler", vim.o.diffopt)
    end)

    it("wraps vim.diff to inject ignore_whitespace while active", function()
      local captured_opts
      vim.diff = function(a, b, opts)
        captured_opts = opts
        return {}
      end
      util.enable_ignore_whitespace()
      vim.diff("x", "y", { algorithm = "histogram" })
      assert.is_true(captured_opts.ignore_whitespace)
      assert.are.equal("histogram", captured_opts.algorithm)

      util.disable_ignore_whitespace()
      captured_opts = nil
      vim.diff("x", "y", { algorithm = "histogram" })
      assert.is_nil(captured_opts.ignore_whitespace)
    end)
  end)

  describe("linematch suppression", function()
    local saved_diffopt
    local saved_vim_diff

    before_each(function()
      saved_diffopt = vim.o.diffopt
      saved_vim_diff = vim.diff
    end)

    after_each(function()
      if util.linematch_suppressed() then util.restore_linematch() end
      if util.ignore_whitespace_active() then util.disable_ignore_whitespace() end
      vim.o.diffopt = saved_diffopt
      vim.diff = saved_vim_diff
    end)

    it("removes linematch:N from diffopt", function()
      vim.o.diffopt = "internal,filler,linematch:40"
      util.suppress_linematch()
      assert.is_nil(vim.o.diffopt:match("linematch:"))
      assert.is_true(util.linematch_suppressed())
    end)

    it("restores the original linematch entry verbatim", function()
      vim.o.diffopt = "internal,filler,linematch:60"
      util.suppress_linematch()
      util.restore_linematch()
      assert.is_not_nil(vim.o.diffopt:match("linematch:60"))
      assert.is_false(util.linematch_suppressed())
    end)

    it("handles diffopt with no linematch entry", function()
      vim.o.diffopt = "internal,filler"
      util.suppress_linematch()
      util.restore_linematch()
      assert.are.equal("internal,filler", vim.o.diffopt)
    end)

    it("injects linematch = 0 into the vim.diff wrapper while active", function()
      local captured
      vim.diff = function(a, b, opts)
        captured = opts
        return {}
      end
      util.suppress_linematch()
      vim.diff("x", "y", { algorithm = "histogram", linematch = 60 })
      assert.are.equal(0, captured.linematch)
      assert.are.equal("histogram", captured.algorithm)
    end)

    it("composes with ignore_whitespace without losing state on disable", function()
      vim.o.diffopt = "internal,filler,linematch:40"
      util.enable_ignore_whitespace()
      util.suppress_linematch()
      assert.is_true(util.ignore_whitespace_active())
      assert.is_true(util.linematch_suppressed())
      -- Disable whitespace but keep linematch suppressed.
      util.disable_ignore_whitespace()
      assert.is_false(util.ignore_whitespace_active())
      assert.is_true(util.linematch_suppressed())
      assert.is_nil(vim.o.diffopt:match("iwhiteall"))
      assert.is_nil(vim.o.diffopt:match("linematch:"))
      util.restore_linematch()
      assert.is_not_nil(vim.o.diffopt:match("linematch:40"))
    end)
  end)

  describe("create_scratch_buf", function()
    it("creates a buffer with correct properties", function()
      local buf = util.create_scratch_buf("test://buf", { "line 1", "line 2" }, "test.lua")

      assert.are.equal("nofile", vim.bo[buf].buftype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.are.equal("wipe", vim.bo[buf].bufhidden)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.same({ "line 1", "line 2" }, lines)

      assert.are.equal("lua", vim.bo[buf].filetype)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("handles unknown file type", function()
      local buf = util.create_scratch_buf("test://x", { "data" }, "file.xyz_unknown_ext")
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
