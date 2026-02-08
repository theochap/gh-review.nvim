--- mini.diff integration for PR review gutter signs and overlay
local M = {}

local state = require("gh-review.state")

local ref_cache = {} -- buf_id → { path = string, lines = string[] }

--- Set mini.diff reference text for a buffer from the PR base.
--- Called on every BufEnter for PR files. The git show result is cached,
--- but set_ref_text is always re-called since :edit triggers on_detach
--- which disables the buffer in mini.diff.
---@param buf number
function M.attach(buf)
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return end

  local pr = state.get_pr()
  if not pr then return end

  local filepath = vim.api.nvim_buf_get_name(buf)
  local cwd = vim.fn.getcwd()
  local rel = filepath:sub(#cwd + 2)

  -- Only attach to files that are part of the PR
  local found = false
  for _, f in ipairs(state.get_files()) do
    if f.path == rel then found = true; break end
  end
  if not found then return end

  -- Get base content (cached per buffer)
  local cached = ref_cache[buf]
  if not cached or cached.path ~= rel then
    local result = vim.system(
      { "git", "show", pr.base_ref .. ":" .. rel },
      { text = true, cwd = cwd }
    ):wait()
    if result.code ~= 0 then return end
    local lines = vim.split(result.stdout or "", "\n")
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    ref_cache[buf] = { path = rel, lines = lines }
  end

  -- Override source to a no-op so the git source doesn't run and
  -- asynchronously overwrite our PR-base ref text.
  vim.b[buf].minidiff_config = {
    source = { attach = function() end, detach = function() end, name = "gh-review" },
  }

  -- set_ref_text auto-enables if the buffer isn't enabled yet
  pcall(MiniDiff.set_ref_text, buf, ref_cache[buf].lines)
end

--- Toggle overlay on current buffer
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
  if not success then
    vim.notify("GHReview: " .. tostring(err), vim.log.levels.WARN)
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
    end
  end
  ref_cache = {}
end

return M
