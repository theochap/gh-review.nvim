--- vim.diagnostic bridge for PR review comment markers
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

local NS = vim.api.nvim_create_namespace("gh_review_comments")

--- Extract the relative file path from a buffer name.
--- Handles both real file paths and ghreview:// scratch buffers.
---@param bufnr number
---@return string? rel_path
---@return boolean is_commit_buf Whether this is a commit diff buffer
local function get_rel_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- ghreview://commit/<sha>/<path> — commit diff right side
  local commit_path = name:match("^ghreview://commit/[^/]+/(.+)$")
  if commit_path then
    return commit_path, true
  end
  -- Regular file — make relative to cwd
  local cwd = vim.fn.getcwd()
  if name:sub(1, #cwd) == cwd then
    return name:sub(#cwd + 2), false
  end
  return name, false
end

--- Refresh diagnostics for a specific buffer
---@param bufnr number
function M.refresh_buf(bufnr)
  if not state.is_active() then
    vim.diagnostic.reset(NS, bufnr)
    return
  end

  local rel_path, is_commit_buf = get_rel_path(bufnr)
  if not rel_path then
    vim.diagnostic.reset(NS, bufnr)
    return
  end

  local threads = state.get_effective_threads_for_file(rel_path)
  if #threads == 0 then
    vim.diagnostic.reset(NS, bufnr)
    return
  end

  local diagnostics = {}
  local cfg = config.get()
  for _, thread in ipairs(threads) do
    -- For commit diff buffers, use the original thread.line (no working tree mapping)
    -- For regular buffers, use mapped_line (mapped to working tree)
    local line = is_commit_buf and thread.line or thread.mapped_line
    if line and type(line) == "number" and line > 0 then
      local first_comment = thread.comments[1]
      local body = first_comment and first_comment.body or ""
      -- Truncate for virtual text
      local short = body:match("^([^\n]+)") or body
      if #short > 80 then
        short = short:sub(1, 77) .. "..."
      end

      local msg = short
      local severity = cfg.diagnostics.severity
      if thread.is_resolved then
        msg = "[resolved] " .. msg
        severity = vim.diagnostic.severity.HINT
      end

      table.insert(diagnostics, {
        lnum = line - 1, -- 0-indexed
        col = 0,
        message = msg,
        severity = severity,
        source = "gh-review",
        user_data = { thread_id = thread.id },
      })
    end
  end

  vim.diagnostic.set(NS, bufnr, diagnostics)
end

--- Check if a buffer should have diagnostics
---@param bufnr number
---@return boolean
local function should_have_diagnostics(bufnr)
  if vim.bo[bufnr].buftype == "" then
    return true
  end
  -- Commit diff right-side buffers
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("^ghreview://commit/") ~= nil
end

--- Refresh diagnostics for all loaded buffers
function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and should_have_diagnostics(bufnr) then
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
      if state.is_active() and should_have_diagnostics(args.buf) then
        M.refresh_buf(args.buf)
        if vim.bo[args.buf].buftype == "" then
          require("gh-review.ui.minidiff").attach(args.buf)
        end
      end
    end,
  })
end

--- Get the namespace ID (for external use)
function M.namespace()
  return NS
end

return M
