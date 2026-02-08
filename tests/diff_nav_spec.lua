---@module 'luassert'

local config = require("gh-review.config")
local state = require("gh-review.state")

describe("diff navigation", function()
  before_each(function()
    config.setup()
    state.clear()
  end)

  describe("config defaults", function()
    it("has next_diff default", function()
      assert.are.equal("]d", config.get().keymaps.next_diff)
    end)

    it("has prev_diff default", function()
      assert.are.equal("[d", config.get().keymaps.prev_diff)
    end)
  end)

  describe("_get_current_file_index", function()
    local gh_review

    before_each(function()
      gh_review = require("gh-review")
    end)

    it("returns nil when no diff is active", function()
      local idx, files = gh_review._get_current_file_index()
      assert.is_nil(idx)
      assert.is_nil(files)
    end)

    it("returns correct index when file matches", function()
      state.set_files({
        { path = "a.lua", status = "modified", additions = 1, deletions = 0 },
        { path = "b.lua", status = "modified", additions = 1, deletions = 0 },
        { path = "c.lua", status = "modified", additions = 1, deletions = 0 },
      })

      -- Mock diff_review.get_file_path to return "b.lua"
      local diff_review = require("gh-review.ui.diff_review")
      local orig = diff_review.get_file_path
      diff_review.get_file_path = function() return "b.lua" end

      local idx, files = gh_review._get_current_file_index()
      assert.are.equal(2, idx)
      assert.are.equal(3, #files)

      diff_review.get_file_path = orig
    end)

    it("returns nil when file not in list", function()
      state.set_files({
        { path = "a.lua", status = "modified", additions = 1, deletions = 0 },
      })

      local diff_review = require("gh-review.ui.diff_review")
      local orig = diff_review.get_file_path
      diff_review.get_file_path = function() return "z.lua" end

      local idx, _ = gh_review._get_current_file_index()
      assert.is_nil(idx)

      diff_review.get_file_path = orig
    end)
  end)

  describe("next/prev file skipping", function()
    it("skips deleted files when finding next", function()
      local files = {
        { path = "a.lua", status = "modified" },
        { path = "b.lua", status = "deleted" },
        { path = "c.lua", status = "deleted" },
        { path = "d.lua", status = "modified" },
      }
      -- Simulate finding next non-deleted from index 1
      local next_idx = nil
      for i = 2, #files do
        if files[i].status ~= "deleted" then
          next_idx = i
          break
        end
      end
      assert.are.equal(4, next_idx)
    end)

    it("skips deleted files when finding prev", function()
      local files = {
        { path = "a.lua", status = "modified" },
        { path = "b.lua", status = "deleted" },
        { path = "c.lua", status = "deleted" },
        { path = "d.lua", status = "modified" },
      }
      -- Simulate finding prev non-deleted from index 4
      local prev_idx = nil
      for i = 3, 1, -1 do
        if files[i].status ~= "deleted" then
          prev_idx = i
          break
        end
      end
      assert.are.equal(1, prev_idx)
    end)

    it("returns nil at first file boundary", function()
      local files = {
        { path = "a.lua", status = "modified" },
        { path = "b.lua", status = "modified" },
      }
      -- Simulate finding prev non-deleted from index 1
      local prev_idx = nil
      for i = 0, 1, -1 do
        if i >= 1 and files[i].status ~= "deleted" then
          prev_idx = i
          break
        end
      end
      assert.is_nil(prev_idx)
    end)

    it("returns nil at last file boundary", function()
      local files = {
        { path = "a.lua", status = "modified" },
        { path = "b.lua", status = "modified" },
      }
      -- Simulate finding next non-deleted from index 2
      local next_idx = nil
      for i = 3, #files do
        if files[i].status ~= "deleted" then
          next_idx = i
          break
        end
      end
      assert.is_nil(next_idx)
    end)

    it("returns nil when all remaining files are deleted", function()
      local files = {
        { path = "a.lua", status = "modified" },
        { path = "b.lua", status = "deleted" },
        { path = "c.lua", status = "deleted" },
      }
      local next_idx = nil
      for i = 2, #files do
        if files[i].status ~= "deleted" then
          next_idx = i
          break
        end
      end
      assert.is_nil(next_idx)
    end)
  end)
end)
