--- Floating panel listing the unsubmitted (pending) review comments, with
--- keys to publish them all in one go.
local M = {}

local config = require("gh-review.config")

--- Location label for a pending comment ("path:line", or just "path" when
--- GitHub gave us no line to anchor to).
---@param comment table
---@return string
local function location(comment)
  local path = comment.path or "?"
  if not comment.line then return path end
  if comment.start_line and comment.start_line ~= comment.line then
    return path .. ":" .. comment.start_line .. "-" .. comment.line
  end
  return path .. ":" .. comment.line
end

--- Render the panel contents.
---@param review table from graphql.fetch_pending_review
---@return string[] lines
---@return table[] highlights each { line: number, hl: string }
---@return table<number, table> comment_at maps buffer line → comment
local function render(review)
  local lines, highlights, comment_at = {}, {}, {}

  local count = #review.comments
  table.insert(lines, ("── Pending review · %d comment%s ──"):format(count, count == 1 and "" or "s"))
  table.insert(highlights, { line = #lines, hl = "Title" })
  table.insert(lines, "Not published yet — submit to make these visible on GitHub.")
  table.insert(highlights, { line = #lines, hl = "Comment" })
  if review.total_count and review.total_count > count then
    table.insert(lines, ("(showing the first %d of %d)"):format(count, review.total_count))
    table.insert(highlights, { line = #lines, hl = "WarningMsg" })
  end
  table.insert(lines, "")

  for i, comment in ipairs(review.comments) do
    local header = ("%d. %s"):format(i, location(comment))
    if comment.is_outdated then header = header .. "  [outdated]" end
    table.insert(lines, header)
    table.insert(highlights, { line = #lines, hl = "Special" })
    comment_at[#lines] = comment

    for _, body_line in ipairs(vim.split(comment.body, "\n", { plain = true })) do
      table.insert(lines, "  " .. body_line)
      comment_at[#lines] = comment
    end

    if i < count then table.insert(lines, "") end
  end

  table.insert(lines, "")
  table.insert(lines, "── <cr>: jump  s: comment  a: approve  x: request changes  q: close ──")
  table.insert(highlights, { line = #lines, hl = "Comment" })

  return lines, highlights, comment_at
end

--- Show the pending review panel.
---@param review table from graphql.fetch_pending_review
---@param opts? { on_jump?: fun(comment: table), on_submit?: fun(event: string) }
---@return number? win, number? buf
function M.show(review, opts)
  opts = opts or {}
  local lines, highlights, comment_at = render(review)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "gh-review-pending"

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, hl.hl, hl.line - 1, 0, -1)
  end

  local cfg = config.get()
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, cfg.float.max_width)
  local height = math.min(#lines, cfg.float.max_height)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = cfg.float.border,
    title = " Unsubmitted Review Comments ",
    title_pos = "center",
  })
  vim.wo[win].winhighlight = "Normal:NormalFloat,CursorLine:CursorLine"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local kopts = { buffer = buf, nowait = true, silent = true }
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, kopts)

  vim.keymap.set("n", "<cr>", function()
    local comment = comment_at[vim.api.nvim_win_get_cursor(win)[1]]
    close()
    if comment and opts.on_jump then opts.on_jump(comment) end
  end, kopts)

  local events = { s = "COMMENT", a = "APPROVE", x = "REQUEST_CHANGES" }
  for key, event in pairs(events) do
    vim.keymap.set("n", key, function()
      close()
      if opts.on_submit then opts.on_submit(event) end
    end, kopts)
  end

  return win, buf
end

M._render = render

return M
