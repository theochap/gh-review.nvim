---@module 'luassert'

local state = require("gh-review.state")

describe("diffview", function()
  local diffview

  before_each(function()
    state.clear()
    package.loaded["gh-review.integrations.diffview"] = nil
  end)

  after_each(function()
    package.loaded["diffview"] = nil
  end)

  it("notifies when diffview.nvim not installed", function()
    package.loaded["diffview"] = nil

    local notifications = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

    diffview = require("gh-review.integrations.diffview")
    diffview.open()

    vim.notify = orig_notify

    assert.are.equal(1, #notifications)
    assert.is_truthy(notifications[1].msg:find("diffview.nvim not installed"))
  end)

  it("notifies when no active review", function()
    package.loaded["diffview"] = {}

    local notifications = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

    diffview = require("gh-review.integrations.diffview")
    diffview.open()

    vim.notify = orig_notify

    assert.are.equal(1, #notifications)
    assert.is_truthy(notifications[1].msg:find("no active review"))
  end)

  it("opens diffview with base ref when PR is active", function()
    package.loaded["diffview"] = {}
    state.set_pr({
      number = 42, title = "Test", author = "dev", base_ref = "main",
      head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
    })

    local cmd_called
    local orig_cmd = vim.cmd
    vim.cmd = function(c) cmd_called = c end

    diffview = require("gh-review.integrations.diffview")
    diffview.open()

    vim.cmd = orig_cmd

    assert.are.equal("DiffviewOpen main...HEAD", cmd_called)
  end)

  it("appends file path when provided", function()
    package.loaded["diffview"] = {}
    state.set_pr({
      number = 42, title = "Test", author = "dev", base_ref = "develop",
      head_ref = "feature", url = "", body = "", review_decision = "", repository = "org/repo",
    })

    local cmd_called
    local orig_cmd = vim.cmd
    vim.cmd = function(c) cmd_called = c end

    diffview = require("gh-review.integrations.diffview")
    diffview.open("src/file.lua")

    vim.cmd = orig_cmd

    assert.are.equal("DiffviewOpen develop...HEAD -- src/file.lua", cmd_called)
  end)

  it("close does not error when command does not exist", function()
    diffview = require("gh-review.integrations.diffview")
    assert.has_no.errors(function()
      diffview.close()
    end)
  end)
end)
