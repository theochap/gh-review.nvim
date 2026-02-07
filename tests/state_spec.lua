---@module 'luassert'

local state = require("gh-review.state")

describe("state", function()
  before_each(function()
    state.clear()
  end)

  describe("is_active", function()
    it("is false initially", function()
      assert.is_false(state.is_active())
    end)

    it("becomes true after set_pr", function()
      state.set_pr({ number = 1, title = "test" })
      assert.is_true(state.is_active())
    end)

    it("becomes false after clear", function()
      state.set_pr({ number = 1, title = "test" })
      state.clear()
      assert.is_false(state.is_active())
    end)
  end)

  describe("clear", function()
    it("resets all state", function()
      state.set_pr({ number = 1, title = "test" })
      state.set_files({ { path = "a.lua" } })
      state.set_threads({ { id = "t1", path = "a.lua", mapped_line = 5 } })
      state.set_diff_text("diff content")
      state.set_pr_comments({ { author = "user", body = "hi" } })

      state.clear()

      assert.is_nil(state.get_pr())
      assert.are.same({}, state.get_files())
      assert.are.same({}, state.get_threads())
      assert.are.same({}, state.get_pr_comments())
      assert.are.equal("", state.get_diff_text())
      assert.is_false(state.is_active())
    end)
  end)

  describe("get_threads_for_file", function()
    it("returns only threads matching the path", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1 },
        { id = "t2", path = "b.lua", mapped_line = 2 },
        { id = "t3", path = "a.lua", mapped_line = 3 },
      })

      local result = state.get_threads_for_file("a.lua")
      assert.are.equal(2, #result)
      assert.are.equal("t1", result[1].id)
      assert.are.equal("t3", result[2].id)
    end)

    it("returns empty table when no match", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1 },
      })
      assert.are.same({}, state.get_threads_for_file("nope.lua"))
    end)
  end)

  describe("get_thread_at", function()
    it("finds thread at exact file and line", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10 },
        { id = "t2", path = "a.lua", mapped_line = 20 },
      })
      local t = state.get_thread_at("a.lua", 20)
      assert.is_not_nil(t)
      assert.are.equal("t2", t.id)
    end)

    it("returns nil when no match", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10 },
      })
      assert.is_nil(state.get_thread_at("a.lua", 99))
    end)

    it("returns nil for wrong file", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10 },
      })
      assert.is_nil(state.get_thread_at("b.lua", 10))
    end)
  end)

  describe("get_nearest_thread", function()
    before_each(function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10 },
        { id = "t2", path = "a.lua", mapped_line = 20 },
        { id = "t3", path = "a.lua", mapped_line = 30 },
      })
    end)

    it("returns exact match first", function()
      local t = state.get_nearest_thread("a.lua", 20)
      assert.are.equal("t2", t.id)
    end)

    it("finds nearest within default distance (3)", function()
      local t = state.get_nearest_thread("a.lua", 22)
      assert.are.equal("t2", t.id)
    end)

    it("returns nil when beyond default distance", function()
      assert.is_nil(state.get_nearest_thread("a.lua", 25))
    end)

    it("respects custom max_dist", function()
      local t = state.get_nearest_thread("a.lua", 25, 10)
      assert.are.equal("t2", t.id)
    end)

    it("picks the closest when equidistant threads exist", function()
      -- Line 15 is equidistant from 10 and 20; should pick one (closest first found)
      local t = state.get_nearest_thread("a.lua", 15, 10)
      assert.is_not_nil(t)
      assert.is_true(t.id == "t1" or t.id == "t2")
    end)

    it("returns nil for wrong file", function()
      assert.is_nil(state.get_nearest_thread("nope.lua", 10))
    end)
  end)
end)
