---@module 'luassert'

local state = require("gh-review.state")
local config = require("gh-review.config")

describe("unified", function()
  local unified, diff_module

  before_each(function()
    config.setup()
    state.clear()
    package.loaded["gh-review.ui.unified"] = nil
    unified = require("gh-review.ui.unified")
    diff_module = require("gh-review.diff")
  end)

  after_each(function()
    pcall(unified.close)
    state.clear()
  end)

  describe("_render", function()
    it("emits hunk header + context + grouped -/+ blocks", function()
      local file_diff = {
        path = "src/a.lua",
        hunks = {
          {
            old_start = 10, old_count = 3, new_start = 10, new_count = 4,
            lines = {
              " context_one",
              "-removed_one",
              "-removed_two",
              "+added_one",
              "+added_two",
              "+added_three",
              " context_two",
            },
          },
        },
      }

      local lines, highlights, row_map = unified._render(file_diff)

      -- Header + 7 content lines
      assert.are.equal(8, #lines)
      assert.is_truthy(lines[1]:find("^@@"))
      assert.are.equal("context_one", lines[2])
      assert.are.equal("removed_one", lines[3])
      assert.are.equal("removed_two", lines[4])
      assert.are.equal("added_one", lines[5])
      assert.are.equal("added_two", lines[6])
      assert.are.equal("added_three", lines[7])
      assert.are.equal("context_two", lines[8])

      -- Highlights
      local hl_by_row = {}
      for _, h in ipairs(highlights) do hl_by_row[h[1]] = h[2] end
      assert.are.equal("DiffText", hl_by_row[1])
      assert.are.equal("DiffDelete", hl_by_row[3])
      assert.are.equal("DiffDelete", hl_by_row[4])
      assert.are.equal("DiffAdd", hl_by_row[5])
      assert.are.equal("DiffAdd", hl_by_row[6])
      assert.are.equal("DiffAdd", hl_by_row[7])
      -- Context line 2 has no highlight
      assert.is_nil(hl_by_row[2])
      assert.is_nil(hl_by_row[8])

      -- row_map tracks old/new line numbers
      assert.are.equal("header", row_map[1].kind)
      assert.are.equal(10, row_map[2].old)
      assert.are.equal(10, row_map[2].new)
      assert.are.equal(11, row_map[3].old) -- removed_one
      assert.is_nil(row_map[3].new)
      assert.are.equal(11, row_map[5].new) -- added_one
      assert.is_nil(row_map[5].old)
    end)

    it("separates multiple hunks with a blank row", function()
      local file_diff = {
        hunks = {
          {
            old_start = 1, old_count = 1, new_start = 1, new_count = 1,
            lines = { "-a", "+A" },
          },
          {
            old_start = 20, old_count = 1, new_start = 20, new_count = 1,
            lines = { "-b", "+B" },
          },
        },
      }

      local lines = unified._render(file_diff)
      -- 1 header, 2 content, 1 blank, 1 header, 2 content = 7
      assert.are.equal(7, #lines)
      assert.are.equal("", lines[4])
    end)

    it("handles a pure-add hunk", function()
      local file_diff = {
        hunks = {
          {
            old_start = 1, old_count = 0, new_start = 1, new_count = 2,
            lines = { "+line_one", "+line_two" },
          },
        },
      }

      local lines, highlights = unified._render(file_diff)
      assert.are.equal(3, #lines) -- header + 2 additions
      local hl_by_row = {}
      for _, h in ipairs(highlights) do hl_by_row[h[1]] = h[2] end
      assert.are.equal("DiffAdd", hl_by_row[2])
      assert.are.equal("DiffAdd", hl_by_row[3])
    end)

    it("handles a pure-delete hunk", function()
      local file_diff = {
        hunks = {
          {
            old_start = 5, old_count = 2, new_start = 5, new_count = 0,
            lines = { "-gone_one", "-gone_two" },
          },
        },
      }

      local lines, highlights = unified._render(file_diff)
      assert.are.equal(3, #lines)
      local hl_by_row = {}
      for _, h in ipairs(highlights) do hl_by_row[h[1]] = h[2] end
      assert.are.equal("DiffDelete", hl_by_row[2])
      assert.are.equal("DiffDelete", hl_by_row[3])
    end)
  end)

  describe("open / close", function()
    it("notifies when no diff data is loaded", function()
      state.set_pr({ number = 1, title = "t", base_ref = "main" })
      state.set_diff_text("")

      local notifications = {}
      local orig = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, msg) end

      unified.open("src/a.lua")

      vim.notify = orig
      assert.is_true(#notifications >= 1)
      assert.is_truthy(notifications[1]:find("no diff"))
      assert.is_false(unified.is_active())
    end)

    it("opens a scratch buffer with the rendered content", function()
      state.set_pr({ number = 1, title = "t", base_ref = "main" })
      state.set_diff_text(table.concat({
        "diff --git a/src/a.lua b/src/a.lua",
        "--- a/src/a.lua",
        "+++ b/src/a.lua",
        "@@ -1,1 +1,2 @@",
        " ctx",
        "+added",
      }, "\n"))

      unified.open("src/a.lua")

      assert.is_true(unified.is_active())
      local buf = vim.api.nvim_get_current_buf()
      local name = vim.api.nvim_buf_get_name(buf)
      assert.is_truthy(name:find("ghreview://unified/src/a%.lua"))
      assert.is_false(vim.bo[buf].modifiable)

      unified.close()
      assert.is_false(unified.is_active())
    end)
  end)
end)
