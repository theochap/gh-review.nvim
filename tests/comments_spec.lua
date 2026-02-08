---@module 'luassert'

local comments = require("gh-review.ui.comments")
local config = require("gh-review.config")

describe("comments.show_thread", function()
  before_each(function()
    config.setup()
  end)

  local function make_thread(opts)
    opts = opts or {}
    return {
      id = "thread1",
      path = "src/main.lua",
      line = 10,
      mapped_line = 10,
      is_resolved = opts.resolved or false,
      comments = opts.comments or {
        {
          id = "c1",
          author = "alice",
          body = "Looks good",
          created_at = "2024-01-15T10:00:00Z",
          url = "https://github.com/test/pr/1#comment-1",
        },
      },
    }
  end

  it("opens a floating window", function()
    local win, buf = comments.show_thread(make_thread())
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    -- Cleanup
    vim.api.nvim_win_close(win, true)
  end)

  it("enables word wrap and linebreak on the window", function()
    local win, _ = comments.show_thread(make_thread())
    assert.is_true(vim.wo[win].wrap)
    assert.is_true(vim.wo[win].linebreak)
    vim.api.nvim_win_close(win, true)
  end)

  it("shows author and comment body in buffer", function()
    local win, buf = comments.show_thread(make_thread())
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("@alice"))
    assert.is_truthy(text:find("Looks good"))
    vim.api.nvim_win_close(win, true)
  end)

  it("shows [RESOLVED] for resolved threads", function()
    local win, buf = comments.show_thread(make_thread({ resolved = true }))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("%[RESOLVED%]"))
    vim.api.nvim_win_close(win, true)
  end)

  it("shows multiple comments", function()
    local thread = make_thread({
      comments = {
        { id = "c1", author = "alice", body = "First comment", created_at = "2024-01-15T10:00:00Z", url = "" },
        { id = "c2", author = "bob", body = "Second comment", created_at = "2024-01-15T11:00:00Z", url = "" },
      },
    })
    local win, buf = comments.show_thread(thread)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("@alice"))
    assert.is_truthy(text:find("@bob"))
    assert.is_truthy(text:find("First comment"))
    assert.is_truthy(text:find("Second comment"))
    vim.api.nvim_win_close(win, true)
  end)

  it("sets buffer as non-modifiable", function()
    local win, buf = comments.show_thread(make_thread())
    assert.is_false(vim.bo[buf].modifiable)
    vim.api.nvim_win_close(win, true)
  end)
end)
