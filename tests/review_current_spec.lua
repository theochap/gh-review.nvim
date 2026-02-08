---@module 'luassert'

local state = require("gh-review.state")
local gh = require("gh-review.gh")
local config = require("gh-review.config")

describe("review_current", function()
  local orig_pr_view_current
  local notifications = {}

  before_each(function()
    config.setup()
    state.clear()
    notifications = {}
    orig_pr_view_current = gh.pr_view_current

    -- Capture vim.notify calls
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    gh.pr_view_current = orig_pr_view_current
    state.clear()
  end)

  it("is callable", function()
    local gh_review = require("gh-review")
    assert.is_function(gh_review.review_current)
  end)

  it("warns when a review is already active", function()
    state.set_pr({ number = 1, title = "test" })

    local gh_review = require("gh-review")
    gh_review.review_current()

    assert.are.equal(1, #notifications)
    assert.is_truthy(notifications[1].msg:find("already active"))
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)

  it("shows error when no PR exists for current branch", function()
    gh.pr_view_current = function(callback)
      callback("no pull requests found", nil)
    end

    local gh_review = require("gh-review")
    gh_review.review_current()

    -- First notification is "detecting PR..."
    assert.is_truthy(notifications[1].msg:find("detecting PR"))
    -- Second is the error
    assert.is_truthy(notifications[2].msg:find("no PR for current branch"))
    assert.are.equal(vim.log.levels.ERROR, notifications[2].level)
  end)

  it("calls _load_pr_data on success", function()
    local loaded_pr_number = nil
    local gh_review = require("gh-review")
    local orig_load = gh_review._load_pr_data
    gh_review._load_pr_data = function(pr_number)
      loaded_pr_number = pr_number
    end

    gh.pr_view_current = function(callback)
      callback(nil, { number = 42, title = "Test PR" })
    end

    gh_review.review_current()

    -- The callback uses vim.schedule, so we need to process it
    vim.wait(100, function() return loaded_pr_number ~= nil end)

    assert.are.equal(42, loaded_pr_number)

    gh_review._load_pr_data = orig_load
  end)

  it("has default keymap 'O'", function()
    assert.are.equal("O", config.get().keymaps.review_current)
  end)

  describe("PR auto-detection", function()
    local gh_review

    before_each(function()
      gh_review = require("gh-review")
      gh_review._pr_detection_notified = false
    end)

    it("notifies when a PR is found for the current branch", function()
      gh.pr_view_current = function(callback)
        callback(nil, { number = 7, title = "My PR" })
      end

      gh_review._schedule_pr_detection()
      -- The if branch uses vim.defer_fn; call check directly for test
      -- Simulate: vim_did_enter is 1, so defer_fn queues check
      vim.wait(2000, function() return #notifications > 0 end)

      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("PR #7 found") then
          found = true
          break
        end
      end
      assert.is_true(found, "expected PR detection notification")
    end)

    it("does not notify when no PR exists", function()
      gh.pr_view_current = function(callback)
        callback("no pull requests found", nil)
      end

      gh_review._schedule_pr_detection()
      vim.wait(2000, function() return false end)

      for _, n in ipairs(notifications) do
        assert.is_falsy(n.msg:find("PR #"), "should not notify about a PR")
      end
    end)

    it("does not notify when a review is already active", function()
      state.set_pr({ number = 1, title = "test" })

      gh.pr_view_current = function(callback)
        callback(nil, { number = 7, title = "My PR" })
      end

      gh_review._schedule_pr_detection()
      vim.wait(2000, function() return false end)

      for _, n in ipairs(notifications) do
        assert.is_falsy(n.msg:find("PR #7 found"), "should not notify when review active")
      end
    end)

    it("only notifies once even if called multiple times", function()
      gh.pr_view_current = function(callback)
        callback(nil, { number = 7, title = "My PR" })
      end

      gh_review._schedule_pr_detection()
      gh_review._schedule_pr_detection()
      vim.wait(2000, function() return #notifications > 0 end)

      local count = 0
      for _, n in ipairs(notifications) do
        if n.msg:find("PR #7 found") then
          count = count + 1
        end
      end
      assert.are.equal(1, count, "should only notify once")
    end)
  end)
end)
