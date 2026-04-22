--- Comment thread floating window
local M = {}

local config = require("gh-review.config")
local util = require("gh-review.util")
local state = require("gh-review.state")
local diff_module = require("gh-review.diff")

--- Build the exact slice of diff lines that a thread points to, with
--- per-row highlight hints. Only the lines inside the commented range are
--- emitted — surrounding hunk context is omitted. Returns two parallel
--- arrays: rendered lines (with original `+`/`-`/` ` prefix preserved) and
--- a row→hl_group map for DiffAdd/DiffDelete.
---@param thread table GHReviewThread
---@return string[] lines
---@return table<number, string> highlights
local function build_diff_context(thread)
  local diff_text = state.get_diff_text()
  if not diff_text or diff_text == "" then return {}, {} end

  local files = diff_module.parse(diff_text)
  local file_diff = files[thread.path]
  if not file_diff then return {}, {} end

  local side = thread.side or "RIGHT"
  local target_end = thread.line
  if not target_end then return {}, {} end
  local target_start = thread.start_line or target_end

  local out_lines = {}
  local out_hl = {}

  for _, hunk in ipairs(file_diff.hunks) do
    local old_line = hunk.old_start
    local new_line = hunk.new_start

    for _, l in ipairs(hunk.lines) do
      local prefix = l:sub(1, 1)
      local take = false
      if side == "RIGHT" and (prefix == " " or prefix == "+") then
        take = new_line >= target_start and new_line <= target_end
      elseif side == "LEFT" and (prefix == " " or prefix == "-") then
        take = old_line >= target_start and old_line <= target_end
      end
      if take then
        table.insert(out_lines, l)
        if prefix == "-" then
          out_hl[#out_lines] = "DiffDelete"
        elseif prefix == "+" then
          out_hl[#out_lines] = "DiffAdd"
        end
      end

      if prefix == "-" then
        old_line = old_line + 1
      elseif prefix == "+" then
        new_line = new_line + 1
      else
        old_line = old_line + 1
        new_line = new_line + 1
      end
    end

    if #out_lines > 0 then return out_lines, out_hl end
  end

  return {}, {}
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
  local loc = thread.path
  if thread.start_line and thread.line and thread.start_line ~= thread.line then
    loc = loc .. ":" .. thread.start_line .. "-" .. thread.line
  else
    loc = loc .. ":" .. (thread.line or thread.mapped_line or "?")
  end
  table.insert(lines, "File: " .. loc)
  table.insert(lines, "")

  -- Diff context: the hunk the comment points to, with a ▶ marker on the
  -- exact line(s) being discussed.
  local diff_lines, diff_hl = build_diff_context(thread)
  if #diff_lines > 0 then
    for i, dl in ipairs(diff_lines) do
      table.insert(lines, dl)
      if diff_hl[i] then
        table.insert(highlights, { line = #lines, hl = diff_hl[i] })
      end
    end
    table.insert(lines, "")
  end

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
