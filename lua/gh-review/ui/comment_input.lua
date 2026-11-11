--- Scratch buffer for writing replies and new comment threads.
--- Opens in a bottom horizontal split so the underlying diff stays visible
--- while composing.
local M = {}

local config = require("gh-review.config")

---@class GHReviewCommentInputOpts
---@field title string
---@field on_submit fun(body: string)
---@field on_cancel? fun()
---@field context_lines? string[] Read-only lines shown above the input (reply context)
---@field allow_empty? boolean
---@field body_lines? string[] Initial content of the input
---@field cursor_line? number Line of `body_lines` to put the cursor on (1-based, default 1)
---@field suggestion_lines? string[] The commented lines; enables the key that inserts a suggestion block of them

--- Open a scratch buffer for composing a comment
---@param opts GHReviewCommentInputOpts
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  -- Markdown for the highlighting, but no diagnostics: linters and the
  -- markdown LSP attach on the filetype and would flag a comment draft
  -- (line length, heading rules) that GitHub renders fine.
  vim.diagnostic.enable(false, { bufnr = buf })
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false

  local cfg = config.get()

  -- Build initial content: a header hint line, optional reply context, then an
  -- empty input line. The header is a real buffer line (reliably rendered,
  -- unlike virtual lines above row 0) and is excluded from the submitted body.
  local suggestion_key = opts.suggestion_lines and cfg.input_keys.suggestion or nil
  local cancel_key = cfg.input_keys.cancel
  local hints = { "C-s submit" }
  if suggestion_key then table.insert(hints, suggestion_key .. " suggestion") end
  if cancel_key and cancel_key ~= "" then table.insert(hints, cancel_key .. " cancel") end
  local hint = table.concat(hints, " · ")
  local header = opts.title .. "  (" .. hint .. ")"
  local init_lines = { header }
  if opts.context_lines and #opts.context_lines > 0 then
    vim.list_extend(init_lines, opts.context_lines)
    table.insert(init_lines, string.rep("─", 72))
  end
  local input_start = #init_lines -- 0-indexed line where the input begins
  vim.list_extend(init_lines, opts.body_lines or { "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)

  -- Bottom split sized to fit header + context + a reasonable input area,
  -- capped by config.float.max_height so very large replies don't dominate.
  local context_height = math.min(input_start, 20)
  local height = math.min(10 + context_height, cfg.float.max_height)

  vim.cmd("botright " .. height .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- Window-local display polish
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixheight = true
  pcall(vim.api.nvim_buf_set_name, buf, "gh-review://compose/" .. opts.title)

  -- Highlight the header line and any reply context as dimmed, then drop the
  -- cursor onto the empty input line below them.
  local ns = vim.api.nvim_create_namespace("gh_review_input_ctx")
  vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
  for i = 1, input_start - 1 do
    vim.api.nvim_buf_add_highlight(buf, ns, "Comment", i, 0, -1)
  end
  vim.api.nvim_win_set_cursor(win, { input_start + (opts.cursor_line or 1), 0 })

  vim.cmd("startinsert")

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-s>", function()
      local lines = vim.api.nvim_buf_get_lines(buf, input_start, -1, false)
      local body = vim.trim(table.concat(lines, "\n"))
      close()
      -- Some submissions are meaningful without a body (approving a review),
      -- so callers can opt into accepting an empty one.
      if body ~= "" or opts.allow_empty then
        opts.on_submit(body)
      else
        vim.notify("Empty comment, not submitted", vim.log.levels.WARN)
      end
    end, { buffer = buf, nowait = true })
  end

  -- Insert a suggestion block of the commented lines below the cursor, and
  -- move the cursor onto its first line of code.
  if suggestion_key then
    vim.keymap.set({ "n", "i" }, suggestion_key, function()
      local row = math.max(vim.api.nvim_win_get_cursor(win)[1], input_start + 1)
      local block = require("gh-review.util").suggestion_block(opts.suggestion_lines)
      vim.api.nvim_buf_set_lines(buf, row, row, false, block)
      vim.api.nvim_win_set_cursor(win, { row + 2, 0 })
    end, { buffer = buf, nowait = true, desc = "Insert a suggestion block" })
  end

  -- Cancel from normal mode; <Esc> keeps its usual meaning.
  if cancel_key and cancel_key ~= "" then
    vim.keymap.set("n", cancel_key, function()
      close()
      if opts.on_cancel then
        opts.on_cancel()
      end
    end, { buffer = buf, nowait = true, desc = "Cancel the comment" })
  end

  return win, buf
end

return M
