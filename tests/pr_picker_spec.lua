---@module 'luassert'

local config = require("gh-review.config")

describe("pr_picker", function()
  local pr_picker, gh
  local picker_config

  before_each(function()
    config.setup()
    picker_config = nil

    -- Stub snacks.nvim
    package.loaded["snacks"] = {
      picker = {
        pick = function(opts) picker_config = opts end,
      },
    }

    package.loaded["gh-review.gh"] = nil
    package.loaded["gh-review.ui.pr_picker"] = nil
    gh = require("gh-review.gh")
    pr_picker = require("gh-review.ui.pr_picker")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
  end)

  describe("show", function()
    it("notifies when snacks not available", function()
      package.loaded["snacks"] = nil
      package.loaded["gh-review.ui.pr_picker"] = nil
      pr_picker = require("gh-review.ui.pr_picker")

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("snacks.nvim required"))
    end)

    it("shows error when pr_list fails", function()
      gh.pr_list = function(cb) cb("network error", nil) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("failed to list PRs") then found = true end
      end
      assert.is_true(found)
    end)

    it("shows info when no PRs found", function()
      gh.pr_list = function(cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("no open PRs found") then found = true end
      end
      assert.is_true(found)
    end)

    it("builds picker items from PR list", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Add feature", author = { login = "dev1" },
            body = "Description", state = "OPEN", headRefName = "feature",
            isDraft = false, createdAt = "2024-01-15T10:00:00Z", reviewDecision = "APPROVED",
          },
          {
            number = 11, title = "Fix bug", author = { login = "dev2" },
            body = "", state = "OPEN", headRefName = "bugfix",
            isDraft = true, createdAt = "2024-01-16T10:00:00Z", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      assert.is_not_nil(picker_config)
      assert.are.equal(2, #picker_config.items)

      -- First PR
      assert.is_truthy(picker_config.items[1].text:find("#10"))
      assert.is_truthy(picker_config.items[1].text:find("Add feature"))
      assert.are.equal("dev1", picker_config.items[1]._author)
      assert.are.equal("", picker_config.items[1]._draft)

      -- Second PR (draft)
      assert.is_truthy(picker_config.items[2].text:find("#11"))
      assert.are.equal("[DRAFT] ", picker_config.items[2]._draft)
    end)

    it("format function produces expected output", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Test PR", author = { login = "dev" },
            body = "", state = "OPEN", headRefName = "feat",
            isDraft = false, createdAt = "2024-01-15T10:00:00Z", reviewDecision = "APPROVED",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local item = picker_config.items[1]
      local formatted = picker_config.format(item)
      assert.is_table(formatted)
      assert.are.equal("#10", formatted[1][1])
      assert.are.equal("Test PR", formatted[3][1])
    end)

    it("confirm calls on_select with PR number", function()
      local selected_number
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 42, title = "Test", author = { login = "dev" },
            body = "", state = "OPEN", headRefName = "feat",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function(n) selected_number = n end })

      local mock_picker = { close = function() end }
      picker_config.confirm(mock_picker, picker_config.items[1])

      assert.are.equal(42, selected_number)
    end)

    it("confirm does nothing with nil item", function()
      gh.pr_list = function(cb)
        cb(nil, { { number = 1, title = "", author = { login = "" }, body = "", state = "", headRefName = "", isDraft = false, createdAt = "", reviewDecision = "" } })
      end

      local called = false
      pr_picker.show({ on_select = function() called = true end })

      local mock_picker = { close = function() end }
      picker_config.confirm(mock_picker, nil)

      assert.is_false(called)
    end)

    it("handles PR with nil author", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 5, title = "No Author", author = nil,
            body = "", state = "OPEN", headRefName = "branch",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      assert.are.equal("unknown", picker_config.items[1]._author)
    end)

    it("preview function generates markdown content", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Feature PR", author = { login = "dev" },
            body = "PR description here", state = "OPEN", headRefName = "feature-branch",
            isDraft = false, createdAt = "2024-03-15T10:00:00Z", reviewDecision = "APPROVED",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      -- Call preview function
      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("#10"))
      assert.is_truthy(text:find("Feature PR"))
      assert.is_truthy(text:find("@dev"))
      assert.is_truthy(text:find("feature%-branch"))
      assert.is_truthy(text:find("APPROVED"))
      assert.is_truthy(text:find("PR description here"))
    end)

    it("preview shows 'No description' for empty body", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 1, title = "T", author = { login = "d" },
            body = "", state = "OPEN", headRefName = "b",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("No description"))
    end)

    it("preview handles draft PR", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 1, title = "Draft", author = { login = "d" },
            body = "", state = "OPEN", headRefName = "b",
            isDraft = true, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("Draft.*yes"))
    end)
  end)
end)
