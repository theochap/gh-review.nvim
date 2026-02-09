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

    it("format function shows > prefix for active commit", function()
      state.set_commits({
        { sha = "abc", oid = "abcfull", message = "fix", author = "dev", date = "" },
      })
      state.set_active_commit({ sha = "abc", oid = "abcfull", message = "fix", author = "dev" })

      commits_ui.show()

      local item = picker_config.items[1]
      local formatted = picker_config.format(item)
      assert.are.equal("> ", formatted[1][1])
      assert.are.equal("CurSearch", formatted[1][2])
    end)
  end)
end)
