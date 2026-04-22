--- mini.diff integration for PR review gutter signs and overlay
local M = {}

local state = require("gh-review.state")
local util = require("gh-review.util")

local ref_cache = {} -- buf_id → { path = string, lines = string[] }

-- User's current overlay preference. Tracked at session scope so opening a
-- new file (via any path — picker, :edit, ]d, etc.) can restore the overlay
-- state the user last chose, without them having to press D every time.
local overlay_preference = false

--- Set mini.diff reference text for a buffer from the PR base.
--- Called on every BufEnter for PR files. The git show result is cached,
--- but set_ref_text is always re-called since :edit triggers on_detach
--- which disables the buffer in mini.diff.
--- Returns true iff mini.diff was actually attached (i.e. the buffer belongs
--- to the active PR and the base content was fetched). Callers use this to
--- decide whether it's safe to flip buffer-specific mini.diff state.
---@param buf number
---@param opts? { rel_path?: string } rel_path lets callers attach to scratch
---  buffers (e.g. ghreview://commit/...) whose name doesn't match cwd/rel.
---@return boolean attached
function M.attach(buf, opts)
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return false end

  local pr = state.get_pr()
  if not pr then return false end

  local rel
  if opts and opts.rel_path then
    rel = opts.rel_path
  else
    local filepath = vim.api.nvim_buf_get_name(buf)
    local cwd = vim.fn.getcwd()
    rel = filepath:sub(#cwd + 2)
  end

  -- Only attach to files that are part of the effective file set
  local found = false
  for _, f in ipairs(state.get_effective_files()) do
    if f.path == rel then found = true; break end
  end
  if not found then return false end

  -- Determine base ref: commit parent, or merge-base SHA (matches GitHub's three-dot
  -- view), falling back to the branch name only if merge-base lookup failed at load time.
  local active_commit = state.get_active_commit()
  local base_ref = active_commit and (active_commit.oid .. "~1") or pr.base_sha or pr.base_ref
  local cache_key = base_ref .. ":" .. rel

  -- Get base content (cached per buffer)
  local cached = ref_cache[buf]
  if not cached or cached.path ~= cache_key then
    local lines = util.git_show_lines(base_ref .. ":" .. rel, vim.fn.getcwd())
    if #lines == 0 then return false end
    ref_cache[buf] = { path = cache_key, lines = lines }
  end

  -- Override source to a no-op so the git source doesn't run and
  -- asynchronously overwrite our PR-base ref text.
  vim.b[buf].minidiff_config = {
    source = { attach = function() end, detach = function() end, name = "gh-review" },
  }

  -- set_ref_text auto-enables if the buffer isn't enabled yet
  pcall(MiniDiff.set_ref_text, buf, ref_cache[buf].lines)
  return true
end

--- Force the overlay to a specific state (on or off). Records the choice as
--- the new session preference so future file opens restore the same state.
--- Queries mini.diff's buffer data to avoid toggling when already in the desired state.
--- Schedules a redraw so the overlay extmarks paint even if a floating
--- window (e.g. the snacks picker) is still open — otherwise the first
--- open from the file tree renders late.
---@param buf number
---@param enable boolean
function M.set_overlay(buf, enable)
  overlay_preference = enable
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return end
  local data_ok, data = pcall(MiniDiff.get_buf_data, buf)
  local currently_on = data_ok and data and data.overlay == true
  if enable == currently_on then return end
  pcall(MiniDiff.toggle_overlay, buf)
  vim.schedule(function() pcall(vim.cmd, "redraw") end)
end

--- Return the current overlay preference (true = user wants the overlay on
--- for PR files, false = off). Used by the BufEnter autocmd to auto-apply
--- on newly-entered PR buffers.
---@return boolean
function M.get_overlay_preference()
  return overlay_preference
end

--- Apply the overlay preference to a buffer the first time we see it.
--- Subsequent BufEnter events (e.g. exiting a floating window back to this
--- buffer) are no-ops, so a state the user explicitly changed (pressing D
--- to turn off, for example) isn't forcibly reset by the autocmd.
--- Uses a buffer-local variable so the flag is scoped to the buffer and
--- cleaned up automatically when the buffer is wiped.
---@param buf number
function M.apply_overlay_on_first_entry(buf)
  if vim.b[buf].gh_review_overlay_initialized then return end
  vim.b[buf].gh_review_overlay_initialized = true
  if overlay_preference then
    M.set_overlay(buf, true)
  end
end

--- Toggle overlay on current buffer. Flips the session preference so future
--- files follow suit.
function M.toggle_overlay()
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then
    vim.notify("GHReview: mini.diff not installed", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  -- Re-attach to ensure buffer is enabled (may have been reset by :edit)
  M.attach(buf)
  local success, err = pcall(MiniDiff.toggle_overlay, buf)
  if success then
    overlay_preference = not overlay_preference
  else
    vim.notify("GHReview: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Re-apply the cached ref_text for every attached PR buffer so mini.diff
--- recomputes its hunks. Used when a global toggle (e.g. ignore-whitespace)
--- changes how vim.diff should interpret the reference.
function M.refresh_all()
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return end
  for buf, cached in pairs(ref_cache) do
    if vim.api.nvim_buf_is_valid(buf) and cached and cached.lines then
      pcall(MiniDiff.set_ref_text, buf, cached.lines)
    end
  end
end

--- Disable mini.diff on all tracked buffers and restore default source
function M.detach_all()
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return end
  for buf, _ in pairs(ref_cache) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(MiniDiff.disable, buf)
      vim.b[buf].minidiff_config = nil
      vim.b[buf].gh_review_overlay_initialized = nil
    end
  end
  ref_cache = {}
  overlay_preference = false
end

return M
