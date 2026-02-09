---@module 'luassert'

local config = require("gh-review.config")
local state = require("gh-review.state")
local lualine = require("gh-review.integrations.lualine")

describe("lualine", function()
  before_each(function()
    config.setup()
    state.clear()
  end)

  describe("condition", function()
    it("returns false when no active review", function()
      assert.is_false(lualine.condition())
    end)

    it("returns true when review is active", function()
      state.set_pr({
        number = 123,
        title = "Test PR",
        author = "dev",
        base_ref = "main",
        head_ref = "feature",
        url = "https://github.com/org/repo/pull/123",
        body = "",
        review_decision = "",
        repository = "org/repo",
      })
      assert.is_true(lualine.condition())
    end)
  end)

  describe("component", function()
    it("returns empty string when inactive", function()
      assert.are.equal("", lualine.component())
    end)

    it("returns formatted string for approved PR", function()
      state.set_pr({
        number = 123,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "head_ref",
        url = "https://github.com/org/repo/pull/123",
        body = "",
        review_decision = "APPROVED",
        repository = "org/repo",
      })
      assert.are.equal("⎇ #123 head_ref ✓", lualine.component())
    end)

    it("returns formatted string for changes requested PR", function()
      state.set_pr({
        number = 123,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "head_ref",
        url = "https://github.com/org/repo/pull/123",
        body = "",
        review_decision = "CHANGES_REQUESTED",
        repository = "org/repo",
      })
      assert.are.equal("⎇ #123 head_ref ✗", lualine.component())
    end)

    it("returns formatted string for review required PR", function()
      state.set_pr({
        number = 123,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "head_ref",
        url = "https://github.com/org/repo/pull/123",
        body = "",
        review_decision = "",
        repository = "org/repo",
      })
      -- Default icon is review_required when no decision
      assert.are.equal("⎇ #123 head_ref ◔", lualine.component())
    end)

    it("appends commit info when commit is active", function()
      state.set_pr({
        number = 42,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "feat",
        url = "https://github.com/org/repo/pull/42",
        body = "",
        review_decision = "APPROVED",
        repository = "org/repo",
      })
      state.set_active_commit({
        sha = "abc1234",
        oid = "abc1234full",
        message = "fix bug",
        author = "dev",
      })
      local result = lualine.component()
      assert.is_truthy(result:find("@ abc1234 fix bug"))
    end)

    it("truncates commit message to 30 chars with ...", function()
      state.set_pr({
        number = 42,
        title = "Test",
        author = "dev",
        base_ref = "main",
        head_ref = "feat",
        url = "https://github.com/org/repo/pull/42",
        body = "",
        review_decision = "APPROVED",
        repository = "org/repo",
      })
      local long_msg = "this is a very long commit message that exceeds thirty characters"
      state.set_active_commit({
        sha = "def5678",
        oid = "def5678full",
        message = long_msg,
        author = "dev",
      })
      local result = lualine.component()
      assert.is_truthy(result:find("%.%.%.$"))
      -- The truncated part should be 27 chars + "..."
      local after_sha = result:match("@ def5678 (.+)$")
      assert.are.equal(30, #after_sha)
    end)
  end)

  describe("spec", function()
    it("returns table with component function and cond", function()
      local s = lualine.spec()
      assert.is_table(s)
      assert.are.equal(lualine.component, s[1])
      assert.are.equal(lualine.condition, s.cond)
    end)
  end)
end)
