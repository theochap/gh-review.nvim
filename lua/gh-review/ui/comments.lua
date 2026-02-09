--- Comment thread floating window
local M = {}

local config = require("gh-review.config")
local util = require("gh-review.util")

--- Show a single thread in a floating window
---@param thread table GHReviewThread
---@param opts? { on_reply?: fun(), on_resolve?: fun() }
function M.show_thread(thread, opts)
  opts = opts or {}
  local lines = {}
  local highlights = {}

  -- Header
  local status = thread.is_resolved and " [RESOLVED]" or ""
  table.insert(lines, "── Thread" .. status .. " ──")
  table.insert(highlights, { line = #lines, hl = "Title" })
  table.insert(lines, "File: " .. thread.path .. ":" .. (thread.mapped_line or thread.line or "?"))
  table.insert(lines, "")

  -- Comments
  for i, comment in ipairs(thread.comments) do
    local header = "@" .. comment.author .. "  " .. util.format_time(comment.created_at)
    table.insert(lines, header)
    table.insert(highlights, { line = #lines, hl = "Special" })

    -- Comment body
    for body_line in comment.body:gmatch("[^\n]*") do
      table.insert(lines, "  " .. body_line)
    end

    if i < #thread.comments then
      table.insert(lines, "")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "── r: reply  t: resolve  o: browser  q: close ──")

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "gh-review-thread"

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, hl.hl, hl.line - 1, 0, -1)
  end

  -- Calculate window size
  local cfg = config.get()
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, cfg.float.max_width)
  local height = math.min(#lines, cfg.float.max_height)

  -- Open float
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = cfg.float.border,
    title = " PR Comment ",
    title_pos = "center",
  })

  -- Use proper floating window highlights and enable word wrap
  vim.wo[win].winhighlight = "Normal:NormalFloat,CursorLine:CursorLine"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  -- Buffer-local keymaps
  local kopts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, kopts)

  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(win, true)
    if opts.on_reply then
      opts.on_reply()
    end
  end, kopts)

  vim.keymap.set("n", "t", function()
    vim.api.nvim_win_close(win, true)
    if opts.on_resolve then
      opts.on_resolve()
    end
  end, kopts)

  vim.keymap.set("n", "o", function()
    local first = thread.comments[1]
    if first and first.url then
      vim.ui.open(first.url)
    end
  end, kopts)

  -- Auto-close on CursorMoved in another window
  vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      if vim.api.nvim_get_current_win() ~= win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
        return true -- remove autocmd
      end
    end,
  })

  return win, buf
end

return M
