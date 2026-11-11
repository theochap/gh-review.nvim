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

  describe("display_order", function()
    --- Paths of `files.display_order(file_list)`, for terser assertions.
    ---@param file_list table[]
    ---@return string[]
    local function order(file_list)
      local paths = {}
      for _, f in ipairs(files.display_order(file_list)) do
        table.insert(paths, f.path)
      end
      return paths
    end

    it("returns an empty list for no files", function()
      assert.are.same({}, order({}))
    end)

    it("lists directories before files, matching the sidebar", function()
      local file_list = {
        { path = "README.md", status = "modified" },
        { path = "lua/init.lua", status = "modified" },
        { path = "lua/ui/files.lua", status = "added" },
      }
      assert.are.same({ "lua/ui/files.lua", "lua/init.lua", "README.md" }, order(file_list))
    end)

    it("is independent of the order files came in", function()
      local file_list = {
        { path = "src/b.lua", status = "modified" },
        { path = "docs/a.md", status = "added" },
        { path = "src/a.lua", status = "modified" },
      }
      assert.are.same({ "docs/a.md", "src/a.lua", "src/b.lua" }, order(file_list))
    end)

    it("walks collapsed directory chains", function()
      local file_list = {
        { path = "top.lua", status = "modified" },
        { path = "a/b/c/y.lua", status = "added" },
        { path = "a/b/c/x.lua", status = "added" },
      }
      assert.are.same({ "a/b/c/x.lua", "a/b/c/y.lua", "top.lua" }, order(file_list))
    end)

    it("returns the same file tables it was given", function()
      local file = { path = "a.lua", status = "modified" }
      local ordered = files.display_order({ file })
      assert.are.equal(file, ordered[1])
    end)

    it("matches the file items the picker renders", function()
      local file_list = {
        { path = "z.lua", status = "modified" },
        { path = "pkg/deep/nested/one.lua", status = "added" },
        { path = "pkg/two.lua", status = "modified" },
        { path = "a.lua", status = "deleted" },
      }
      local from_items = {}
      for _, item in ipairs(files._build_items(file_list, "/tmp/repo")) do
        if not item._is_dir then table.insert(from_items, item._file_data.path) end
      end
      assert.are.same(from_items, order(file_list))
    end)
  end)

  describe("sync_selection / sync_current", function()
    local moved

    --- Stub snacks with a picker whose sorted index space is `iter_items`.
    --- `list.items` is set to something *different* on purpose: it is the raw
    --- item table, which stops matching the row numbering once the matcher's
    --- top-k results kick in, and must not be what we index by.
    ---@param iter_items table[]
    ---@param raw_items? table[]
    local function stub_picker(iter_items, raw_items)
      moved = nil
      local picker = {
        list = {
          items = raw_items or {},
          move = function(_, idx, absolute) moved = { idx = idx, absolute = absolute } end,
        },
      }
      function picker:iter()
        local i = 0
        return function()
          i = i + 1
          if iter_items[i] then return iter_items[i], i end
        end
      end
      package.loaded["snacks"] = { picker = { get = function() return { picker } end } }
    end

    local function item(rel_path)
      return { file = vim.fn.getcwd() .. "/" .. rel_path }
    end

    after_each(function()
      package.loaded["snacks"] = nil
    end)

    it("moves the cursor to the row holding the file", function()
      stub_picker({ item("src/a.lua"), item("src/b.lua"), item("src/c.lua") })

      files.sync_selection("src/b.lua")

      assert.are.same({ idx = 2, absolute = true }, moved)
    end)

    it("indexes the picker's sorted rows, not the raw item table", function()
      -- What the rows show, in order
      local iter_items = { item("src/b.lua"), item("src/a.lua") }
      -- What `list.items` happens to hold — reversed, as a filtered list would
      local raw_items = { item("src/a.lua"), item("src/b.lua") }
      stub_picker(iter_items, raw_items)

      files.sync_selection("src/a.lua")

      -- Row 2 is src/a.lua; indexing list.items would have said row 1
      assert.are.same({ idx = 2, absolute = true }, moved)
    end)

    it("does nothing when the file is not in the list", function()
      stub_picker({ item("src/a.lua") })

      files.sync_selection("src/absent.lua")

      assert.is_nil(moved)
    end)

    it("does nothing when the picker is closed", function()
      package.loaded["snacks"] = { picker = { get = function() return {} end } }

      files.sync_selection("src/a.lua")

      assert.is_nil(moved)
    end)

    it("stays silent when snacks is unavailable", function()
      -- Runs on every buffer switch, so it must not notify
      package.loaded["snacks"] = nil
      local orig_require = _G.require
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg) table.insert(notifications, msg) end

      files.sync_selection("src/a.lua")
      files.sync_current()

      vim.notify = orig_notify
      _G.require = orig_require
      assert.are.same({}, notifications)
    end)

    it("syncs to a working-tree buffer's path", function()
      stub_picker({ item("src/a.lua"), item("src/b.lua") })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/b.lua")

      files.sync_current(buf)

      assert.are.same({ idx = 2, absolute = true }, moved)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("syncs from the review's scratch buffers too", function()
      local names = {
        "ghreview://base/src/b.lua",
        "ghreview://commit/abc1234/src/b.lua",
        "ghreview://unified/src/b.lua",
      }
      for _, name in ipairs(names) do
        stub_picker({ item("src/a.lua"), item("src/b.lua") })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, name)

        files.sync_current(buf)

        assert.are.same({ idx = 2, absolute = true }, moved, name)
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("ignores buffers that are not PR files", function()
      stub_picker({ item("src/a.lua") })
      local unnamed = vim.api.nvim_create_buf(false, true)
      local outside = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(outside, "/somewhere/else/src/a.lua")

      files.sync_current(unnamed)
      assert.is_nil(moved)
      files.sync_current(outside)
      assert.is_nil(moved)

      vim.api.nvim_buf_delete(unnamed, { force = true })
      vim.api.nvim_buf_delete(outside, { force = true })
    end)
  end)

  describe("show", function()
    it("keeps an open sidebar instead of opening a second one", function()
      local state = require("gh-review.state")
      state.set_files({ { path = "a.lua", status = "modified" } })
      local opened = 0
      package.loaded["snacks"] = { picker = {
        pick = function() opened = opened + 1 end,
        get = function() return { {} } end,
      } }
      files.show()
      package.loaded["snacks"] = nil
      state.clear()
      assert.are.equal(0, opened)
    end)

    it("opens without focus when asked", function()
      local state = require("gh-review.state")
      state.set_files({ { path = "a.lua", status = "modified" } })
      local opts
      package.loaded["snacks"] = { picker = { pick = function(o) opts = o end, get = function() return {} end } }
      package.loaded["snacks.picker.format"] = { tree = function() return {} end }
      files.show({ focus = false })
      package.loaded["snacks"] = nil
      package.loaded["snacks.picker.format"] = nil
      state.clear()
      assert.is_false(opts.focus)
    end)
  end)

  describe("renames", function()
    local file = { path = "lua/new/b.lua", old_path = "lua/old/a.lua", status = "renamed" }

    it("labels the full path change, or file names only", function()
      assert.are.equal("lua/old/a.lua → lua/new/b.lua", files.rename_label(file, true))
      assert.are.equal("a.lua → b.lua", files.rename_label(file, false))
    end)

    it("shows the full change by default, and the toggle switches to file names", function()
      local state = require("gh-review.state")
      state.set_files({ file })
      local opts
      package.loaded["snacks"] = { picker = { pick = function(o) opts = o end, get = function() return {} end } }
      package.loaded["snacks.picker.format"] = { tree = function() return {} end }
      files._full_rename_paths = nil
      files.show()
      local leaf
      for _, item in ipairs(opts.items) do
        if not item._is_dir then leaf = item end
      end
      local function row() return table.concat(vim.tbl_map(function(c) return c[1] end, opts.format(leaf, {})), "") end
      assert.is_truthy(row():find("lua/old/a.lua → lua/new/b.lua", 1, true))
      assert.are.equal("gh_review_toggle_rename_paths", opts.win.list.keys["p"][1])
      opts.actions.gh_review_toggle_rename_paths({ list = { set_target = function() end, update = function() end, cursor = 1, top = 1 } })
      assert.is_truthy(row():find("a.lua → b.lua", 1, true))
      assert.is_nil(row():find("lua/old", 1, true))
      package.loaded["snacks"] = nil
      package.loaded["snacks.picker.format"] = nil
      files._full_rename_paths = nil
      state.clear()
    end)

    it("starts with file names when full_rename_paths is off", function()
      config.setup({ full_rename_paths = false })
      files._full_rename_paths = nil
      local state = require("gh-review.state")
      state.set_files({ file })
      local opts
      package.loaded["snacks"] = { picker = { pick = function(o) opts = o end, get = function() return {} end } }
      package.loaded["snacks.picker.format"] = { tree = function() return {} end }
      files.show()
      local leaf
      for _, item in ipairs(opts.items) do
        if not item._is_dir then leaf = item end
      end
      local row = table.concat(vim.tbl_map(function(c) return c[1] end, opts.format(leaf, {})), "")
      assert.is_truthy(row:find("a.lua → b.lua", 1, true))
      package.loaded["snacks"] = nil
      package.loaded["snacks.picker.format"] = nil
      files._full_rename_paths = nil
      state.clear()
    end)

    it("makes the old path searchable", function()
      local items = files._build_items({ file }, "/repo")
      local leaf
      for _, item in ipairs(items) do
        if not item._is_dir then leaf = item end
      end
      assert.is_truthy(leaf.text:find("lua/old/a.lua", 1, true))
    end)
  end)
end)
