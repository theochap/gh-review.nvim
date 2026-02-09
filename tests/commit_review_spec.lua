---@module 'luassert'

local state = require("gh-review.state")

describe("commit review", function()
  before_each(function()
    state.clear()
  end)

  describe("active_commit state", function()
    it("is nil initially", function()
      assert.is_nil(state.get_active_commit())
    end)

    it("can be set and retrieved", function()
      local commit = { sha = "abc1234", oid = "abc1234567890abcdef1234567890abcdef123456", message = "fix bug", author = "dev", date = "2025-01-01" }
      state.set_active_commit(commit)
      local active = state.get_active_commit()
      assert.are.equal("abc1234", active.sha)
      assert.are.equal("abc1234567890abcdef1234567890abcdef123456", active.oid)
    end)

    it("clear_active_commit resets commit and commit_files", function()
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890abcdef1234567890abcdef123456" })
      state.set_commit_files({ { path = "a.lua", status = "modified", additions = 0, deletions = 0 } })
      state.clear_active_commit()
      assert.is_nil(state.get_active_commit())
      assert.are.same({}, state.get_commit_files())
    end)

    it("clear() resets active_commit", function()
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({ { path = "a.lua", status = "added", additions = 0, deletions = 0 } })
      state.clear()
      assert.is_nil(state.get_active_commit())
      assert.are.same({}, state.get_commit_files())
    end)
  end)

  describe("get_effective_files", function()
    it("returns all PR files when no commit is active", function()
      local files = {
        { path = "a.lua", status = "modified", additions = 5, deletions = 2 },
        { path = "b.lua", status = "added", additions = 10, deletions = 0 },
      }
      state.set_files(files)
      assert.are.same(files, state.get_effective_files())
    end)

    it("returns commit_files when a commit is active", function()
      state.set_files({
        { path = "a.lua", status = "modified", additions = 5, deletions = 2 },
        { path = "b.lua", status = "added", additions = 10, deletions = 0 },
        { path = "c.lua", status = "deleted", additions = 0, deletions = 8 },
      })
      local commit_files = {
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      }
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files(commit_files)
      assert.are.same(commit_files, state.get_effective_files())
    end)
  end)

  describe("get_effective_threads", function()
    it("returns all threads when no commit is active", function()
      local threads = {
        { id = "t1", path = "a.lua", mapped_line = 1 },
        { id = "t2", path = "b.lua", mapped_line = 2 },
      }
      state.set_threads(threads)
      assert.are.same(threads, state.get_effective_threads())
    end)

    it("filters threads by path and commit_oid when commit is active", function()
      -- Simulate PR with 3 commits in order
      state.set_commits({
        { sha = "aaa1234", oid = "aaa1234567890", message = "first", author = "dev", date = "" },
        { sha = "bbb1234", oid = "bbb1234567890", message = "second", author = "dev", date = "" },
        { sha = "ccc1234", oid = "ccc1234567890", message = "third", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "bbb1234567890" },
        { id = "t2", path = "b.lua", mapped_line = 2, commit_oid = "bbb1234567890" },
        { id = "t3", path = "a.lua", mapped_line = 5, commit_oid = "ccc1234567890" },
        { id = "t4", path = "a.lua", mapped_line = 8, commit_oid = "aaa1234567890" },
      })
      -- Select commit bbb (the second one)
      state.set_active_commit({ sha = "bbb1234", oid = "bbb1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      -- t1: path match + oid is bbb (selected) → included
      -- t2: path doesn't match (b.lua not in commit_files) → excluded
      -- t3: path match + oid is ccc (after bbb) → included
      -- t4: path match but oid is aaa (before bbb) → excluded
      assert.are.equal(2, #result)
      assert.are.equal("t1", result[1].id)
      assert.are.equal("t3", result[2].id)
    end)

    it("includes threads with nil commit_oid (path-only fallback)", function()
      state.set_commits({
        { sha = "abc1234", oid = "abc1234567890", message = "test", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "abc1234567890" },
        { id = "t2", path = "a.lua", mapped_line = 3 }, -- no commit_oid
      })
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      assert.are.equal(2, #result)
      assert.are.equal("t1", result[1].id)
      assert.are.equal("t2", result[2].id)
    end)

    it("excludes threads with unknown commit_oid not in PR commits", function()
      state.set_commits({
        { sha = "abc1234", oid = "abc1234567890", message = "test", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "abc1234567890" },
        { id = "t2", path = "a.lua", mapped_line = 3, commit_oid = "unknown_pre_force_push" },
      })
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      -- t2 has an OID not in the commits list → excluded
      assert.are.equal(1, #result)
      assert.are.equal("t1", result[1].id)
    end)

    it("selecting first commit accepts OIDs from all commits", function()
      state.set_commits({
        { sha = "aaa1234", oid = "aaa1234567890", message = "first", author = "dev", date = "" },
        { sha = "bbb1234", oid = "bbb1234567890", message = "second", author = "dev", date = "" },
        { sha = "ccc1234", oid = "ccc1234567890", message = "third", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "aaa1234567890" },
        { id = "t2", path = "a.lua", mapped_line = 5, commit_oid = "bbb1234567890" },
        { id = "t3", path = "a.lua", mapped_line = 8, commit_oid = "ccc1234567890" },
      })
      state.set_active_commit({ sha = "aaa1234", oid = "aaa1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      -- All OIDs are >= first commit, so all included
      assert.are.equal(3, #result)
    end)

    it("selecting last commit only accepts its own OID", function()
      state.set_commits({
        { sha = "aaa1234", oid = "aaa1234567890", message = "first", author = "dev", date = "" },
        { sha = "bbb1234", oid = "bbb1234567890", message = "second", author = "dev", date = "" },
        { sha = "ccc1234", oid = "ccc1234567890", message = "third", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "aaa1234567890" },
        { id = "t2", path = "a.lua", mapped_line = 5, commit_oid = "bbb1234567890" },
        { id = "t3", path = "a.lua", mapped_line = 8, commit_oid = "ccc1234567890" },
      })
      state.set_active_commit({ sha = "ccc1234", oid = "ccc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      -- Only t3 has OID of last commit
      assert.are.equal(1, #result)
      assert.are.equal("t3", result[1].id)
    end)

    it("excludes outdated threads even when path and OID match", function()
      state.set_commits({
        { sha = "abc1234", oid = "abc1234567890", message = "test", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "abc1234567890", is_outdated = false },
        { id = "t2", path = "a.lua", mapped_line = 5, commit_oid = "abc1234567890", is_outdated = true },
      })
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      local result = state.get_effective_threads()
      assert.are.equal(1, #result)
      assert.are.equal("t1", result[1].id)
    end)

    it("clearing commit restores full thread list", function()
      state.set_commits({
        { sha = "abc1234", oid = "abc1234567890", message = "test", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1 },
        { id = "t2", path = "b.lua", mapped_line = 2 },
      })
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })

      -- Filtered: only a.lua
      assert.are.equal(1, #state.get_effective_threads())

      -- Clear: all threads restored
      state.clear_active_commit()
      assert.are.equal(2, #state.get_effective_threads())
    end)
  end)

  describe("get_effective_threads_for_file", function()
    before_each(function()
      state.set_commits({
        { sha = "abc1234", oid = "abc1234567890", message = "test", author = "dev", date = "" },
      })
      state.set_threads({
        { id = "t1", path = "a.lua", mapped_line = 1, commit_oid = "abc1234567890" },
        { id = "t2", path = "b.lua", mapped_line = 2, commit_oid = "abc1234567890" },
      })
    end)

    it("returns threads when no commit filter", function()
      local result = state.get_effective_threads_for_file("a.lua")
      assert.are.equal(1, #result)
      assert.are.equal("t1", result[1].id)
    end)

    it("returns threads for file in commit with matching oid", function()
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "a.lua", status = "modified", additions = 0, deletions = 0 },
      })
      local result = state.get_effective_threads_for_file("a.lua")
      assert.are.equal(1, #result)
    end)

    it("returns empty for file not in commit", function()
      state.set_active_commit({ sha = "abc1234", oid = "abc1234567890" })
      state.set_commit_files({
        { path = "c.lua", status = "modified", additions = 0, deletions = 0 },
      })
      local result = state.get_effective_threads_for_file("a.lua")
      assert.are.same({}, result)
    end)
  end)

  describe("commits store full OID", function()
    it("stores oid alongside short sha", function()
      local commits = {
        { sha = "abc1234", oid = "abc1234567890abcdef1234567890abcdef123456", message = "test", author = "dev", date = "" },
      }
      state.set_commits(commits)
      local stored = state.get_commits()
      assert.are.equal("abc1234", stored[1].sha)
      assert.are.equal("abc1234567890abcdef1234567890abcdef123456", stored[1].oid)
    end)
  end)
end)
