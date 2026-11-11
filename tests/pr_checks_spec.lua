---@module 'luassert'

local config = require("gh-review.config")

describe("ui.pr_checks", function()
  local pr_checks
  local pr = { number = 7, title = "Add thing", head_oid = "0123456789abcdef" }
  local checks = {
    { name = "lint", workflow = "CI", state = "SUCCESS", url = "https://x/lint", required = false },
    { name = "unit", workflow = "CI", state = "FAILURE", url = "https://x/unit", required = false },
    { name = "e2e", workflow = "CI", state = "FAILURE", url = "https://x/e2e", required = true },
    { name = "deploy", state = "PENDING", url = "https://x/deploy", required = false },
    { name = "docs", workflow = "Docs", state = "SKIPPED", required = false },
  }

  before_each(function()
    config.setup()
    package.loaded["gh-review.ui.pr_checks"] = nil
    pr_checks = require("gh-review.ui.pr_checks")
  end)

  it("groups failing first, required first within a group", function()
    local lines, _, urls = pr_checks.build(pr, checks)
    assert.are.equal("#7 Add thing", lines[1])
    assert.are.equal("head 01234567 · 2 failing · 1 pending · 1 passed · 1 skipped / neutral", lines[2])
    assert.are.equal("Failing (2)", lines[4])
    assert.are.equal("  ✗ CI / e2e  (required)", lines[5])
    assert.are.equal("  ✗ CI / unit", lines[6])
    assert.are.equal("https://x/e2e", urls[5])
    assert.are.equal("Pending (1)", lines[8])
    assert.are.equal("  ◔ deploy", lines[9])
  end)

  it("says when there are no checks", function()
    local lines = pr_checks.build(pr, {})
    assert.is_truthy(lines[2]:find("no checks", 1, true))
  end)

  it("opens loading, fills in, opens URLs, refreshes and closes", function()
    local prev = vim.api.nvim_get_current_win()
    local refreshed = false
    local win = pr_checks.open(pr, { on_refresh = function() refreshed = true end })
    assert.are.equal(win.win, vim.api.nvim_get_current_win())
    assert.are.equal("Loading checks…", vim.api.nvim_buf_get_lines(win.buf, 2, 3, false)[1])

    win.set({ head_oid = pr.head_oid, checks = checks })
    -- Cursor lands on the first failing check.
    assert.are.equal(5, vim.api.nvim_win_get_cursor(win.win)[1])

    local opened
    local orig_open = vim.ui.open
    vim.ui.open = function(url) opened = url end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<cr>", true, false, true), "x", false)
    vim.ui.open = orig_open
    assert.are.equal("https://x/e2e", opened)

    vim.api.nvim_feedkeys("R", "x", false)
    assert.is_true(refreshed)

    win.set_error("HTTP 500")
    assert.is_truthy(vim.api.nvim_buf_get_lines(win.buf, 2, 3, false)[1]:find("HTTP 500", 1, true))

    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(win.win))
    assert.are.equal(prev, vim.api.nvim_get_current_win())
  end)
end)
