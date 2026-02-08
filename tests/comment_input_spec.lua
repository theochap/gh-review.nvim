---@module 'luassert'

local comment_input = require("gh-review.ui.comment_input")
local config = require("gh-review.config")

describe("comment_input", function()
  before_each(function()
    config.setup()
  end)

  describe("open without context", function()
    it("opens a floating window", function()
      local win, buf = comment_input.open({
        title = "Test",
        on_submit = function() end,
      })
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("sets markdown filetype", function()
      local win, buf = comment_input.open({
        title = "Test",
        on_submit = function() end,
      })
      assert.are.equal("markdown", vim.bo[buf].filetype)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("enables wrap and linebreak", function()
      local win, buf = comment_input.open({
        title = "Test",
        on_submit = function() end,
      })
      assert.is_true(vim.wo[win].wrap)
      assert.is_true(vim.wo[win].linebreak)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("starts with empty buffer", function()
      local win, buf = comment_input.open({
        title = "Test",
        on_submit = function() end,
      })
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal("", lines[1])
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("open with context_lines", function()
    it("shows context lines above separator", function()
      local ctx = { "@alice:", "  Original comment" }
      local win, buf = comment_input.open({
        title = "Reply",
        on_submit = function() end,
        context_lines = ctx,
      })
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal("@alice:", lines[1])
      assert.are.equal("  Original comment", lines[2])
      -- Line 3 is the separator (all ─ characters, which are multi-byte UTF-8)
      assert.is_truthy(lines[3]:find("─"))
      -- Line 4 is the empty input line
      assert.are.equal("", lines[4])
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("applies Comment highlight to context lines", function()
      local ctx = { "@alice:", "  Comment body" }
      local win, buf = comment_input.open({
        title = "Reply",
        on_submit = function() end,
        context_lines = ctx,
      })
      local ns = vim.api.nvim_get_namespaces()["gh_review_input_ctx"]
      assert.is_not_nil(ns)
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.is_true(#extmarks > 0)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("submits only text below the separator", function()
      local submitted = nil
      local ctx = { "@alice:", "  Original" }
      local win, buf = comment_input.open({
        title = "Reply",
        on_submit = function(body) submitted = body end,
        context_lines = ctx,
      })
      -- Buffer layout: "@alice:", "  Original", "───...", ""
      -- input_start = 3 (0-indexed line of the empty input line)
      -- Replace the empty input line with our reply text
      local input_line_0idx = #ctx + 1 -- context + separator = 0-indexed line of input
      vim.api.nvim_buf_set_lines(buf, input_line_0idx, -1, false, { "My reply" })

      -- Simulate Ctrl-S by triggering the keymap synchronously
      vim.cmd("stopinsert")
      local keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
      vim.api.nvim_feedkeys(keys, "x", false)

      assert.are.equal("My reply", submitted)
    end)
  end)

  describe("open with multi-comment context", function()
    it("shows full thread context", function()
      local ctx = {
        "@alice:",
        "  First comment body",
        "",
        "@bob:",
        "  Second comment body",
      }
      local win, buf = comment_input.open({
        title = "Reply",
        on_submit = function() end,
        context_lines = ctx,
      })
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("@alice:"))
      assert.is_truthy(text:find("First comment body"))
      assert.is_truthy(text:find("@bob:"))
      assert.is_truthy(text:find("Second comment body"))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
