--- vim.diagnostic bridge for PR review comment markers
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

local NS = vim.api.nvim_create_namespace("gh_review_comments")

--- Refresh diagnostics for a specific buffer
---@param bufnr number
function M.refresh_buf(bufnr)
  if not state.is_active() then
    vim.diagnostic.reset(NS, bufnr)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  -- Get path relative to cwd
  local cwd = vim.fn.getcwd()
  local rel_path = filepath
  if filepath:sub(1, #cwd) == cwd then
    rel_path = filepath:sub(#cwd + 2) -- +2 to skip the /
  end

  local threads = state.get_threads_for_file(rel_path)
  if #threads == 0 then
    vim.diagnostic.reset(NS, bufnr)
    return
  end

  local diagnostics = {}
  local cfg = config.get()
  for _, thread in ipairs(threads) do
    local line = thread.mapped_line
    if line and line > 0 then
      local first_comment = thread.comments[1]
      local body = first_comment and first_comment.body or ""
      -- Truncate for virtual text
      local short = body:match("^([^\n]+)") or body
      if #short > 80 then
        short = short:sub(1, 77) .. "..."
      end

      local msg = short
      if thread.is_resolved then
        msg = "[resolved] " .. msg
      end

      table.insert(diagnostics, {
        lnum = line - 1, -- 0-indexed
        col = 0,
        message = msg,
        severity = cfg.diagnostics.severity,
        source = "gh-review",
        user_data = { thread_id = thread.id },
      })
    end
  end

  vim.diagnostic.set(NS, bufnr, diagnostics)
end

--- Refresh diagnostics for all loaded buffers
function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      M.refresh_buf(bufnr)
    end
  end
end

--- Clear all diagnostics
function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    vim.diagnostic.reset(NS, bufnr)
  end
end

--- Set up BufEnter autocommand to refresh diagnostics
function M.setup()
  local group = vim.api.nvim_create_augroup("GHReviewDiagnostics", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if state.is_active() and vim.bo[args.buf].buftype == "" then
        M.refresh_buf(args.buf)
        require("gh-review.ui.minidiff").attach(args.buf)
      end
    end,
  })
end

--- Get the namespace ID (for external use)
function M.namespace()
  return NS
end

return M
