--- Comment thread floating window and all-comments picker
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Format a timestamp for display
---@param ts string ISO 8601 timestamp
---@return string
local function format_time(ts)
  -- Extract date portion
  local date = ts:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date or ts
end

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
    local header = "@" .. comment.author .. "  " .. format_time(comment.created_at)
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

  -- Auto-close on CursorMoved in the parent window
  local parent_win = vim.fn.win_getid(vim.fn.winnr("#"))
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

--- Build preview lines for a thread
---@param thread table GHReviewThread
---@return string[]
local function build_thread_preview(thread)
  local lines = {}
  local status = thread.is_resolved and " [RESOLVED]" or ""
  table.insert(lines, "── Thread" .. status .. " ──")
  table.insert(lines, "File: " .. thread.path .. ":" .. (thread.mapped_line or thread.line or "?"))
  table.insert(lines, "")

  for i, comment in ipairs(thread.comments) do
    local date = format_time(comment.created_at)
    table.insert(lines, "@" .. comment.author .. "  " .. date)
    for body_line in comment.body:gmatch("[^\n]*") do
      table.insert(lines, "  " .. body_line)
    end
    if i < #thread.comments then
      table.insert(lines, "")
    end
  end

  return lines
end

--- Show all comments in a snacks picker with thread preview
---@param opts? { on_goto?: fun(thread: table) }
function M.show_all(opts)
  opts = opts or {}
  local threads = state.get_threads()
  if #threads == 0 then
    vim.notify("No review comments", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for comments picker", vim.log.levels.ERROR)
    return
  end

  local items = {}
  for _, thread in ipairs(threads) do
    local first = thread.comments[1]
    local author = first and first.author or "?"
    local body = first and first.body:match("^([^\n]+)") or ""
    if #body > 80 then
      body = body:sub(1, 77) .. "..."
    end
    local resolved = thread.is_resolved and " ✓" or ""
    local loc = thread.path .. ":" .. (thread.mapped_line or thread.line or 0)

    table.insert(items, {
      text = loc .. " @" .. author .. " " .. body,
      _thread = thread,
      _author = author,
      _body = body,
      _resolved = resolved,
      _loc = loc,
    })
  end

  Snacks.picker.pick({
    title = "PR Comments",
    items = items,
    format = function(item, picker)
      return {
        { item._loc, "Directory" },
        { "  @" .. item._author .. item._resolved, "Special" },
        { "  " .. item._body, "Comment", virtual = true },
      }
    end,
    preview = function(ctx)
      local item = ctx.item
      if not item or not item._thread then return end
      local lines = build_thread_preview(item._thread)
      ctx.preview:set_lines(lines)
      ctx.preview:highlight({ ft = "markdown" })
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      if opts.on_goto and item._thread then
        opts.on_goto(item._thread)
      end
    end,
  })
end

return M
