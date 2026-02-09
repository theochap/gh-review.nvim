---@module 'luassert'

local state = require("gh-review.state")
local config = require("gh-review.config")

describe("diff_review", function()
  local diff_review, util

  before_each(function()
    config.setup()
    state.clear()

    -- Stub diagnostics (required by diff_review.open for commit buffers)
    package.loaded["gh-review.ui.diagnostics"] = {
      setup = function() end,
      refresh_buf = function() end,
      refresh_all = function() end,
      clear_all = function() end,
    }

    package.loaded["gh-review.ui.diff_review"] = nil
    diff_review = require("gh-review.ui.diff_review")
    util = require("gh-review.util")
  end)

  after_each(function()
    pcall(diff_review.close)
    -- Clean up any leftover ghreview:// scratch buffers from commit diff tests
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name:find("^ghreview://") then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end
    package.loaded["gh-review.ui.diagnostics"] = nil
  end)

  describe("initial state", function()
    it("is_diff_active returns false", function()
      assert.is_false(diff_review.is_diff_active())
    end)

    it("get_work_win returns nil", function()
      assert.is_nil(diff_review.get_work_win())
    end)

    it("get_file_path returns nil", function()
      assert.is_nil(diff_review.get_file_path())
    end)
  end)

  describe("close", function()
    it("does not error when nothing is open", function()
      assert.has_no.errors(function()
        diff_review.close()
      end)
    end)
  end)

  describe("open", function()
    it("returns early when no PR is active", function()
      diff_review.open("some/file.lua")
      assert.is_false(diff_review.is_diff_active())
    end)

    it("opens diff split for a file with active PR", function()
      state.set_pr({
        number = 42, title = "Test", author = "dev", base_ref = "main",
        head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
      })

      local orig_git_show = util.git_show_lines
      util.git_show_lines = function() return { "base line 1", "base line 2" } end

      local cwd = vim.fn.getcwd()
      local test_file = cwd .. "/test_diff_review_temp.lua"
      vim.fn.writefile({ "work line 1", "work line 2" }, test_file)

      diff_review.open("test_diff_review_temp.lua")

      assert.is_true(diff_review.is_diff_active())
      assert.is_not_nil(diff_review.get_work_win())

      diff_review.close()
      util.git_show_lines = orig_git_show
      vim.fn.delete(test_file)

      assert.is_false(diff_review.is_diff_active())
    end)

    it("opens commit diff with scratch buffers", function()
      state.set_pr({
        number = 42, title = "Test", author = "dev", base_ref = "main",
        head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
      })
      state.set_active_commit({
        sha = "abc1234", oid = "abc1234full", message = "test commit", author = "dev",
      })

      local orig_git_show = util.git_show_lines
      util.git_show_lines = function(ref)
        if ref:find("~1:") then return { "parent line 1" }
        else return { "commit line 1" } end
      end

      diff_review.open("src/file.lua")

      assert.is_true(diff_review.is_diff_active())

      diff_review.close()
      util.git_show_lines = orig_git_show
    end)

    it("repositions cursor when same file reopened", function()
      state.set_pr({
        number = 42, title = "Test", author = "dev", base_ref = "main",
        head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
      })
      state.set_active_commit({
        sha = "abc1234", oid = "abc1234full", message = "test", author = "dev",
      })

      local orig_git_show = util.git_show_lines
      util.git_show_lines = function()
        return { "line 1", "line 2", "line 3", "line 4", "line 5" }
      end

      diff_review.open("src/file.lua")
      assert.is_true(diff_review.is_diff_active())

      -- Open same file again with target line
      diff_review.open("src/file.lua", 3)
      assert.is_true(diff_review.is_diff_active())

      diff_review.close()
      util.git_show_lines = orig_git_show
    end)

    it("get_file_path returns path only when in a diff window", function()
      state.set_pr({
        number = 42, title = "Test", author = "dev", base_ref = "main",
        head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
      })
      state.set_active_commit({
        sha = "abc", oid = "abcdef", message = "test", author = "dev",
      })

      local orig_git_show = util.git_show_lines
      util.git_show_lines = function() return { "line 1" } end

      diff_review.open("src/test.lua")

      -- Should return path when in a diff window
      local path = diff_review.get_file_path()
      assert.are.equal("src/test.lua", path)

      -- Create a new window outside the diff
      vim.cmd("botright new")
      local outside_path = diff_review.get_file_path()
      assert.is_nil(outside_path)
      vim.cmd("close")

      diff_review.close()
      util.git_show_lines = orig_git_show
    end)
  end)
end)
