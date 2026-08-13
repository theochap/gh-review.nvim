---@module 'luassert'

local config = require("gh-review.config")
local review_submit = require("gh-review.ui.review_submit")

--- A pending review payload in the shape graphql.fetch_pending_review returns.
---@param comments table[]
---@param overrides? table
local function make_review(comments, overrides)
  return vim.tbl_extend("force", {
    id = "PRR_1",
    url = "https://github.com/o/r/pull/1",
    body = "",
    total_count = #comments,
    comments = comments,
  }, overrides or {})
end

describe("review_submit", function()
  before_each(function()
    config.setup()
  end)

  describe("render", function()
    it("shows the comment count and the pending warning", function()
      local lines = review_submit._render(make_review({
        { path = "a.lua", line = 5, body = "nit" },
      }))
      assert.is_truthy(lines[1]:find("1 comment", 1, true))
      assert.is_falsy(lines[1]:find("comments", 1, true))
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("Not published yet", 1, true))
    end)

    it("pluralises the count", function()
      local lines = review_submit._render(make_review({
        { path = "a.lua", line = 1, body = "x" },
        { path = "b.lua", line = 2, body = "y" },
      }))
      assert.is_truthy(lines[1]:find("2 comments", 1, true))
    end)

    it("labels single lines, ranges and missing lines", function()
      local lines = review_submit._render(make_review({
        { path = "a.lua", line = 5, body = "single" },
        { path = "b.lua", line = 9, start_line = 7, body = "range" },
        { path = "c.lua", body = "no line" },
      }))
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("1. a.lua:5", 1, true))
      assert.is_truthy(joined:find("2. b.lua:7-9", 1, true))
      assert.is_truthy(joined:find("3. c.lua", 1, true))
      -- No stray colon when there is no line to anchor to
      assert.is_falsy(joined:find("c.lua:", 1, true))
    end)

    it("marks outdated comments", function()
      local lines = review_submit._render(make_review({
        { path = "a.lua", line = 5, body = "stale", is_outdated = true },
      }))
      assert.is_truthy(table.concat(lines, "\n"):find("[outdated]", 1, true))
    end)

    it("notes when only part of the pending review was fetched", function()
      local lines = review_submit._render(make_review({
        { path = "a.lua", line = 1, body = "x" },
      }, { total_count = 130 }))
      assert.is_truthy(table.concat(lines, "\n"):find("first 1 of 130", 1, true))
    end)

    it("maps every rendered comment line back to its comment", function()
      local first = { path = "a.lua", line = 5, body = "line one\nline two" }
      local second = { path = "b.lua", line = 6, body = "other" }
      local lines, _, comment_at = review_submit._render(make_review({ first, second }))

      local seen_first, seen_second = 0, 0
      for i = 1, #lines do
        if comment_at[i] == first then seen_first = seen_first + 1 end
        if comment_at[i] == second then seen_second = seen_second + 1 end
      end
      -- Header + both body lines for the first comment, header + body for the second
      assert.are.equal(3, seen_first)
      assert.are.equal(2, seen_second)
    end)

    it("keeps the key hints in the footer", function()
      local lines = review_submit._render(make_review({ { path = "a", line = 1, body = "b" } }))
      local footer = lines[#lines]
      assert.is_truthy(footer:find("s: comment", 1, true))
      assert.is_truthy(footer:find("a: approve", 1, true))
      assert.is_truthy(footer:find("x: request changes", 1, true))
    end)
  end)

  describe("show", function()
    local win, buf

    after_each(function()
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      win, buf = nil, nil
    end)

    it("opens a readonly float with the rendered contents", function()
      win, buf = review_submit.show(make_review({
        { path = "a.lua", line = 5, body = "nit" },
      }))

      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.are.equal("gh-review-pending", vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modifiable)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_truthy(table.concat(lines, "\n"):find("a.lua:5", 1, true))
    end)

    it("jumps to the comment under the cursor and closes", function()
      local comment = { path = "a.lua", line = 5, body = "nit" }
      local jumped
      win, buf = review_submit.show(make_review({ comment }), {
        on_jump = function(c) jumped = c end,
      })

      -- Move onto the comment's header line, then confirm
      local target
      local _, _, comment_at = review_submit._render(make_review({ comment }))
      for i, c in pairs(comment_at) do
        if c == comment then
          target = target and math.min(target, i) or i
        end
      end
      vim.api.nvim_win_set_cursor(win, { target, 0 })
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal \r")
      end)

      assert.are.equal(comment, jumped)
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end)

    it("reports the submit event for each key and closes", function()
      for key, event in pairs({ s = "COMMENT", a = "APPROVE", x = "REQUEST_CHANGES" }) do
        local submitted
        local w = review_submit.show(make_review({ { path = "a", line = 1, body = "b" } }), {
          on_submit = function(e) submitted = e end,
        })
        vim.api.nvim_win_call(w, function()
          vim.cmd("normal " .. key)
        end)
        assert.are.equal(event, submitted)
        assert.is_false(vim.api.nvim_win_is_valid(w))
      end
    end)

    it("closes on q without submitting", function()
      local submitted = false
      win, buf = review_submit.show(make_review({ { path = "a", line = 1, body = "b" } }), {
        on_submit = function() submitted = true end,
      })
      local w = win
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal q")
      end)

      assert.is_false(submitted)
      assert.is_false(vim.api.nvim_win_is_valid(w))
      win = nil
    end)
  end)
end)
