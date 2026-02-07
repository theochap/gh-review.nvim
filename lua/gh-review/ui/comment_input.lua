--- Scratch buffer for writing replies and new comment threads
local M = {}

local config = require("gh-review.config")

--- Open a scratch buffer for composing a comment
---@param opts { title: string, on_submit: fun(body: string), on_cancel?: fun() }
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false

  local cfg = config.get()
  local width = math.min(80, cfg.float.max_width)
  local height = math.min(15, cfg.float.max_height)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = cfg.float.border,
    title = " " .. opts.title .. " ",
    title_pos = "center",
    footer = " Ctrl-S: submit | Esc Esc: cancel ",
    footer_pos = "center",
  })

  -- Start in insert mode
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

  -- Submit: Ctrl-S
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-s>", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local body = vim.trim(table.concat(lines, "\n"))
      close()
      if body ~= "" then
        opts.on_submit(body)
      else
        vim.notify("Empty comment, not submitted", vim.log.levels.WARN)
      end
    end, { buffer = buf, nowait = true })
  end

  -- Cancel: double Esc
  local esc_count = 0
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    esc_count = esc_count + 1
    if esc_count >= 2 then
      close()
      if opts.on_cancel then
        opts.on_cancel()
      end
    else
      -- First Esc: exit insert mode if in insert, reset timer
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
