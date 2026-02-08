---@module 'luassert'

local state = require("gh-review.state")

-- Stub trouble.item so tests work without the real trouble.nvim plugin
package.loaded["trouble.item"] = {
  new = function(data)
    return data
  end,
  add_id = function(items, keys)
    for i, item in ipairs(items) do
      item.id = i
    end
  end,
}

-- Force re-require of the source module with our stub in place
package.loaded["trouble.sources.gh_review"] = nil
local source = require("trouble.sources.gh_review")

describe("trouble source gh_review", function()
  before_each(function()
    state.clear()
  end)

  after_each(function()
    state.clear()
  end)

  describe("_get_thread", function()
    it("returns nil when node has no item", function()
      local self_mock = {
        at = function() return nil end,
      }
      assert.is_nil(source._get_thread(self_mock))
    end)

    it("returns nil when item has no thread", function()
      local self_mock = {
        at = function() return { item = { item = {} } } end,
      }
      assert.is_nil(source._get_thread(self_mock))
    end)

    it("returns thread from valid node", function()
      local thread = { id = "t1", path = "a.lua" }
      local self_mock = {
        at = function()
          return { item = { item = { thread = thread } } }
        end,
      }
      assert.are.same(thread, source._get_thread(self_mock))
    end)
  end)

  describe("config", function()
    it("defines gh_review mode", function()
      assert.is_not_nil(source.config.modes.gh_review)
    end)

    it("has cr, r, and t keymaps", function()
      local keys = source.config.modes.gh_review.keys
      assert.is_not_nil(keys["<cr>"])
      assert.is_not_nil(keys["r"])
      assert.is_not_nil(keys["t"])
    end)

    it("has wrap and linebreak window options", function()
      local win = source.config.modes.gh_review.win
      assert.is_not_nil(win)
      assert.is_not_nil(win.wo)
      assert.is_true(win.wo.wrap)
      assert.is_true(win.wo.linebreak)
    end)
  end)

  describe("get", function()
    it("returns empty items when no active review", function()
      local items
      source.get(function(result) items = result end)
      assert.are.same({}, items)
    end)

    it("returns items for each thread when active", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/a.lua",
          line = 5,
          mapped_line = 5,
          is_resolved = false,
          comments = { { author = "alice", body = "Check this" } },
        },
        {
          id = "t2",
          path = "src/b.lua",
          line = 10,
          mapped_line = 10,
          is_resolved = true,
          comments = { { author = "bob", body = "Done" } },
        },
      })

      local items
      source.get(function(result) items = result end)
      assert.are.equal(2, #items)
    end)

    it("includes [resolved] prefix for resolved threads", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/a.lua",
          line = 5,
          mapped_line = 5,
          is_resolved = true,
          comments = { { author = "alice", body = "LGTM" } },
        },
      })

      local items
      source.get(function(result) items = result end)
      assert.is_truthy(items[1].message:find("^%[resolved%]"))
    end)

    it("includes reply count", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/a.lua",
          line = 5,
          mapped_line = 5,
          is_resolved = false,
          comments = {
            { author = "alice", body = "First" },
            { author = "bob", body = "Reply 1" },
            { author = "carol", body = "Reply 2" },
          },
        },
      })

      local items
      source.get(function(result) items = result end)
      assert.is_truthy(items[1].message:find("%[%+2 replies%]"))
    end)

    it("stores thread in item data", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      local thread = {
        id = "t1",
        path = "src/a.lua",
        line = 5,
        mapped_line = 5,
        is_resolved = false,
        comments = { { author = "alice", body = "Hi" } },
      }
      state.set_threads({ thread })

      local items
      source.get(function(result) items = result end)
      assert.are.equal("t1", items[1].item.thread.id)
    end)
  end)
end)
