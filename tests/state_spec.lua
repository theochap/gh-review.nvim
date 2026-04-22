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
      state.set_view_mode("inline")

      state.clear()

      assert.is_nil(state.get_pr())
      assert.are.same({}, state.get_files())
      assert.are.same({}, state.get_threads())
      assert.are.same({}, state.get_pr_comments())
      assert.are.equal("", state.get_diff_text())
      assert.is_false(state.is_active())
      assert.is_nil(state.get_view_mode())
    end)
  end)

  describe("view_mode", function()
    it("is nil until set", function()
      assert.is_nil(state.get_view_mode())
    end)

    it("round-trips set/get", function()
      state.set_view_mode("inline")
      assert.are.equal("inline", state.get_view_mode())
      state.set_view_mode("split")
      assert.are.equal("split", state.get_view_mode())
    end)
  end)

  describe("get_threads", function()
    it("excludes outdated threads", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, is_outdated = false },
        { id = "t2", path = "a.lua", mapped_line = 2, is_outdated = true },
        { id = "t3", path = "b.lua", mapped_line = 3, is_outdated = false },
      })

      local result = state.get_threads()
      assert.are.equal(2, #result)
      assert.are.equal("t1", result[1].id)
      assert.are.equal("t3", result[2].id)
    end)

    it("returns empty when all threads are outdated", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, is_outdated = true },
      })
      assert.are.same({}, state.get_threads())
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

    it("excludes outdated threads", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, is_outdated = false },
        { id = "t2", path = "a.lua", mapped_line = 2, is_outdated = true },
      })
      local result = state.get_threads_for_file("a.lua")
      assert.are.equal(1, #result)
      assert.are.equal("t1", result[1].id)
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

    it("skips outdated threads even at exact match", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10, is_outdated = true },
      })
      assert.is_nil(state.get_thread_at("a.lua", 10))
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

    it("skips outdated threads in proximity search", function()
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 10, is_outdated = true },
        { id = "t2", path = "a.lua", mapped_line = 20 },
      })
      -- Line 11 is close to t1 but t1 is outdated; should not find it
      assert.is_nil(state.get_nearest_thread("a.lua", 11))
    end)
  end)

  describe("reviewed files", function()
    it("is_reviewed defaults to false", function()
      assert.is_false(state.is_reviewed("src/a.lua"))
    end)

    it("set_reviewed(true) marks the file", function()
      state.set_reviewed("src/a.lua", true)
      assert.is_true(state.is_reviewed("src/a.lua"))
    end)

    it("set_reviewed(false) unmarks the file", function()
      state.set_reviewed("src/a.lua", true)
      state.set_reviewed("src/a.lua", false)
      assert.is_false(state.is_reviewed("src/a.lua"))
    end)

    it("toggle_reviewed flips and returns the new state", function()
      assert.is_true(state.toggle_reviewed("src/a.lua"))
      assert.is_true(state.is_reviewed("src/a.lua"))
      assert.is_false(state.toggle_reviewed("src/a.lua"))
      assert.is_false(state.is_reviewed("src/a.lua"))
    end)

    it("get_reviewed_files returns every marked path", function()
      state.set_reviewed("src/a.lua", true)
      state.set_reviewed("src/b.lua", true)
      local list = state.get_reviewed_files()
      table.sort(list)
      assert.are.same({ "src/a.lua", "src/b.lua" }, list)
    end)

    it("clear wipes the reviewed set", function()
      state.set_reviewed("src/a.lua", true)
      state.clear()
      assert.is_false(state.is_reviewed("src/a.lua"))
      assert.are.same({}, state.get_reviewed_files())
    end)
  end)

  describe("reviewed persistence across set_pr", function()
    local original_stdpath, tmp_data

    before_each(function()
      tmp_data = vim.fn.tempname()
      vim.fn.mkdir(tmp_data, "p")
      original_stdpath = vim.fn.stdpath
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.stdpath = function(what)
        if what == "data" then return tmp_data end
        return original_stdpath(what)
      end
      -- The store module is cached; it looks at stdpath each call so no reload needed.
    end)

    after_each(function()
      vim.fn.stdpath = original_stdpath
      vim.fn.delete(tmp_data, "rf")
    end)

    it("reloads reviewed marks when set_pr is called with a persisted PR", function()
      -- First session: mark a file
      state.set_pr({ number = 42, title = "T", repository = "owner/repo" })
      state.set_reviewed("src/a.lua", true)
      assert.is_true(state.is_reviewed("src/a.lua"))

      -- Simulate a fresh session: clear + set_pr again (same PR) reloads
      state.clear()
      assert.is_false(state.is_reviewed("src/a.lua"))
      state.set_pr({ number = 42, title = "T", repository = "owner/repo" })
      assert.is_true(state.is_reviewed("src/a.lua"))
    end)

    it("does not persist when PR has no repository/number", function()
      state.set_pr({ number = 1, title = "test" })
      state.set_reviewed("src/a.lua", true)
      state.clear()
      state.set_pr({ number = 1, title = "test" })
      assert.is_false(state.is_reviewed("src/a.lua"))
    end)
  end)
end)
