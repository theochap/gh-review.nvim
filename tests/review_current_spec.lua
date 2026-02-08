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
end)
