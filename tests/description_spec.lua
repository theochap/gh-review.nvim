---@module 'luassert'

local config = require("gh-review.config")
local state = require("gh-review.state")
local description = require("gh-review.ui.description")

--- Helper to create a minimal PR table
local function make_pr(overrides)
  return vim.tbl_deep_extend("force", {
    number = 99,
    title = "Test PR Title",
    author = "testuser",
    base_ref = "main",
    head_ref = "feature-branch",
    url = "https://github.com/org/repo/pull/99",
    body = "This is the PR body.",
    review_decision = "APPROVED",
    repository = "org/repo",
  }, overrides or {})
end

describe("description", function()
  before_each(function()
    config.setup()
    state.clear()
  end)

  describe("build_lines", function()
    it("returns no active PR message when no PR set", function()
      local lines = description._build_lines()
      assert.are.same({ "(no active PR)" }, lines)
    end)

    it("contains title, author, status, base/head, URL for full PR", function()
      state.set_pr(make_pr())
      state.set_files({
        { path = "a.lua", status = "added", additions = 10, deletions = 0 },
        { path = "b.lua", status = "modified", additions = 5, deletions = 3 },
      })
      state.set_commits({
        { sha = "abc1234", oid = "abc1234full", message = "first commit", author = "dev", date = "2024-01-15T10:00:00Z" },
      })
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")

      assert.is_truthy(text:find("# PR #99: Test PR Title"))
      assert.is_truthy(text:find("@testuser"))
      assert.is_truthy(text:find("APPROVED"))
      assert.is_truthy(text:find("main"))
      assert.is_truthy(text:find("feature%-branch"))
      assert.is_truthy(text:find("https://github.com/org/repo/pull/99"))
    end)

    it("shows file stats summed correctly", function()
      state.set_pr(make_pr())
      state.set_files({
        { path = "a.lua", status = "added", additions = 10, deletions = 2 },
        { path = "b.lua", status = "modified", additions = 5, deletions = 3 },
      })
      state.set_commits({})
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("2 files changed, %+15 %-5"))
    end)

    it("shows (no description) for empty body", function()
      state.set_pr(make_pr({ body = "" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("%(no description%)"))
    end)

    it("shows (no commits) when no commits", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("%(no commits%)"))
    end)

    it("shows (no top-level comments) when no comments", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("%(no top%-level comments%)"))
    end)

    it("shows commits with details", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({
        { sha = "abc1234", oid = "abc1234full", message = "first commit", author = "dev1", date = "2024-01-15T10:00:00Z" },
        { sha = "def5678", oid = "def5678full", message = "second commit", author = "dev2", date = "2024-01-16T10:00:00Z" },
      })
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("`abc1234`"))
      assert.is_truthy(text:find("first commit"))
      assert.is_truthy(text:find("`def5678`"))
      assert.is_truthy(text:find("second commit"))
    end)

    it("prefixes active commit with > in commits list", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({
        { sha = "abc1234", oid = "abc1234full", message = "first", author = "dev", date = "2024-01-15T10:00:00Z" },
        { sha = "def5678", oid = "def5678full", message = "second", author = "dev", date = "2024-01-16T10:00:00Z" },
      })
      state.set_active_commit({ sha = "abc1234", oid = "abc1234full", message = "first", author = "dev" })
      state.set_pr_comments({})

      local lines = description._build_lines()
      local found_active = false
      local found_inactive = false
      for _, line in ipairs(lines) do
        if line:find("`abc1234`") then
          assert.is_truthy(line:match("^> "))
          found_active = true
        end
        if line:find("`def5678`") then
          assert.is_truthy(line:match("^  "))
          found_inactive = true
        end
      end
      assert.is_true(found_active)
      assert.is_true(found_inactive)
    end)

    it("maps review decision to correct icons", function()
      -- APPROVED -> ✓
      state.set_pr(make_pr({ review_decision = "APPROVED" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})
      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("✓"))

      -- CHANGES_REQUESTED -> ✗
      state.clear()
      state.set_pr(make_pr({ review_decision = "CHANGES_REQUESTED" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})
      lines = description._build_lines()
      text = table.concat(lines, "\n")
      assert.is_truthy(text:find("✗"))

      -- REVIEW_REQUIRED -> ◔
      state.clear()
      state.set_pr(make_pr({ review_decision = "REVIEW_REQUIRED" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})
      lines = description._build_lines()
      text = table.concat(lines, "\n")
      assert.is_truthy(text:find("◔"))
    end)

    it("preserves multi-line body", function()
      state.set_pr(make_pr({ body = "line one\nline two\nline three" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local lines = description._build_lines()
      local found_one, found_two, found_three = false, false, false
      for _, line in ipairs(lines) do
        if line == "line one" then found_one = true end
        if line == "line two" then found_two = true end
        if line == "line three" then found_three = true end
      end
      assert.is_true(found_one)
      assert.is_true(found_two)
      assert.is_true(found_three)
    end)

    it("shows top-level comments with author and body", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({
        { author = "reviewer", body = "Looks good!", created_at = "2024-01-17T12:00:00Z", url = "https://example.com" },
      })

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("@reviewer"))
      assert.is_truthy(text:find("Looks good!"))
    end)

    it("shows commits count in header", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({
        { sha = "a", oid = "afull", message = "c1", author = "d", date = "2024-01-01T00:00:00Z" },
        { sha = "b", oid = "bfull", message = "c2", author = "d", date = "2024-01-02T00:00:00Z" },
        { sha = "c", oid = "cfull", message = "c3", author = "d", date = "2024-01-03T00:00:00Z" },
      })
      state.set_pr_comments({})

      local lines = description._build_lines()
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("## Commits %(3%)"))
    end)
  end)

  describe("show", function()
    before_each(function()
      -- Stub gh.pr_add_comment for the 'n' keymap
      package.loaded["gh-review.gh"] = nil
      package.loaded["gh-review.ui.description"] = nil
    end)

    it("returns nil when no active PR", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      local desc = require("gh-review.ui.description")
      local result = desc.show()

      vim.notify = orig_notify
      assert.is_nil(result)
      assert.is_truthy(notifications[1].msg:find("no active review"))
    end)

    it("creates buffer and window when PR is active", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local desc = require("gh-review.ui.description")
      local win, buf = desc.show()

      assert.is_not_nil(win)
      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.is_true(vim.api.nvim_buf_is_valid(buf))

      -- Buffer should be markdown
      assert.are.equal("markdown", vim.bo[buf].filetype)
      assert.are.equal("nofile", vim.bo[buf].buftype)
      assert.is_false(vim.bo[buf].modifiable)

      -- Window options
      assert.is_false(vim.wo[win].number)
      assert.is_true(vim.wo[win].wrap)

      -- Content should include PR info
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("PR #99"))

      vim.api.nvim_win_close(win, true)
    end)

    it("focuses existing window if buffer already visible", function()
      state.set_pr(make_pr())
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local desc = require("gh-review.ui.description")
      local win1, buf1 = desc.show()

      -- Open something else so we're not in the description window
      vim.cmd("wincmd w")

      -- Call show again — should focus existing window
      local win2 = desc.show()

      -- Should return to existing window (no new window)
      assert.are.equal(win1, vim.api.nvim_get_current_win())

      vim.api.nvim_win_close(win1, true)
    end)
  end)

  describe("refresh_buf", function()
    it("updates buffer content", function()
      state.set_pr(make_pr({ title = "Original Title" }))
      state.set_files({})
      state.set_commits({})
      state.set_pr_comments({})

      local desc = require("gh-review.ui.description")
      local win, buf = desc.show()

      -- Change state
      local pr = state.get_pr()
      pr.title = "Updated Title"

      -- Refresh
      desc.refresh_buf(buf)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("Updated Title"))

      vim.api.nvim_win_close(win, true)
    end)

    it("does nothing for invalid buffer", function()
      local desc = require("gh-review.ui.description")
      assert.has_no.errors(function()
        desc.refresh_buf(99999)
      end)
    end)
  end)
end)
