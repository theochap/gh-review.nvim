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
