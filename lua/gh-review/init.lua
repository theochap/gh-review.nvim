--- gh-review.nvim — Public API
local M = {}

local config = require("gh-review.config")
local state = require("gh-review.state")
local gh = require("gh-review.gh")
local graphql = require("gh-review.graphql")
local diff = require("gh-review.diff")
local diagnostics = require("gh-review.ui.diagnostics")
local util = require("gh-review.util")
local vcs = require("gh-review.vcs")

--- Guard: return true (and notify) if no active review
---@return boolean
local function require_active()
  if not state.is_active() then
    vim.notify("GHReview: no active review", vim.log.levels.WARN)
    return false
  end
  return true
end

--- Close all snacks pickers for a given source
---@param source string
local function close_snacks_picker(source)
  pcall(function()
    local Snacks = require("snacks")
    local pickers = Snacks.picker.get({ source = source })
    for _, p in ipairs(pickers) do p:close() end
  end)
end

--- Apply gh-review's overlay highlight tweaks:
---   - MiniDiffOverContext → DiffDelete so the reference-side context block
---     shares the red tint with pure deletions.
---   - MiniDiffOverChange → an explicit orange background so the actually-
---     changed characters within a line pop against the surrounding red,
---     instead of the default DiffText blue which can clash with it.
--- A light/dark-appropriate shade is picked from `vim.o.background`.
function M._apply_overlay_highlights()
  vim.api.nvim_set_hl(0, "MiniDiffOverContext", { link = "DiffDelete" })
  local orange_bg = vim.o.background == "light" and "#ffd8a8" or "#5a3a1a"
  vim.api.nvim_set_hl(0, "MiniDiffOverChange", { bg = orange_bg })
end

--- Plugin setup
---@param user_config? table
function M.setup(user_config)
  config.setup(user_config)
  diagnostics.setup()
  M._setup_keymaps()

  -- Register which-key group
  vim.schedule(function()
    require("gh-review.integrations.which_key").register()
  end)

  -- Apply overlay highlight tweaks now, and re-apply after any colorscheme
  -- change (colorschemes typically re-run MiniDiff's default highlight setup,
  -- which would otherwise revert our links).
  M._apply_overlay_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("GHReviewHighlights", { clear = true }),
    callback = function() M._apply_overlay_highlights() end,
  })

  -- The detected VCS layout (git worktree vs. jj workspace) is cached per
  -- directory; drop it when the cwd changes so a new repo is re-detected.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup("GHReviewVcs", { clear = true }),
    callback = function() vcs.invalidate() end,
  })

  -- Auto-detect PR for current branch after startup
  M._schedule_pr_detection()
end

--- Check if the current branch has an open PR and notify the user
M._pr_detection_notified = false

function M._schedule_pr_detection()
  local function check()
    if M._pr_detection_notified or state.is_active() then return end
    gh.pr_view_current(function(err, data)
      if err or not data then return end
      if M._pr_detection_notified or state.is_active() then return end
      M._pr_detection_notified = true
      local km = config.get().keymaps
      vim.notify(
        string.format("GHReview: PR #%d found — %s (use %s%s to review)", data.number, data.title, km.prefix, km.review_current),
        vim.log.levels.INFO
      )
    end)
  end

  if vim.v.vim_did_enter == 1 then
    -- Plugin loaded after startup (e.g. by lazy.nvim) — defer directly
    vim.defer_fn(check, 100)
  else
    -- Plugin loaded during startup — wait for VimEnter
    vim.api.nvim_create_autocmd("VimEnter", {
      callback = function() vim.defer_fn(check, 100) end,
      once = true,
    })
  end
end

--- Checkout a PR and load all review data
---@param pr_number number
function M.checkout(pr_number)
  vim.notify("GHReview: checking out PR #" .. pr_number .. "...", vim.log.levels.INFO)

  gh.checkout(pr_number, function(err)
    if err then
      vim.notify("GHReview: checkout failed: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.notify("GHReview: checked out PR #" .. pr_number, vim.log.levels.INFO)
    M._load_pr_data(pr_number)
  end)
end

--- Load PR metadata, files, diff, and threads
---@param pr_number number
---@param callback? fun()
function M._load_pr_data(pr_number, callback)
  -- 5 parallel operations: metadata chain, files, diff, comments, commits
  local pending = 5
  local errors = {}

  local function done()
    pending = pending - 1
    if pending > 0 then return end

    if #errors > 0 then
      vim.notify("GHReview: errors loading PR data:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
      return
    end

    -- Map thread line numbers using diff data
    local diff_files = diff.parse(state.get_diff_text())
    local threads = diff.map_threads(state.get_threads(), diff_files)
    state.set_threads(threads)

    -- Refresh diagnostics
    diagnostics.refresh_all()

    -- Refresh trouble if open
    pcall(function()
      local trouble = require("trouble")
      if trouble.is_open("gh_review") then
        trouble.refresh("gh_review")
      end
    end)

    vim.notify("GHReview: loaded " .. #state.get_files() .. " files, " .. #state.get_threads() .. " threads", vim.log.levels.INFO)

    if callback then callback() end
  end

  -- PR metadata chain: pr_view → repo_name → fetch_threads
  -- Counted as ONE pending item — done() is called exactly once at the end
  gh.pr_view(pr_number, function(err, data)
    if err then
      table.insert(errors, "metadata: " .. err)
      done()
      return
    end
    if not data then
      table.insert(errors, "metadata: empty response")
      done()
      return
    end

    gh.repo_name(function(repo_err, repo)
      if repo_err then
        table.insert(errors, "repo: " .. repo_err)
        done()
        return
      end

      state.set_pr({
        number = data.number,
        title = data.title,
        author = data.author and data.author.login or "unknown",
        base_ref = data.baseRefName,
        base_sha = util.git_merge_base(data.baseRefName, vim.fn.getcwd()),
        head_ref = data.headRefName,
        head_sha = type(data.headRefOid) == "string" and data.headRefOid or nil,
        url = data.url,
        body = data.body or "",
        review_decision = data.reviewDecision or "",
        repository = repo,
      })

      -- Seed view mode from config only on first PR load of the session
      -- so a user's toggle choice persists across refreshes.
      if not state.get_view_mode() then
        state.set_view_mode(config.get().default_view_mode or "split")
      end

      -- Apply default ignore-whitespace preference. Done inside the PR-id
      -- branch (rather than at plugin setup) so it only takes effect while a
      -- review is active; M.close reliably unwinds it.
      if config.get().default_ignore_whitespace and not util.ignore_whitespace_active() then
        util.enable_ignore_whitespace()
      end

      local owner, repo_name = repo:match("^(.+)/(.+)$")
      if not owner or not repo_name then
        table.insert(errors, "invalid repo format: " .. (repo or "nil"))
        done()
        return
      end

      -- Fetch PR node ID for mutations (fire and forget)
      graphql.fetch_pr_id(owner, repo_name, pr_number, function(id_err, pr_id)
        if id_err then
          table.insert(errors, "pr_id: " .. id_err)
        else
          local pr = state.get_pr()
          if pr then
            pr.node_id = pr_id
          end
        end
      end)

      -- Fetch threads — this is the terminal done() for the chain
      graphql.fetch_threads(owner, repo_name, pr_number, function(t_err, threads)
        if t_err then
          table.insert(errors, "threads: " .. t_err)
        else
          state.set_threads(threads or {})
        end
        done()
      end)
    end)
  end)

  -- PR files
  gh.pr_files(pr_number, function(err, files)
    if err then
      table.insert(errors, "files: " .. err)
    else
      local parsed = {}
      for _, f in ipairs(files or {}) do
        table.insert(parsed, {
          path = f.path,
          status = (f.status or "modified"):lower(),
          additions = f.additions or 0,
          deletions = f.deletions or 0,
          old_path = f.previousFilename,
        })
      end
      state.set_files(parsed)
    end
    done()
  end)

  -- PR diff
  gh.pr_diff(pr_number, function(err, diff_text)
    if err then
      table.insert(errors, "diff: " .. err)
    else
      state.set_diff_text(diff_text or "")
    end
    done()
  end)

  -- Top-level PR comments
  gh.pr_comments(pr_number, function(err, comments)
    if err then
      table.insert(errors, "comments: " .. err)
    else
      local parsed = {}
      for _, c in ipairs(comments or {}) do
        table.insert(parsed, {
          author = c.author and c.author.login or "unknown",
          body = c.body or "",
          created_at = c.createdAt or "",
          url = c.url or "",
        })
      end
      state.set_pr_comments(parsed)
    end
    done()
  end)

  -- PR commits
  gh.pr_commits(pr_number, function(err, commits)
    if err then
      table.insert(errors, "commits: " .. err)
    else
      local parsed = {}
      for _, c in ipairs(commits or {}) do
        local commit = c.commit or c
        local full_oid = c.oid or commit.oid or ""
        table.insert(parsed, {
          sha = full_oid:sub(1, 7),
          oid = full_oid,
          message = (commit.messageHeadline or commit.message or ""):match("^([^\n]+)") or "",
          author = commit.authors and commit.authors[1] and commit.authors[1].login
            or commit.author and commit.author.login
            or "unknown",
          date = commit.committedDate or commit.authoredDate or "",
        })
      end
      state.set_commits(parsed)
    end
    done()
  end)
end

--- Refresh current PR data
---@param callback? fun()
function M.refresh(callback)
  local pr = state.get_pr()
  if not pr then
    vim.notify("GHReview: no active review", vim.log.levels.WARN)
    return
  end

  vim.notify("GHReview: refreshing...", vim.log.levels.INFO)
  M._load_pr_data(pr.number, callback)
end

--- Open a PR file in whatever view mode is currently active.
--- Deleted files can only be shown in split view, so we fall back transparently.
---@param path string PR-relative file path
---@param line? number Optional cursor target line
function M._open_file(path, line)
  local diff_review = require("gh-review.ui.diff_review")
  local minidiff = require("gh-review.ui.minidiff")
  local mode = state.get_view_mode() or "split"

  if mode == "inline" then
    for _, f in ipairs(state.get_effective_files()) do
      if f.path == path and f.status == "deleted" then
        vim.notify("GHReview: inline view unavailable for deleted files; using split", vim.log.levels.INFO)
        diff_review.open(path, line)
        require("gh-review.ui.files").sync_selection(path)
        return
      end
    end
    diff_review.close()
    M._open_inline(path, line)
  else
    -- Turn off the inline overlay on the target buffer to avoid clashing
    -- virtual text on top of the split's diff highlights.
    local existing = vim.fn.bufnr(vim.fn.getcwd() .. "/" .. path)
    if existing ~= -1 then
      minidiff.set_overlay(existing, false)
    end
    diff_review.open(path, line)
  end

  require("gh-review.ui.files").sync_selection(path)
end

--- Open a PR file in inline (mini.diff overlay) view.
--- For commit-scoped review, creates a scratch buffer with the commit's file content
--- so the overlay reflects the commit vs its parent, not the working tree.
---@param path string PR-relative file path
---@param line? number Optional cursor target line
function M._open_inline(path, line)
  local pr = state.get_pr()
  if not pr then return end

  local cwd = vim.fn.getcwd()
  local active_commit = state.get_active_commit()
  local minidiff = require("gh-review.ui.minidiff")

  local buf
  if active_commit then
    local lines = util.git_show_lines(active_commit.oid .. ":" .. path, cwd)
    local short_sha = active_commit.oid:sub(1, 8)
    buf = util.create_scratch_buf("ghreview://commit/" .. short_sha .. "/" .. path, lines, path)
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. path))
    buf = vim.api.nvim_get_current_buf()
  end

  if line then
    local target = math.min(line, math.max(vim.api.nvim_buf_line_count(buf), 1))
    pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
    vim.cmd("normal! zz")
  end

  minidiff.attach(buf, { rel_path = path })
  minidiff.set_overlay(buf, true)

  -- Refresh diagnostics for commit scratch buffers (BufEnter misses them).
  if active_commit then
    diagnostics.refresh_buf(buf)
  end
end

--- Toggle between split and inline view for the current file.
--- The choice sticks for the remainder of the session (until close or config change).
function M.toggle_view()
  if not require_active() then return end

  local diff_review = require("gh-review.ui.diff_review")
  local rel_path, line

  if diff_review.is_diff_active() then
    rel_path = diff_review.get_file_path()
    local work_win = diff_review.get_work_win()
    if work_win then
      line = vim.api.nvim_win_get_cursor(work_win)[1]
    end
  else
    rel_path = M._current_rel_path()
    if rel_path then
      line = vim.api.nvim_win_get_cursor(0)[1]
    end
  end

  if not rel_path then
    vim.notify("GHReview: no active file to toggle view for", vim.log.levels.WARN)
    return
  end

  local current = state.get_view_mode() or "split"
  local new_mode = current == "split" and "inline" or "split"
  state.set_view_mode(new_mode)

  M._open_file(rel_path, line)
  vim.notify("GHReview: view mode → " .. new_mode, vim.log.levels.INFO)
end

--- Open current diff file with mini.diff overlay (legacy entry point).
--- Equivalent to switching to inline view and opening the current file.
function M.open_minidiff()
  if not require_active() then return end

  local diff_review = require("gh-review.ui.diff_review")
  local file_path = diff_review.get_file_path() or M._current_rel_path()
  if not file_path then
    vim.notify("GHReview: no file to open", vim.log.levels.WARN)
    return
  end

  state.set_view_mode("inline")
  M._open_file(file_path)
end

--- Toggle mini.diff overlay on current buffer
function M.toggle_overlay()
  if not require_active() then return end
  require("gh-review.ui.minidiff").toggle_overlay()
end

--- Toggle whitespace-only hunk filtering across the split, diffview, and
--- inline views. Flips 'diffopt' (for :diffthis-based views) and wraps
--- vim.diff (for mini.diff) so the same preference reaches every surface.
function M.toggle_ignore_whitespace()
  if not require_active() then return end
  if util.ignore_whitespace_active() then
    util.disable_ignore_whitespace()
    vim.notify("GHReview: showing all whitespace changes", vim.log.levels.INFO)
  else
    util.enable_ignore_whitespace()
    vim.notify("GHReview: hiding whitespace-only changes", vim.log.levels.INFO)
  end
  -- Force :diffthis windows to redraw and mini.diff to recompute hunks.
  pcall(vim.cmd, "diffupdate")
  require("gh-review.ui.minidiff").refresh_all()
end

--- Toggle linematch between Neovim's default (interleaved pairs with
--- DiffText highlights) and suppressed (grouped deletion/addition blocks,
--- no intra-line highlight). Applies to the split, diffview, and inline
--- views via the same mechanism as ignore_whitespace.
function M.toggle_linematch()
  if not require_active() then return end
  if util.linematch_suppressed() then
    util.restore_linematch()
    vim.notify("GHReview: linematch on (char-level highlights, interleaved pairs)", vim.log.levels.INFO)
  else
    util.suppress_linematch()
    vim.notify("GHReview: linematch off (grouped blocks)", vim.log.levels.INFO)
  end
  pcall(vim.cmd, "diffupdate")
  require("gh-review.ui.minidiff").refresh_all()
end

--- Close the review session
function M.close()
  require("gh-review.ui.minidiff").detach_all()
  diagnostics.clear_all()
  require("gh-review.ui.diff_review").close()
  close_snacks_picker("gh_review_files")
  close_snacks_picker("gh_review_commits")
  close_snacks_picker("gh_review_stack")
  -- Close trouble comments panel if open
  pcall(function() require("trouble").close("gh_review") end)
  require("gh-review.integrations.diffview").close()
  require("gh-review.ui.unified").close()
  util.disable_ignore_whitespace()
  util.restore_linematch()
  state.clear()
  vim.notify("GHReview: review session closed", vim.log.levels.INFO)
end

--- Toggle commits sidebar
function M.commits_panel()
  if not require_active() then return end
  require("gh-review.ui.commits").toggle()
end

--- Open diffview.nvim for the active PR (merge-base ... HEAD).
--- Requires diffview.nvim; warns if not installed.
function M.diffview()
  if not require_active() then return end
  require("gh-review.integrations.diffview").open()
end

--- Open the current-buffer PR file in the unified single-buffer view
--- (deletions as a block above additions as a block, VS Code-style).
function M.open_unified()
  if not require_active() then return end
  local rel = M._current_rel_path()
  if not rel then
    vim.notify("GHReview: no active file", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  require("gh-review.ui.unified").open(rel, line)
end

--- Toggle the "reviewed" mark on the current PR file. The mark is
--- session-scoped (cleared on review close) and shown in the file tree.
function M.toggle_reviewed()
  if not require_active() then return end
  local rel = M._current_rel_path()
  if not rel then
    vim.notify("GHReview: no active file", vim.log.levels.WARN)
    return
  end
  local now_reviewed = state.toggle_reviewed(rel)
  vim.notify(
    "GHReview: " .. rel .. " " .. (now_reviewed and "marked reviewed" or "unmarked"),
    vim.log.levels.INFO
  )
  -- Refresh the files picker if it's open so the mark updates immediately.
  -- Use an in-place list render (not picker:find) so the cursor stays
  -- where the user had it instead of snapping back to the top.
  pcall(function()
    local Snacks = require("snacks")
    for _, picker in ipairs(Snacks.picker.get({ source = "gh_review_files" })) do
      picker.list:set_target(picker.list.cursor, picker.list.top, { force = true })
      picker.list:update({ force = true })
    end
  end)
end

--- Open or close the file tree sidebar (no intermediate focus step).
function M.files()
  if not require_active() then return end
  require("gh-review.ui.files").open_or_close()
end

--- Focus the file tree sidebar, opening it if closed.
function M.files_focus()
  if not require_active() then return end
  require("gh-review.ui.files").focus()
end

--- Open or close the comments panel. Strict two-state toggle — closes the
--- trouble panel if it's open regardless of where the cursor is; opens it
--- otherwise. Complement to `M.comments_focus`.
function M.comments()
  if not require_active() then return end
  local trouble = require("trouble")
  if trouble.is_open("gh_review") then
    trouble.close("gh_review")
  else
    trouble.open("gh_review")
  end
end

--- Focus the comments panel, opening it if closed. Does not close when
--- already focused (use M.comments for that).
function M.comments_focus()
  if not require_active() then return end
  local trouble = require("trouble")
  if trouble.is_open("gh_review") then
    trouble.focus("gh_review")
  else
    trouble.open("gh_review")
  end
end

--- Show comment thread at or near cursor
function M.show_hover()
  if not require_active() then return end

  local rel_path = M._current_rel_path()
  if not rel_path then return end

  local thread = state.get_nearest_thread(rel_path, vim.api.nvim_win_get_cursor(0)[1])
  if not thread then
    vim.notify("GHReview: no comment thread near cursor", vim.log.levels.INFO)
    return
  end

  M._show_thread_popup(thread)
end

--- Show PR description page
function M.description()
  if not require_active() then return end
  require("gh-review.ui.description").show()
end

--- Show thread in a floating popup with reply/resolve actions
---@param thread table GHReviewThread
function M._show_thread_popup(thread)
  require("gh-review.ui.comments").show_thread(thread, {
    on_reply = function() M._reply_to_thread(thread) end,
    on_resolve = function() M._toggle_resolve(thread) end,
  })
end

--- Navigate to a thread location and show it
---@param thread table GHReviewThread
function M._goto_thread(thread)
  local line = thread.mapped_line or thread.line
  if not line then return end

  M._open_file(thread.path, line)

  vim.schedule(function()
    -- If trouble panel is open, it auto-follows; otherwise show floating popup
    if not require("trouble").is_open("gh_review") then
      M._show_thread_popup(thread)
    end
  end)
end

--- Navigate to next or previous comment in current file
---@param forward boolean true for next, false for previous
local function navigate_comment(forward)
  local fallback = forward and "]c" or "[c"

  if not state.is_active() then
    vim.cmd("normal! " .. fallback)
    return
  end

  local rel_path = M._current_rel_path()
  if not rel_path then return end

  local threads = state.get_threads_for_file(rel_path)
  if #threads == 0 then
    vim.cmd("normal! " .. fallback)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  table.sort(threads, function(a, b)
    if forward then
      return (a.mapped_line or 0) < (b.mapped_line or 0)
    else
      return (a.mapped_line or 0) > (b.mapped_line or 0)
    end
  end)

  for _, thread in ipairs(threads) do
    if thread.mapped_line then
      if forward and thread.mapped_line > cursor_line then
        M._goto_thread(thread)
        return
      elseif not forward and thread.mapped_line < cursor_line then
        M._goto_thread(thread)
        return
      end
    end
  end

  -- Wrap around
  if threads[1] and threads[1].mapped_line then
    M._goto_thread(threads[1])
  end
end

--- Jump to next comment in current file
function M.next_comment()
  navigate_comment(true)
end

--- Jump to previous comment in current file
function M.prev_comment()
  navigate_comment(false)
end

--- Find the index of the currently open diff file in state.get_files()
---@return number?, GHReviewFile[]? index (1-based) and files list, or nil if not found
function M._get_current_file_index()
  local diff_review = require("gh-review.ui.diff_review")
  local file_path = diff_review.get_file_path()
  if not file_path then return nil, nil end

  local files = state.get_effective_files()
  for i, f in ipairs(files) do
    if f.path == file_path then
      return i, files
    end
  end
  return nil, nil
end

--- Detect if cursor is at a boundary hunk (first or last) in the diff
---@param direction string "next" or "prev"
---@return boolean true if at boundary (no more hunks in this direction)
function M._at_boundary_hunk(direction)
  local diff_review = require("gh-review.ui.diff_review")
  local work_win = diff_review.get_work_win()
  if not work_win then return true end

  local motion = direction == "next" and "]c" or "[c"

  -- Save cursor, try the motion, compare, restore
  local ok, at_boundary = pcall(function()
    return vim.api.nvim_win_call(work_win, function()
      local before = vim.api.nvim_win_get_cursor(0)
      local moved = pcall(vim.cmd, "normal! " .. motion)
      local after = vim.api.nvim_win_get_cursor(0)
      -- Restore cursor
      vim.api.nvim_win_set_cursor(0, before)
      -- At boundary if motion failed or cursor didn't move
      return not moved or (before[1] == after[1] and before[2] == after[2])
    end)
  end)

  if not ok then return true end
  return at_boundary
end

--- The effective PR files in the order the file tree sidebar lists them.
--- Cross-file motions follow that order so `]d`/`[d` and `]f`/`[f` walk the
--- picker top to bottom instead of the order the API returned files in.
---@return table[] files
local function ordered_pr_files()
  return require("gh-review.ui.files").display_order(state.get_effective_files())
end

--- Pick the next/previous non-deleted file in the effective files list
--- relative to `current_rel`. Returns a file table or nil.
---@param current_rel string?
---@param forward boolean
---@return table? file
local function adjacent_pr_file(current_rel, forward)
  local files = ordered_pr_files()
  if #files == 0 then return nil end

  local idx
  if current_rel then
    for i, f in ipairs(files) do
      if f.path == current_rel then idx = i; break end
    end
  end
  if not idx then
    -- Caller is not on a known PR file — start at one end.
    idx = forward and 0 or (#files + 1)
  end

  if forward then
    for i = idx + 1, #files do
      if files[i].status ~= "deleted" then return files[i] end
    end
  else
    for i = idx - 1, 1, -1 do
      if files[i].status ~= "deleted" then return files[i] end
    end
  end
  return nil
end

--- Land the cursor on the first (forward) or last (backward) hunk of a
--- freshly opened inline buffer.
---
--- mini.diff computes hunks on a timer, so immediately after opening a file
--- its hunk list is still empty and `goto_hunk` would report "No hunks to go
--- to" and leave the cursor wherever `:edit` put it (typically the last
--- position remembered for that file). Poll briefly for the hunks to appear,
--- then jump.
---@param buf number Buffer the jump was requested for
---@param forward boolean
---@param attempt? number
local function land_on_edge_hunk_inline(buf, forward, attempt)
  attempt = attempt or 1
  local ok, MiniDiff = pcall(require, "mini.diff")
  if not ok then return end
  -- The user may have moved on while we were waiting for the diff.
  if vim.api.nvim_get_current_buf() ~= buf then return end

  local data_ok, data = pcall(MiniDiff.get_buf_data, buf)
  local hunks = data_ok and data and data.hunks
  if not hunks or #hunks == 0 then
    if attempt >= 20 then return end
    vim.defer_fn(function() land_on_edge_hunk_inline(buf, forward, attempt + 1) end, 10)
    return
  end

  pcall(MiniDiff.goto_hunk, forward and "first" or "last", { wrap = false })
  vim.cmd("normal! zz")
end

--- Land the cursor on the first (forward) or last (backward) hunk of the diff
--- split window `win`, using vim's own diff highlighting as the source of truth.
---@param win number
---@param forward boolean
local function land_on_edge_hunk_split(win, forward)
  vim.api.nvim_win_call(win, function()
    if forward then
      vim.cmd("normal! gg")
      -- `]c` from a line that is already part of a change would skip past
      -- that first hunk, so only step when line 1 is unchanged.
      if vim.fn.diff_hlID(1, 1) == 0 then
        pcall(vim.cmd, "normal! ]c")
      end
    else
      vim.cmd("normal! G")
      local last = vim.fn.line("$")
      if vim.fn.diff_hlID(last, 1) ~= 0 then
        -- The final line is itself changed: walk up to the start of its
        -- block. `[c` can't do this — it stays put on a one-line block and
        -- skips to the preceding block otherwise.
        local line = last
        while line > 1 and vim.fn.diff_hlID(line - 1, 1) ~= 0 do
          line = line - 1
        end
        vim.api.nvim_win_set_cursor(0, { line, 0 })
      else
        pcall(vim.cmd, "normal! [c")
      end
    end
    vim.cmd("normal! zz")
  end)
end

--- Put the cursor on the first line of `win` (the current window when nil).
---@param win number?
local function goto_top(win)
  local function top() pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 }) end
  if win then
    vim.api.nvim_win_call(win, top)
  else
    top()
  end
end

--- Land the cursor on the edge hunk of the file cross-file motion just opened,
--- whichever view it ended up in. `_open_file` falls back to the split view for
--- deleted files, so what's in front of the user decides — not the configured
--- view mode.
---@param buf number Buffer that was opened
---@param forward boolean
---@param file table? The PR file entry that was opened
local function land_on_edge_hunk(buf, forward, file)
  local diff_review = require("gh-review.ui.diff_review")
  -- An added file is one big change with no base content to diff against, so
  -- there is no hunk to look for — show it from the top in either direction.
  local top_only = file ~= nil and file.status == "added"

  if diff_review.is_diff_active() then
    vim.schedule(function()
      local win = diff_review.get_work_win()
      if not win then return end
      if top_only then
        goto_top(win)
      else
        land_on_edge_hunk_split(win, forward)
      end
    end)
  elseif top_only then
    -- Guard like the polling path does: the user may have moved on already.
    if vim.api.nvim_get_current_buf() == buf then goto_top() end
  else
    land_on_edge_hunk_inline(buf, forward)
  end
end

--- Navigate to next or previous diff hunk, crossing file boundaries
---@param forward boolean true for next, false for previous
local function navigate_diff(forward)
  local diff_review = require("gh-review.ui.diff_review")
  local motion = forward and "]c" or "[c"
  local boundary_dir = forward and "next" or "prev"

  if not state.is_active() then
    pcall(vim.cmd, "normal! " .. motion)
    return
  end

  -- Inline view: delegate hunk motion to mini.diff and cross files when the
  -- cursor doesn't move (i.e. we're at the first/last hunk of the buffer).
  if state.get_view_mode() == "inline" then
    local ok, MiniDiff = pcall(require, "mini.diff")
    if not ok then return end

    local before = vim.api.nvim_win_get_cursor(0)
    -- Force wrap=false so the before/after check is meaningful even if the
    -- user has mini.diff's wrap_goto enabled globally. Mute notifications
    -- while probing: mini.diff's "No hunk ranges in direction ..." is our
    -- cue to cross into the next file, not something to show the user.
    local orig_notify = vim.notify
    vim.notify = function() end
    pcall(MiniDiff.goto_hunk, forward and "next" or "prev", { wrap = false })
    vim.notify = orig_notify
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] ~= after[1] or before[2] ~= after[2] then
      return -- moved within the file
    end

    local adj = adjacent_pr_file(M._current_rel_path(), forward)
    if not adj then
      vim.notify("GHReview: " .. (forward and "last" or "first") .. " file in PR", vim.log.levels.INFO)
      return
    end

    M._open_file(adj.path)
    -- Jump to the file's first (or last) hunk directly — the top of the file
    -- is not necessarily where its first change is.
    land_on_edge_hunk(vim.api.nvim_get_current_buf(), forward, adj)
    return
  end

  if not diff_review.is_diff_active() then
    pcall(vim.cmd, "normal! " .. motion)
    return
  end

  if not M._at_boundary_hunk(boundary_dir) then
    -- Still have hunks in this file — just do the motion
    local work_win = diff_review.get_work_win()
    if work_win then
      vim.api.nvim_win_call(work_win, function()
        vim.cmd("normal! " .. motion .. "zz")
      end)
    end
    return
  end

  -- At boundary — find adjacent non-deleted file
  local idx, files = M._get_current_file_index()
  if not idx or not files then return end

  local adj = adjacent_pr_file(files[idx].path, forward)
  if not adj then
    vim.notify("GHReview: " .. (forward and "last" or "first") .. " file in PR", vim.log.levels.INFO)
    return
  end

  M._open_file(adj.path)
  land_on_edge_hunk(vim.api.nvim_get_current_buf(), forward, adj)
end

--- Jump to next diff hunk, crossing file boundaries
function M.next_diff()
  navigate_diff(true)
end

--- Jump to previous diff hunk, crossing file boundaries
function M.prev_diff()
  navigate_diff(false)
end

--- Navigate to next or previous PR file in the effective files list.
--- Silent no-op when no review is active (keybind matches ]c / ]d behavior
--- of doing nothing useful outside PR mode rather than notifying).
---@param forward boolean true for next, false for previous
local function navigate_file(forward)
  if not state.is_active() then return end

  local files = ordered_pr_files()
  if #files == 0 then return end

  -- Work from the current buffer's relative path so navigation works in
  -- inline view, the native split, ghreview:// scratch buffers, and any
  -- other context where the user is sitting on a PR file.
  local current_rel = M._current_rel_path()
  local idx
  if current_rel then
    for i, f in ipairs(files) do
      if f.path == current_rel then
        idx = i
        break
      end
    end
  end
  if not idx then
    -- Not on a recognised PR file — jump to first (going forward) or last (back).
    idx = forward and 0 or (#files + 1)
  end

  local next_idx = forward and (idx + 1) or (idx - 1)
  if next_idx < 1 or next_idx > #files then
    vim.notify("GHReview: " .. (forward and "last" or "first") .. " file in PR", vim.log.levels.INFO)
    return
  end

  M._open_file(files[next_idx].path)
end

--- Jump to next file in the PR
function M.next_file()
  navigate_file(true)
end

--- Jump to previous file in the PR
function M.prev_file()
  navigate_file(false)
end

--- Reply to the thread at cursor position
function M.reply()
  if not require_active() then return end

  local rel_path = M._current_rel_path()
  local thread = state.get_nearest_thread(rel_path, vim.api.nvim_win_get_cursor(0)[1], math.huge)

  if not thread then
    vim.notify("GHReview: no comment thread at cursor", vim.log.levels.WARN)
    return
  end

  M._reply_to_thread(thread)
end

--- Start a new inline comment thread at cursor, or across a visual range.
--- When `start_line` and `end_line` are both given, creates a multi-line
--- thread spanning those lines. With no args, falls back to the cursor line.
---@param start_line? number
---@param end_line? number
function M.new_thread(start_line, end_line)
  if not require_active() then return end

  local pr = state.get_pr()
  if not pr or not pr.node_id then
    vim.notify("GHReview: PR node ID not available, try refreshing", vim.log.levels.ERROR)
    return
  end

  local rel_path = M._current_rel_path()
  if not rel_path then
    vim.notify("GHReview: cannot determine file path", vim.log.levels.ERROR)
    return
  end

  if not start_line then
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  elseif not end_line then
    end_line = start_line
  end

  local range_label = start_line == end_line
    and tostring(start_line)
    or (start_line .. "-" .. end_line)

  require("gh-review.ui.comment_input").open({
    title = "New Thread: " .. rel_path .. ":" .. range_label,
    on_submit = function(body)
      vim.notify("GHReview: creating thread...", vim.log.levels.INFO)
      graphql.create_thread(pr.node_id, rel_path, end_line, "RIGHT", body, function(err)
        if err then
          vim.notify("GHReview: failed to create thread: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("GHReview: thread created", vim.log.levels.INFO)
          M.refresh()
        end
      end, start_line)
    end,
  })
end

--- Start an inline comment that is published immediately, instead of being
--- held back in a pending review the way `M.new_thread` is. Same cursor /
--- visual-range semantics as `M.new_thread`.
---@param start_line? number
---@param end_line? number
function M.new_thread_direct(start_line, end_line)
  if not require_active() then return end

  local pr = state.get_pr()
  if not pr then return end
  if not pr.head_sha then
    vim.notify("GHReview: PR head commit not available, try refreshing", vim.log.levels.ERROR)
    return
  end

  local rel_path = M._current_rel_path()
  if not rel_path then
    vim.notify("GHReview: cannot determine file path", vim.log.levels.ERROR)
    return
  end

  if not start_line then
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  elseif not end_line then
    end_line = start_line
  end

  local range_label = start_line == end_line
    and tostring(start_line)
    or (start_line .. "-" .. end_line)

  require("gh-review.ui.comment_input").open({
    title = "Direct Comment: " .. rel_path .. ":" .. range_label,
    on_submit = function(body)
      vim.notify("GHReview: posting comment...", vim.log.levels.INFO)
      gh.pr_add_review_comment(pr.number, {
        repo = pr.repository,
        body = body,
        commit_id = pr.head_sha,
        path = rel_path,
        line = end_line,
        start_line = start_line,
        side = "RIGHT",
      }, function(err)
        if err then
          vim.notify("GHReview: failed to post comment: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("GHReview: comment posted", vim.log.levels.INFO)
          M.refresh()
        end
      end)
    end,
  })
end

--- Resolve the owner/repo pair for the active PR.
---@return string? owner, string? repo
local function pr_owner_repo()
  local pr = state.get_pr()
  local owner, repo = (pr and pr.repository or ""):match("^(.+)/(.+)$")
  if not owner then
    vim.notify("GHReview: repository not available, try refreshing", vim.log.levels.ERROR)
    return nil, nil
  end
  return owner, repo
end

--- Review events, keyed by the spellings accepted on the command line.
local REVIEW_EVENTS = {
  comment = "COMMENT",
  approve = "APPROVE",
  ["request-changes"] = "REQUEST_CHANGES",
  request_changes = "REQUEST_CHANGES",
}

---@type table<string, string>
local REVIEW_EVENT_LABELS = {
  COMMENT = "Comment",
  APPROVE = "Approve",
  REQUEST_CHANGES = "Request changes",
}

--- Fetch the viewer's pending (unsubmitted) review. Errors are reported here
--- and stop the chain; `review` is nil when nothing is pending.
---@param callback fun(review: table?)
local function fetch_pending_review(callback)
  local pr = state.get_pr()
  local owner, repo = pr_owner_repo()
  if not owner or not pr then return end

  graphql.fetch_pending_review(owner, repo, pr.number, function(err, review)
    if err then
      vim.notify("GHReview: failed to fetch pending review: " .. err, vim.log.levels.ERROR)
      return
    end
    callback(review)
  end)
end

--- As `fetch_pending_review`, but for the flows that exist to publish those
--- comments: reports when there is nothing to submit rather than calling back.
---@param callback fun(review: table)
local function with_pending_review(callback)
  vim.notify("GHReview: checking for unsubmitted comments...", vim.log.levels.INFO)
  fetch_pending_review(function(review)
    if not review or #review.comments == 0 then
      vim.notify("GHReview: no unsubmitted comments", vim.log.levels.INFO)
      return
    end
    callback(review)
  end)
end

--- Review the comments waiting in the pending review and submit them all.
function M.pending_review()
  if not require_active() then return end

  with_pending_review(function(review)
    require("gh-review.ui.review_submit").show(review, {
      on_jump = function(comment)
        if comment.path then
          M._open_file(comment.path, comment.line)
        end
      end,
      on_submit = function(event)
        M._submit_review(review, event)
      end,
    })
  end)
end

--- Submit the pending review without opening the panel first.
---@param event? string "comment" (default), "approve" or "request-changes"
function M.submit_review(event)
  if not require_active() then return end

  local resolved = REVIEW_EVENTS[(event or "comment"):lower()]
  if not resolved then
    vim.notify("GHReview: unknown review event '" .. tostring(event) .. "'", vim.log.levels.ERROR)
    return
  end

  with_pending_review(function(review)
    M._submit_review(review, resolved)
  end)
end

--- Review the PR as a whole: approve it, leave a review comment, or request
--- changes. Unlike `M.submit_review` this does not need anything pending —
--- without an `event` it asks which verdict to give.
---@param event? string "comment", "approve" or "request-changes"
function M.review_pr(event)
  if not require_active() then return end

  if event and event ~= "" then
    local resolved = REVIEW_EVENTS[event:lower()]
    if not resolved then
      vim.notify("GHReview: unknown review event '" .. tostring(event) .. "'", vim.log.levels.ERROR)
      return
    end
    M._review_pr(resolved)
    return
  end

  vim.ui.select({ "APPROVE", "COMMENT", "REQUEST_CHANGES" }, {
    prompt = "Review PR:",
    format_item = function(item)
      return REVIEW_EVENT_LABELS[item] or item
    end,
  }, function(choice)
    if choice then M._review_pr(choice) end
  end)
end

--- Internal: prompt for the review body, then publish a PR-level review.
---
--- A pending review is submitted along with it instead of being left behind:
--- GitHub allows the viewer only one review at a time, so creating a second one
--- would just fail while the pending comments sat there unpublished.
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
function M._review_pr(event)
  local pr = state.get_pr()
  if not pr or not pr.node_id then
    vim.notify("GHReview: PR node ID not available, try refreshing", vim.log.levels.ERROR)
    return
  end

  fetch_pending_review(function(pending)
    local count = pending and #pending.comments or 0
    local title = ("Review PR #%d [%s]"):format(pr.number, REVIEW_EVENT_LABELS[event] or event)
    if count > 0 then
      title = title .. (" — also publishes %d pending comment%s"):format(count, count == 1 and "" or "s")
    end

    require("gh-review.ui.comment_input").open({
      title = title,
      -- GitHub rejects a COMMENT or REQUEST_CHANGES review with no body, but is
      -- happy with a bare approval.
      allow_empty = event == "APPROVE",
      on_submit = function(body)
        vim.notify("GHReview: submitting review...", vim.log.levels.INFO)
        local function done(err)
          if err then
            vim.notify("GHReview: submit failed: " .. err, vim.log.levels.ERROR)
            return
          end
          local suffix = count > 0
            and (", %d comment%s published"):format(count, count == 1 and "" or "s")
            or ""
          vim.notify(
            ("GHReview: review submitted (%s%s)"):format(REVIEW_EVENT_LABELS[event] or event, suffix),
            vim.log.levels.INFO
          )
          M.refresh()
        end

        if pending then
          graphql.submit_review(pending.id, event, body, done)
        else
          graphql.create_review(pr.node_id, event, body, done)
        end
      end,
    })
  end)
end

--- Internal: prompt for an optional summary, then publish a pending review.
---@param review table from graphql.fetch_pending_review
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
function M._submit_review(review, event)
  local count = #review.comments

  require("gh-review.ui.comment_input").open({
    title = ("Submit review [%s] — publishes %d comment%s"):format(
      REVIEW_EVENT_LABELS[event] or event, count, count == 1 and "" or "s"
    ),
    -- Approving without a summary is common; the other events read badly
    -- without one, but GitHub is the authority on what it rejects.
    allow_empty = event == "APPROVE",
    on_submit = function(body)
      vim.notify("GHReview: submitting review...", vim.log.levels.INFO)
      graphql.submit_review(review.id, event, body, function(err)
        if err then
          vim.notify("GHReview: submit failed: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.notify(
          ("GHReview: review submitted (%d comment%s published)"):format(count, count == 1 and "" or "s"),
          vim.log.levels.INFO
        )
        M.refresh()
      end)
    end,
  })
end

--- Toggle resolve/unresolve on the nearest thread
function M.resolve()
  if not require_active() then return end

  local rel_path = M._current_rel_path()
  local thread = state.get_nearest_thread(rel_path, vim.api.nvim_win_get_cursor(0)[1], math.huge)

  if not thread then
    vim.notify("GHReview: no thread to resolve", vim.log.levels.WARN)
    return
  end

  M._toggle_resolve(thread)
end

--- Internal: reply to a specific thread
---@param thread table
function M._reply_to_thread(thread)
  local pr = state.get_pr()
  if not pr or not pr.node_id then
    vim.notify("GHReview: PR node ID not available", vim.log.levels.ERROR)
    return
  end

  local first = thread.comments[1]
  local preview = first and first.body:match("^([^\n]+)") or ""
  if #preview > 50 then preview = preview:sub(1, 47) .. "..." end

  local context_lines = util.build_thread_context(thread.comments)

  require("gh-review.ui.comment_input").open({
    title = "Reply: " .. preview,
    context_lines = context_lines,
    on_submit = function(body)
      vim.notify("GHReview: posting reply...", vim.log.levels.INFO)
      graphql.reply_to_thread(thread.id, body, function(err)
        if err then
          vim.notify("GHReview: reply failed: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("GHReview: reply posted", vim.log.levels.INFO)
          M.refresh()
        end
      end)
    end,
  })
end

--- Internal: toggle resolve/unresolve
---@param thread table
function M._toggle_resolve(thread)
  local action = thread.is_resolved and "unresolving" or "resolving"
  vim.notify("GHReview: " .. action .. " thread...", vim.log.levels.INFO)

  local fn = thread.is_resolved and graphql.unresolve_thread or graphql.resolve_thread
  fn(thread.id, function(err)
    if err then
      vim.notify("GHReview: " .. action .. " failed: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("GHReview: thread " .. (thread.is_resolved and "unresolved" or "resolved"), vim.log.levels.INFO)
      M.refresh()
    end
  end)
end

--- Review the PR associated with the current branch
function M.review_current()
  if state.is_active() then
    vim.notify("GHReview: review already active, close first", vim.log.levels.WARN)
    return
  end
  vim.notify("GHReview: detecting PR for current branch...", vim.log.levels.INFO)
  gh.pr_view_current(function(err, data)
    if err then
      vim.notify("GHReview: no PR for current branch: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.schedule(function()
      vim.notify("GHReview: loading PR #" .. data.number .. " — " .. data.title, vim.log.levels.INFO)
      M._load_pr_data(data.number)
    end)
  end)
end

--- Checkout a PR by number, or open the PR picker if no number given
---@param pr_number? number
function M.checkout_or_pick(pr_number)
  if pr_number then
    M.checkout(pr_number)
    return
  end
  require("gh-review.ui.pr_picker").show({
    on_select = function(n)
      M.checkout(n)
    end,
  })
end

--- Select a specific commit for filtered review
---@param commit GHReviewCommit
function M.select_commit(commit)
  if not commit or not commit.oid or commit.oid == "" then
    vim.notify("GHReview: invalid commit", vim.log.levels.ERROR)
    return
  end

  local cwd = vim.fn.getcwd()
  local status_result = vim.system(
    vcs.git_cmd(util.commit_diff_args({ "--name-status" }, commit.oid), cwd),
    { text = true, cwd = cwd }
  ):wait()

  if status_result.code ~= 0 then
    vim.notify("GHReview: git diff-tree failed: " .. (status_result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  -- Get line counts via numstat
  local numstat_result = vim.system(
    vcs.git_cmd(util.commit_diff_args({ "--numstat" }, commit.oid), cwd),
    { text = true, cwd = cwd }
  ):wait()
  local stats = {}
  if numstat_result.code == 0 and numstat_result.stdout then
    for nline in numstat_result.stdout:gmatch("[^\n]+") do
      local adds, dels, npath = nline:match("^(%d+)\t(%d+)\t(.+)$")
      if adds and npath then
        -- Renames show as "old => new"
        local new_path = npath:match("=>%s*(.+)$")
        local key = new_path and vim.trim(new_path) or npath
        stats[key] = { additions = tonumber(adds), deletions = tonumber(dels) }
      end
    end
  end

  local files = {}
  for line in (status_result.stdout or ""):gmatch("[^\n]+") do
    local status_char, path = line:match("^(%S+)\t(.+)$")
    if status_char and path then
      local file_status = "modified"
      local old_path = nil
      if status_char == "A" then
        file_status = "added"
      elseif status_char == "D" then
        file_status = "deleted"
      elseif status_char:sub(1, 1) == "R" then
        file_status = "renamed"
        local old, new = path:match("^(.+)\t(.+)$")
        if old and new then
          old_path = old
          path = new
        end
      end
      local s = stats[path] or {}
      table.insert(files, {
        path = path,
        status = file_status,
        additions = s.additions or 0,
        deletions = s.deletions or 0,
        old_path = old_path,
      })
    end
  end

  state.set_active_commit(commit)
  state.set_commit_files(files)
  M._refresh_views()
  vim.notify("GHReview: filtering to commit " .. commit.sha, vim.log.levels.INFO)
end

--- Clear commit filter and restore full PR view
function M.clear_commit()
  if not state.get_active_commit() then return end
  state.clear_active_commit()
  M._refresh_views()
  vim.notify("GHReview: showing full PR", vim.log.levels.INFO)
end

--- Directions the jj commit stack can be walked in.
local STACK_DIRECTIONS = {
  next = { revset = "children", noun = "descendant" },
  prev = { revset = "parents", noun = "ancestor" },
}

--- Revision a stack walk starts from: the commit under review when the view is
--- commit-scoped, otherwise the PR head (its child is the next PR of the stack),
--- falling back to the jj working copy.
---@return string?
local function stack_anchor()
  local active = state.get_active_commit()
  if active and active.oid and active.oid ~= "" then return active.oid end
  local pr = state.get_pr()
  if pr and pr.head_sha and pr.head_sha ~= "" then return pr.head_sha end
  return vcs.head_rev()
end

--- Everything that locates the stack the review sits on: the commit under
--- review, the PR head commit, and the PR head branch. The branch matters
--- because the oid GitHub reports is the commit as pushed — once it has been
--- rewritten locally the pushed commit has no descendants, and anchoring on it
--- alone would list the PRs below the review but none above it.
---@return GHReviewJJAnchor
local function stack_anchors()
  local anchor = { revs = {}, bookmarks = {} }
  local active = state.get_active_commit()
  if active and active.oid and active.oid ~= "" then
    table.insert(anchor.revs, active.oid)
  end
  local pr = state.get_pr()
  if pr then
    if pr.head_sha and pr.head_sha ~= "" then table.insert(anchor.revs, pr.head_sha) end
    if pr.head_ref and pr.head_ref ~= "" then table.insert(anchor.bookmarks, pr.head_ref) end
  end
  if #anchor.revs == 0 and #anchor.bookmarks == 0 then
    local head = vcs.head_rev()
    if head then table.insert(anchor.revs, head) end
  end
  return anchor
end

--- Find one of the loaded PR's commits by full oid.
---@param oid string
---@return GHReviewCommit?
local function pr_commit_by_oid(oid)
  for _, commit in ipairs(state.get_commits()) do
    if commit.oid == oid then return commit end
  end
  return nil
end

--- Short label for a jj commit in notifications.
---@param commit GHReviewJJCommit
---@return string
local function jj_commit_label(commit)
  local short = commit.commit_id:sub(1, 8)
  if commit.description ~= "" then return short .. " " .. commit.description end
  return short
end

--- Take the only adjacent commit, or let the user pick when the stack forks.
---@param commits GHReviewJJCommit[]
---@param noun string
---@param callback fun(commit: GHReviewJJCommit)
local function pick_stack_commit(commits, noun, callback)
  if #commits == 1 then
    callback(commits[1])
    return
  end
  vim.ui.select(commits, {
    prompt = "GHReview: which " .. noun .. "?",
    format_item = function(commit)
      local names = table.concat(commit.bookmarks, ", ")
      return jj_commit_label(commit) .. (names ~= "" and ("  [" .. names .. "]") or "")
    end,
  }, function(choice)
    if choice then callback(choice) end
  end)
end

--- Load another PR of the stack and scope the review to `oid` once its data is in.
---@param pr_number number
---@param title string?
---@param oid string
local function load_pr_at_commit(pr_number, title, oid)
  vim.notify(
    "GHReview: loading PR #" .. pr_number .. (title and title ~= "" and (" — " .. title) or "") .. "...",
    vim.log.levels.INFO
  )
  -- The old PR's commit filter must not survive into the new one.
  state.clear_active_commit()
  M._load_pr_data(pr_number, function()
    local commit = pr_commit_by_oid(oid)
    if commit then
      M.select_commit(commit)
      return
    end
    -- The commit sits in this PR's stack range but is not one of its commits,
    -- which normally means it has not been pushed yet. Show the whole PR.
    M._refresh_views()
    vim.notify(
      "GHReview: PR #" .. pr_number .. " loaded; commit " .. oid:sub(1, 8) .. " is not part of it",
      vim.log.levels.WARN
    )
  end)
end

--- Move the review onto an adjacent jj commit: re-scope when it belongs to the
--- PR already loaded, otherwise load the PR of the stack that owns it.
---@param jj_commit GHReviewJJCommit
function M._goto_stack_commit(jj_commit)
  local commit = pr_commit_by_oid(jj_commit.commit_id)
  if commit then
    M.select_commit(commit)
    return
  end

  local pr = state.get_pr()
  vcs.jj_downstream_bookmarks(jj_commit.commit_id, function(err, bookmarks)
    if err then
      vim.notify("GHReview: jj bookmark lookup failed: " .. err, vim.log.levels.ERROR)
      return
    end
    bookmarks = bookmarks or {}
    if #bookmarks == 0 then
      vim.notify(
        "GHReview: commit " .. jj_commit_label(jj_commit) .. " has no bookmark to identify a PR by",
        vim.log.levels.WARN
      )
      return
    end

    gh.pr_view_branch(bookmarks, function(pr_err, data)
      if pr_err or not data then
        vim.notify("GHReview: " .. (pr_err or "no PR found for " .. table.concat(bookmarks, ", ")), vim.log.levels.WARN)
        return
      end
      if pr and data.number == pr.number then
        vim.notify(
          "GHReview: commit " .. jj_commit_label(jj_commit) .. " belongs to PR #" .. data.number
            .. " but is not one of its commits (unpushed?)",
          vim.log.levels.WARN
        )
        return
      end
      load_pr_at_commit(data.number, data.title, jj_commit.commit_id)
    end)
  end)
end

--- Walk the jj commit stack by one step in `direction`.
---@param direction "next"|"prev"
local function navigate_stack(direction)
  if not require_active() then return end
  local dir = STACK_DIRECTIONS[direction]

  if not vcs.jj_root() then
    vim.notify("GHReview: stack navigation requires a jj workspace", vim.log.levels.WARN)
    return
  end

  local anchor = stack_anchor()
  if not anchor then
    vim.notify("GHReview: could not resolve the current jj revision", vim.log.levels.ERROR)
    return
  end

  -- Walk from the change rather than the commit: the oid GitHub reports is the
  -- commit as pushed, and once it has been rewritten locally nothing descends
  -- from it any more, so children() of it would come up empty mid-stack.
  vcs.jj_change_id(anchor, function(id_err, change_id)
    if id_err then
      vim.notify("GHReview: jj log failed: " .. id_err, vim.log.levels.ERROR)
      return
    end
    if not change_id then
      vim.notify(
        "GHReview: commit " .. anchor:sub(1, 8) .. " is not in this jj workspace (fetch it first?)",
        vim.log.levels.WARN
      )
      return
    end

    vcs.jj_adjacent(change_id, dir.revset, function(err, commits)
      if err then
        vim.notify("GHReview: jj log failed: " .. err, vim.log.levels.ERROR)
        return
      end
      commits = commits or {}
      if #commits == 0 then
        vim.notify(
          "GHReview: no " .. dir.noun .. " of " .. anchor:sub(1, 8) .. " in this stack",
          vim.log.levels.INFO
        )
        return
      end
      pick_stack_commit(commits, dir.noun, function(commit)
        M._goto_stack_commit(commit)
      end)
    end)
  end)
end

--- Move the review to the direct descendant of the current commit in the jj
--- stack, loading the PR that owns it when it belongs to another one.
function M.next_stack_commit()
  navigate_stack("next")
end

--- Move the review to the direct ancestor of the current commit in the jj stack.
function M.prev_stack_commit()
  navigate_stack("prev")
end

--- Resolve what the stack picker needs to recognise commits across a local
--- rewrite: the change of the commit the review sits on, and the changes of the
--- loaded PR's commits. Both are best effort — a workspace that has never seen a
--- commit yields nothing for it, and the picker then falls back to commit ids.
---@param anchor string? Revision the review sits on
---@param callback fun(current_change_id: string?, pr_change_ids: table<string, true>)
local function resolve_stack_changes(anchor, callback)
  local oids = {}
  for _, commit in ipairs(state.get_commits()) do
    if commit.oid and commit.oid ~= "" then
      table.insert(oids, commit.oid)
    end
  end

  local function with_pr_changes(current_change_id)
    vcs.jj_change_ids(oids, function(_, change_ids)
      local set = {}
      for _, id in ipairs(change_ids or {}) do
        set[id] = true
      end
      callback(current_change_id, set)
    end)
  end

  if not anchor then
    with_pr_changes(nil)
    return
  end
  vcs.jj_change_id(anchor, function(_, change_id)
    with_pr_changes(change_id)
  end)
end

--- Toggle a floating picker over the whole jj stack: every commit between trunk
--- and the tip of the branch the review sits on, tip first — the PRs below the
--- one under review and the ones stacked above it alike. Selecting an entry moves
--- the review onto that commit, loading another PR of the stack when the commit
--- belongs to one. Works without an active review, so it can be used to pick
--- which PR of the stack to start on.
function M.stack_panel()
  local stack = require("gh-review.ui.stack")
  if stack.close() then return end

  if not vcs.jj_root() then
    vim.notify("GHReview: the stack picker requires a jj workspace", vim.log.levels.WARN)
    return
  end

  local anchors = stack_anchors()
  if #anchors.revs == 0 and #anchors.bookmarks == 0 then
    vim.notify("GHReview: could not resolve the current jj revision", vim.log.levels.ERROR)
    return
  end
  -- Only for the "you are here" marker; the query spans the whole stack.
  local anchor = stack_anchor()

  -- The marker and the `#<pr>` badges match on changes as well as commit ids:
  -- the oids GitHub reports are the commits as pushed, so a single local amend or
  -- rebase leaves none of them in the stack, and matching on them alone would
  -- mark nothing at all. Resolution is best effort — without it the picker just
  -- falls back to commit ids.
  resolve_stack_changes(anchor, function(current_change_id, pr_change_ids)
    vcs.jj_stack(anchors, function(err, commits, truncated)
      if err then
        vim.notify("GHReview: jj log failed: " .. err, vim.log.levels.ERROR)
        return
      end
      commits = commits or {}
      if #commits == 0 then
        local label = anchors.bookmarks[1] or (anchor and anchor:sub(1, 8)) or "the current revision"
        vim.notify("GHReview: no commits between trunk and " .. label, vim.log.levels.INFO)
        return
      end
      stack.show(commits, {
        current_oid = anchor,
        current_change_id = current_change_id,
        pr_change_ids = pr_change_ids,
        truncated = truncated,
        on_select = function(commit)
          M._goto_stack_commit(commit)
        end,
      })
    end)
  end)
end

--- Refresh all views after commit selection change
function M._refresh_views()
  -- Close diff split
  require("gh-review.ui.diff_review").close()
  -- And the unified buffer, which renders a fixed snapshot of the diff: after a
  -- change of commit filter its contents describe the previous scope.
  require("gh-review.ui.unified").close()

  -- Refresh diagnostics
  diagnostics.refresh_all()

  -- Close and reopen trouble if open
  local trouble_was_open = false
  pcall(function()
    local trouble = require("trouble")
    if trouble.is_open("gh_review") then
      trouble_was_open = true
      trouble.close("gh_review")
    end
  end)

  -- Close file sidebar (will reopen below)
  close_snacks_picker("gh_review_files")

  -- Reopen views with updated data after a short delay
  vim.defer_fn(function()
    require("gh-review.ui.files").show()
    if trouble_was_open then
      pcall(function()
        require("trouble").open("gh_review")
      end)
    end
  end, 50)

  -- Refresh description buffer if it exists
  pcall(function()
    local buf = vim.fn.bufnr("gh-review://description")
    if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
      require("gh-review.ui.description").refresh_buf(buf)
    end
  end)
end

--- Get current buffer's path relative to cwd
---@return string?
function M._current_rel_path()
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    -- May be in diff review base window
    return require("gh-review.ui.diff_review").get_file_path()
  end
  local cwd = vim.fn.getcwd()
  if filepath:sub(1, #cwd) == cwd then
    return filepath:sub(#cwd + 2)
  end
  -- Check if we're in a ghreview:// buffer
  local review_path = filepath:match("^ghreview://base/(.+)$")
    or filepath:match("^ghreview://commit/[^/]+/(.+)$")
    or filepath:match("^ghreview://unified/(.+)$")
  if review_path then return review_path end
  return filepath
end

--- Set up all keymaps
function M._setup_keymaps()
  local km = config.get().keymaps
  local prefix = km.prefix
  local opts = { silent = true }

  local function map(suffix, fn, desc)
    vim.keymap.set("n", prefix .. suffix, fn, vim.tbl_extend("force", opts, { desc = desc }))
  end

  map(km.checkout, M.checkout_or_pick, "Checkout PR")
  map(km.review_current, M.review_current, "Review PR for current branch")

  map(km.files, M.files, "Open/close file tree")
  map(km.files_focus, M.files_focus, "Focus file tree")
  map(km.commits, M.commits_panel, "Toggle commits panel")
  map(km.comments, M.comments, "Open/close comments panel")
  map(km.comments_focus, M.comments_focus, "Focus comments panel")
  map(km.reply, M.reply, "Reply to thread")
  map(km.new_thread, M.new_thread, "New comment thread")
  -- Visual-mode variant: spans the selection as a multi-line thread.
  vim.keymap.set("x", prefix .. km.new_thread, function()
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    local start_line = math.min(a, b)
    local end_line = math.max(a, b)
    -- Leave visual mode before we open the input window.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    M.new_thread(start_line, end_line)
  end, vim.tbl_extend("force", opts, { desc = "New multi-line comment thread" }))
  map(km.new_thread_direct, M.new_thread_direct, "New comment (posted immediately)")
  vim.keymap.set("x", prefix .. km.new_thread_direct, function()
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    local start_line = math.min(a, b)
    local end_line = math.max(a, b)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    M.new_thread_direct(start_line, end_line)
  end, vim.tbl_extend("force", opts, { desc = "New multi-line comment (posted immediately)" }))
  map(km.pending_review, M.pending_review, "Review/submit unsubmitted comments")
  map(km.review_pr, M.review_pr, "Approve / comment / request changes on the PR")
  map(km.next_stack, M.next_stack_commit, "Next commit in the jj stack")
  map(km.prev_stack, M.prev_stack_commit, "Previous commit in the jj stack")
  map(km.stack, M.stack_panel, "Toggle the jj stack picker")
  map(km.toggle_resolve, M.resolve, "Toggle resolve")
  map(km.hover, M.show_hover, "View comment at cursor")
  map(km.description, M.description, "PR description")
  map(km.toggle_overlay, M.toggle_overlay, "Toggle diff overlay")
  map(km.open_minidiff, M.open_minidiff, "Open file with diff overlay")
  map(km.diffview, M.diffview, "Open diffview.nvim")
  map(km.unified, M.open_unified, "Open unified single-buffer diff view")
  map(km.toggle_reviewed, M.toggle_reviewed, "Toggle reviewed mark on current file")
  map(km.ignore_whitespace, M.toggle_ignore_whitespace, "Toggle ignore whitespace-only changes")
  map(km.toggle_linematch, M.toggle_linematch, "Toggle linematch (char highlights vs grouped blocks)")
  map(km.toggle_view, M.toggle_view, "Toggle split / inline view")
  map(km.refresh, M.refresh, "Refresh PR data")
  map(km.close, M.close, "Close review")

  -- ]c / [c with fallthrough
  vim.keymap.set("n", km.next_comment, M.next_comment, { desc = "Next comment", silent = true })
  vim.keymap.set("n", km.prev_comment, M.prev_comment, { desc = "Prev comment", silent = true })

  -- ]d / [d cross-file diff hunk navigation
  vim.keymap.set("n", km.next_diff, M.next_diff, { desc = "Next diff hunk", silent = true })
  vim.keymap.set("n", km.prev_diff, M.prev_diff, { desc = "Prev diff hunk", silent = true })

  -- Whole-file jumps across the PR (no-op when no PR review is active).
  vim.keymap.set("n", km.next_file, M.next_file, { desc = "Next PR file", silent = true })
  vim.keymap.set("n", km.prev_file, M.prev_file, { desc = "Prev PR file", silent = true })
end

return M
