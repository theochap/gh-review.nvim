--- Scratch buffer for writing replies and new comment threads.
--- Opens in a bottom horizontal split so the underlying diff stays visible
--- while composing.
local M = {}

local config = require("gh-review.config")

--- Open a scratch buffer for composing a comment
---@param opts { title: string, on_submit: fun(body: string), on_cancel?: fun(), context_lines?: string[], allow_empty?: boolean }
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false

  local cfg = config.get()

  -- Build initial content: a header hint line, optional reply context, then an
  -- empty input line. The header is a real buffer line (reliably rendered,
  -- unlike virtual lines above row 0) and is excluded from the submitted body.
  local header = opts.title .. "  (C-s submit · Esc Esc cancel)"
  local init_lines = { header }
  if opts.context_lines and #opts.context_lines > 0 then
    vim.list_extend(init_lines, opts.context_lines)
    table.insert(init_lines, string.rep("─", 72))
  end
  table.insert(init_lines, "") -- empty input line
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)
  local input_start = #init_lines - 1 -- 0-indexed line of the empty input line

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
  vim.api.nvim_win_set_cursor(win, { input_start + 1, 0 })

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

  local esc_count = 0
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    esc_count = esc_count + 1
    if esc_count >= 2 then
      close()
      if opts.on_cancel then
        opts.on_cancel()
      end
    else
      if vim.fn.mode() == "i" then
        vim.cmd("stopinsert")
      end
      vim.defer_fn(function()
        esc_count = 0
      end, 500)
    end
  end, { buffer = buf, nowait = true })

  return win, buf
end

return M
