---@module 'luassert'

local state = require("gh-review.state")
local config = require("gh-review.config")

describe("commits", function()
  local commits_ui
  local picker_config

  before_each(function()
    config.setup()
    state.clear()
    picker_config = nil

    -- Stub snacks.nvim
    package.loaded["snacks"] = {
      picker = {
        get = function() return {} end,
        pick = function(opts) picker_config = opts end,
      },
    }

    package.loaded["gh-review.ui.commits"] = nil
    commits_ui = require("gh-review.ui.commits")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
  end)

  describe("toggle", function()
    it("calls show when no picker is open", function()
      state.set_pr({
        number = 1, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first", author = "dev", date = "2024-01-01" },
      })

      commits_ui.toggle()

      assert.is_not_nil(picker_config)
      assert.are.equal("gh_review_commits", picker_config.source)
    end)

    it("closes picker when already open", function()
      local closed = false
      package.loaded["snacks"] = {
        picker = {
          get = function()
            return { { close = function() closed = true end } }
          end,
          pick = function(opts) picker_config = opts end,
        },
      }
      package.loaded["gh-review.ui.commits"] = nil
      commits_ui = require("gh-review.ui.commits")

      commits_ui.toggle()

      assert.is_true(closed)
      assert.is_nil(picker_config) -- show() not called
    end)
  end)

  describe("show", function()
    it("notifies when no commits", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      commits_ui.show()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("no commits"))
    end)

    it("notifies when snacks not available", function()
      package.loaded["snacks"] = nil
      package.loaded["gh-review.ui.commits"] = nil
      commits_ui = require("gh-review.ui.commits")

      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first", author = "dev", date = "2024-01-01" },
      })

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      commits_ui.show()

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("snacks.nvim required"))
    end)

    it("builds items from commits", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first commit", author = "dev1", date = "2024-01-01" },
        { sha = "def", oid = "deffull", message = "second commit", author = "dev2", date = "2024-01-02" },
      })

      commits_ui.show()

      assert.are.equal(2, #picker_config.items)
      assert.is_truthy(picker_config.items[1].text:find("abc"))
      assert.is_truthy(picker_config.items[1].text:find("first commit"))
      assert.is_falsy(picker_config.items[1]._is_active)
    end)

    it("marks active commit in items", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first", author = "dev", date = "" },
        { sha = "def", oid = "deffull", message = "second", author = "dev", date = "" },
      })
      state.set_active_commit({ sha = "abc", oid = "abcfull", message = "first", author = "dev" })

      commits_ui.show()

      assert.is_true(picker_config.items[1]._is_active)
      assert.is_false(picker_config.items[2]._is_active)
    end)

    it("format function produces expected output", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "fix bug", author = "dev", date = "2024-01-15T10:00:00Z" },
      })

      commits_ui.show()

      local item = picker_config.items[1]
      local formatted = picker_config.format(item)
      assert.is_table(formatted)
      -- First element is the prefix
      assert.are.equal("  ", formatted[1][1])
      -- Second is sha
      assert.are.equal("abc", formatted[2][1])
    end)

    it("format function highlights the whole entry of the active commit", function()
      local picker_util = require("gh-review.ui.picker_util")
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "fix", author = "dev", date = "" },
        { sha = "def", oid = "deffull", message = "other", author = "dev", date = "" },
      })
      state.set_active_commit({ sha = "abc", oid = "abcfull", message = "fix", author = "dev" })

      commits_ui.show()

      local formatted = picker_config.format(picker_config.items[1])
      assert.are.equal("> ", formatted[1][1])
      assert.are.equal(picker_util.ACTIVE, formatted[1][2])
      -- sha, message and metadata all carry the highlight, not just the marker
      assert.are.equal(picker_util.ACTIVE_ENTRY, formatted[2][2])
      assert.are.equal(picker_util.ACTIVE_ENTRY, formatted[3][2])
      assert.are.equal(picker_util.ACTIVE_ENTRY, formatted[4][2])

      -- Other entries keep their ordinary highlights
      local other = picker_config.format(picker_config.items[2])
      assert.are.equal("Identifier", other[2][2])
      assert.is_nil(other[3][2])
      assert.are.equal("Comment", other[4][2])
    end)

    it("opens on the active commit", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first", author = "dev", date = "" },
        { sha = "def", oid = "deffull", message = "second", author = "dev", date = "" },
      })
      state.set_active_commit({ sha = "def", oid = "deffull", message = "second", author = "dev" })

      commits_ui.show()

      local viewed
      picker_config.on_show({
        items = function() return picker_config.items end,
        list = { view = function(_, idx) viewed = idx end },
      })

      assert.are.equal(2, viewed)
    end)

    it("leaves the cursor at the top when no commit is selected", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "first", author = "dev", date = "" },
      })

      commits_ui.show()

      local viewed
      picker_config.on_show({
        items = function() return picker_config.items end,
        list = { view = function(_, idx) viewed = idx end },
      })

      assert.is_nil(viewed)
    end)
  end)
end)
