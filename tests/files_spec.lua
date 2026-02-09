---@module 'luassert'

local config = require("gh-review.config")
local files = require("gh-review.ui.files")

describe("files", function()
  before_each(function()
    config.setup()
  end)

  describe("status_display", function()
    it("returns correct icon and hl for added", function()
      local icon, hl = files._status_display("added")
      assert.are.equal("A", icon)
      assert.are.equal("GHReviewFileAdded", hl)
    end)

    it("returns correct icon and hl for modified", function()
      local icon, hl = files._status_display("modified")
      assert.are.equal("M", icon)
      assert.are.equal("GHReviewFileModified", hl)
    end)

    it("returns correct icon and hl for deleted", function()
      local icon, hl = files._status_display("deleted")
      assert.are.equal("D", icon)
      assert.are.equal("GHReviewFileDeleted", hl)
    end)

    it("returns correct icon and hl for renamed", function()
      local icon, hl = files._status_display("renamed")
      assert.are.equal("R", icon)
      assert.are.equal("GHReviewFileRenamed", hl)
    end)

    it("returns fallback for unknown status", function()
      local icon, hl = files._status_display("copied")
      assert.are.equal("?", icon)
      assert.are.equal("Normal", hl)
    end)

    it("respects custom icons from config", function()
      config.setup({ icons = { added = "+" } })
      local icon, hl = files._status_display("added")
      assert.are.equal("+", icon)
      assert.are.equal("GHReviewFileAdded", hl)
    end)
  end)

  describe("build_items", function()
    local cwd = "/tmp/repo"

    it("returns empty items for empty file list", function()
      local items = files._build_items({}, cwd)
      assert.are.same({}, items)
    end)

    it("builds single file at root level (no directory node)", function()
      local file_list = {
        { path = "init.lua", status = "added", additions = 10, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      assert.are.equal(1, #items)
      assert.are.equal("init.lua", items[1].text)
      assert.is_false(items[1]._is_dir)
      assert.are.equal("/tmp/repo/init.lua", items[1].file)
      assert.is_nil(items[1].parent)
    end)

    it("builds nested directory + file items", function()
      local file_list = {
        { path = "src/main.lua", status = "modified", additions = 5, deletions = 2 },
      }
      local items = files._build_items(file_list, cwd)
      assert.are.equal(2, #items)
      -- Directory first
      assert.is_true(items[1]._is_dir)
      assert.are.equal("src", items[1]._name)
      -- File second
      assert.is_false(items[2]._is_dir)
      assert.are.equal("main.lua", items[2]._name)
      assert.are.equal(items[1], items[2].parent)
    end)

    it("collapses single-child directory chains", function()
      local file_list = {
        { path = "a/b/c/file.lua", status = "added", additions = 1, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      assert.are.equal(2, #items)
      -- Collapsed directory
      assert.is_true(items[1]._is_dir)
      assert.are.equal("a/b/c", items[1]._name)
      -- File
      assert.is_false(items[2]._is_dir)
      assert.are.equal("file.lua", items[2]._name)
    end)

    it("sorts directories first, then files alphabetically", function()
      local file_list = {
        { path = "zebra.lua", status = "added", additions = 1, deletions = 0 },
        { path = "src/a.lua", status = "modified", additions = 1, deletions = 1 },
        { path = "alpha.lua", status = "deleted", additions = 0, deletions = 5 },
      }
      local items = files._build_items(file_list, cwd)
      -- src/ dir first, then alpha.lua, then zebra.lua
      assert.are.equal(4, #items)
      assert.is_true(items[1]._is_dir)
      assert.are.equal("src", items[1]._name)
      assert.are.equal("a.lua", items[2]._name)
      assert.are.equal("alpha.lua", items[3]._name)
      assert.are.equal("zebra.lua", items[4]._name)
    end)

    it("handles renamed file with old_path", function()
      local file_list = {
        { path = "new_name.lua", status = "renamed", old_path = "old_name.lua", additions = 0, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      assert.are.equal(1, #items)
      assert.are.equal("renamed", items[1]._file_data.status)
      assert.are.equal("old_name.lua", items[1]._file_data.old_path)
    end)

    it("sets _icon and _hl correctly for file items", function()
      local file_list = {
        { path = "a.lua", status = "added", additions = 1, deletions = 0 },
        { path = "b.lua", status = "modified", additions = 1, deletions = 1 },
        { path = "c.lua", status = "deleted", additions = 0, deletions = 5 },
        { path = "d.lua", status = "renamed", old_path = "e.lua", additions = 0, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      -- All at root, sorted alphabetically: a.lua, b.lua, c.lua, d.lua
      assert.are.equal("A", items[1]._icon)
      assert.are.equal("GHReviewFileAdded", items[1]._hl)
      assert.are.equal("M", items[2]._icon)
      assert.are.equal("GHReviewFileModified", items[2]._hl)
      assert.are.equal("D", items[3]._icon)
      assert.are.equal("GHReviewFileDeleted", items[3]._hl)
      assert.are.equal("R", items[4]._icon)
      assert.are.equal("GHReviewFileRenamed", items[4]._hl)
    end)

    it("directory items have no _icon or _hl", function()
      local file_list = {
        { path = "src/main.lua", status = "modified", additions = 1, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      assert.is_nil(items[1]._icon)
      assert.is_nil(items[1]._hl)
    end)

    it("files sharing a common deep prefix collapse correctly", function()
      local file_list = {
        { path = "a/b/c/x.lua", status = "added", additions = 1, deletions = 0 },
        { path = "a/b/c/y.lua", status = "modified", additions = 2, deletions = 1 },
      }
      local items = files._build_items(file_list, cwd)
      -- Should have: dir "a/b/c", then x.lua, y.lua
      assert.are.equal(3, #items)
      assert.is_true(items[1]._is_dir)
      assert.are.equal("a/b/c", items[1]._name)
      assert.are.equal("x.lua", items[2]._name)
      assert.are.equal("y.lua", items[3]._name)
    end)

    it("sets file path correctly for nested files", function()
      local file_list = {
        { path = "lua/gh-review/init.lua", status = "modified", additions = 3, deletions = 1 },
      }
      local items = files._build_items(file_list, cwd)
      local file_item = items[#items]
      assert.are.equal("/tmp/repo/lua/gh-review/init.lua", file_item.file)
    end)

    it("sets last correctly on items", function()
      local file_list = {
        { path = "a.lua", status = "added", additions = 1, deletions = 0 },
        { path = "b.lua", status = "modified", additions = 1, deletions = 0 },
      }
      local items = files._build_items(file_list, cwd)
      assert.is_false(items[1].last)
      assert.is_true(items[2].last)
    end)
  end)
end)
