--- Floating window with the checks of one PR: failing jobs first, then pending,
--- passing and skipped. Opens at once with a loading line, and fills in when
--- the checks arrive.
local M = {}

local config = require("gh-review.config")

---@type table<string, { group: number, icon: string, hl: string }>
local STATES = {
  FAILURE = { group = 1, icon = "✗", hl = "DiagnosticError" },
  ERROR = { group = 1, icon = "✗", hl = "DiagnosticError" },
  TIMED_OUT = { group = 1, icon = "✗", hl = "DiagnosticError" },
  STARTUP_FAILURE = { group = 1, icon = "✗", hl = "DiagnosticError" },
  ACTION_REQUIRED = { group = 1, icon = "!", hl = "DiagnosticError" },
  CANCELLED = { group = 1, icon = "⊘", hl = "DiagnosticWarn" },
  PENDING = { group = 2, icon = "◔", hl = "DiagnosticWarn" },
  SUCCESS = { group = 3, icon = "✓", hl = "DiagnosticOk" },
  NEUTRAL = { group = 4, icon = "○", hl = "Comment" },
  SKIPPED = { group = 4, icon = "○", hl = "Comment" },
  STALE = { group = 4, icon = "○", hl = "Comment" },
}
local GROUPS = { "Failing", "Pending", "Passed", "Skipped / neutral" }

---@param check GHReviewCheck
local function state_of(check)
  return STATES[check.state] or STATES.NEUTRAL
end

--- Build the window lines, with highlights and the URL of each check line.
---@param pr { number: number, title: string, head_oid?: string }
---@param checks GHReviewCheck[]
---@return string[] lines, table[] highlights, table<number, string> urls
function M.build(pr, checks)
  local lines = { "#" .. pr.number .. " " .. pr.title }
  local hls, urls = { { 0, "Title" } }, {}

  local groups = { {}, {}, {}, {} }
  for _, c in ipairs(checks) do
    table.insert(groups[state_of(c).group], c)
  end
  for _, g in ipairs(groups) do
    table.sort(g, function(a, b)
      if a.required ~= b.required then return a.required end
      return (a.workflow or "") .. a.name < (b.workflow or "") .. b.name
    end)
  end

  local counts = {}
  for i, g in ipairs(groups) do
    if #g > 0 then table.insert(counts, #g .. " " .. GROUPS[i]:lower()) end
  end
  local head = pr.head_oid and ("head " .. pr.head_oid:sub(1, 8) .. " · ") or ""
  table.insert(lines, head .. (#checks == 0 and "no checks" or table.concat(counts, " · ")))
  table.insert(hls, { 1, "Comment" })

  for i, g in ipairs(groups) do
    if #g > 0 then
      table.insert(lines, "")
      table.insert(lines, GROUPS[i] .. " (" .. #g .. ")")
      table.insert(hls, { #lines - 1, "Title" })
      for _, c in ipairs(g) do
        local st = state_of(c)
        local name = c.workflow and (c.workflow .. " / " .. c.name) or c.name
        table.insert(lines, "  " .. st.icon .. " " .. name .. (c.required and "  (required)" or ""))
        table.insert(hls, { #lines - 1, st.hl })
        urls[#lines] = c.url
      end
    end
  end
  table.insert(lines, "")
  table.insert(lines, "<cr> open job · R refresh · q close")
  table.insert(hls, { #lines - 1, "Comment" })
  return lines, hls, urls
end

local NS = vim.api.nvim_create_namespace("gh_review_pr_checks")

---@class GHReviewChecksWindow
---@field buf number
---@field win number
---@field set fun(result: { head_oid?: string, checks: GHReviewCheck[] })
---@field set_error fun(err: string)
---@field close fun()

--- Open the window in a loading state.
---@param pr { number: number, title: string, head_oid?: string }
---@param opts { on_refresh: fun() }
---@return GHReviewChecksWindow
function M.open(pr, opts)
  local prev_win = vim.api.nvim_get_current_win()
  local fcfg = config.get().float
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(fcfg.max_width, math.max(40, vim.o.columns - 10))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 3,
    row = 3,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = fcfg.border,
    title = " Checks #" .. pr.number .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local urls = {}
  local handle = {}
  handle.buf, handle.win = buf, win

  local function render(lines, hls)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, NS, h[1], 0, { line_hl_group = h[2] })
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, math.min(#lines, fcfg.max_height))
    end
  end

  function handle.set(result)
    local lines, hls
    lines, hls, urls = M.build(vim.tbl_extend("force", pr, { head_oid = result.head_oid or pr.head_oid }), result.checks)
    render(lines, hls)
    -- Land on the first failing (or otherwise first) check.
    for lnum = 1, #lines do
      if urls[lnum] and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { lnum, 0 })
        break
      end
    end
  end

  function handle.set_error(err)
    urls = {}
    render({ "#" .. pr.number .. " " .. pr.title, "", "Could not load checks: " .. err }, { { 2, "DiagnosticError" } })
  end

  function handle.close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(prev_win) then vim.api.nvim_set_current_win(prev_win) end
  end

  render({ "#" .. pr.number .. " " .. pr.title, "", "Loading checks…" }, { { 2, "Comment" } })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", handle.close)
  map("<esc>", handle.close)
  local function open_url()
    local url = urls[vim.api.nvim_win_get_cursor(win)[1]]
    if url then vim.ui.open(url) end
  end
  map("<cr>", open_url)
  map("o", open_url)
  map("R", function()
    render({ "#" .. pr.number .. " " .. pr.title, "", "Loading checks…" }, { { 2, "Comment" } })
    opts.on_refresh()
  end)
  return handle
end

return M
