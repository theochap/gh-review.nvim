--- gh-review.nvim — Public API
local M = {}

local config = require("gh-review.config")
local state = require("gh-review.state")
local gh = require("gh-review.gh")
local graphql = require("gh-review.graphql")
local diff = require("gh-review.diff")
local diagnostics = require("gh-review.ui.diagnostics")
local util = require("gh-review.util")

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
        head_ref = data.headRefName,
        url = data.url,
        body = data.body or "",
        review_decision = data.reviewDecision or "",
        repository = repo,
      })

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

--- Open current diff file in a normal buffer with mini.diff overlay
function M.open_minidiff()
  if not require_active() then return end

  local diff_review = require("gh-review.ui.diff_review")
  local file_path = diff_review.get_file_path()
  if not file_path then
    file_path = M._current_rel_path()
  end
  if not file_path then
    vim.notify("GHReview: no file to open", vim.log.levels.WARN)
    return
  end

  -- Close diff split if open
  diff_review.close()

  -- Open the file normally
  local cwd = vim.fn.getcwd()
  vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. file_path))

  -- Attach mini.diff and turn on overlay
  local minidiff = require("gh-review.ui.minidiff")
  local buf = vim.api.nvim_get_current_buf()
  minidiff.attach(buf)
  minidiff.toggle_overlay()
end

--- Toggle mini.diff overlay on current buffer
function M.toggle_overlay()
  if not require_active() then return end
  require("gh-review.ui.minidiff").toggle_overlay()
end

--- Close the review session
function M.close()
  require("gh-review.ui.minidiff").detach_all()
  diagnostics.clear_all()
  require("gh-review.ui.diff_review").close()
  close_snacks_picker("gh_review_files")
  close_snacks_picker("gh_review_commits")
  -- Close trouble comments panel if open
  pcall(function() require("trouble").close("gh_review") end)
  require("gh-review.integrations.diffview").close()
  state.clear()
  vim.notify("GHReview: review session closed", vim.log.levels.INFO)
end

--- Toggle commits sidebar
function M.commits_panel()
  if not require_active() then return end
  require("gh-review.ui.commits").toggle()
end

--- Toggle file tree sidebar
function M.files()
  if not require_active() then return end
  require("gh-review.ui.files").toggle()
end

--- Toggle comments panel (open / focus / close cycle)
function M.comments()
  if not require_active() then return end
  local trouble = require("trouble")
  if trouble.is_open("gh_review") then
    if vim.bo.filetype == "trouble" then
      trouble.close("gh_review")
    else
      trouble.focus("gh_review")
    end
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

  require("gh-review.ui.diff_review").open(thread.path, line)

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

--- Navigate to next or previous diff hunk, crossing file boundaries
---@param forward boolean true for next, false for previous
local function navigate_diff(forward)
  local diff_review = require("gh-review.ui.diff_review")
  local motion = forward and "]c" or "[c"
  local boundary_dir = forward and "next" or "prev"

  if not state.is_active() or not diff_review.is_diff_active() then
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

  local adj_idx = nil
  if forward then
    for i = idx + 1, #files do
      if files[i].status ~= "deleted" then
        adj_idx = i
        break
      end
    end
  else
    for i = idx - 1, 1, -1 do
      if files[i].status ~= "deleted" then
        adj_idx = i
        break
      end
    end
  end

  if not adj_idx then
    vim.notify("GHReview: " .. (forward and "last" or "first") .. " file in PR", vim.log.levels.INFO)
    return
  end

  diff_review.open(files[adj_idx].path)
  vim.schedule(function()
    local win = diff_review.get_work_win()
    if win then
      vim.api.nvim_win_call(win, function()
        if forward then
          vim.cmd("normal! gg")
          pcall(vim.cmd, "normal! ]czz")
        else
          vim.cmd("normal! G")
          pcall(vim.cmd, "normal! [czz")
        end
      end)
    end
  end)
end

--- Jump to next diff hunk, crossing file boundaries
function M.next_diff()
  navigate_diff(true)
end

--- Jump to previous diff hunk, crossing file boundaries
function M.prev_diff()
  navigate_diff(false)
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

--- Start a new inline comment thread at cursor
function M.new_thread()
  if not require_active() then return end

  local pr = state.get_pr()
  if not pr or not pr.node_id then
    vim.notify("GHReview: PR node ID not available, try refreshing", vim.log.levels.ERROR)
    return
  end

  local rel_path = M._current_rel_path()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  if not rel_path then
    vim.notify("GHReview: cannot determine file path", vim.log.levels.ERROR)
    return
  end

  require("gh-review.ui.comment_input").open({
    title = "New Thread: " .. rel_path .. ":" .. cursor_line,
    on_submit = function(body)
      vim.notify("GHReview: creating thread...", vim.log.levels.INFO)
      graphql.create_thread(pr.node_id, rel_path, cursor_line, "RIGHT", body, function(err)
        if err then
          vim.notify("GHReview: failed to create thread: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("GHReview: thread created", vim.log.levels.INFO)
          M.refresh()
        end
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
      graphql.reply_to_thread(pr.node_id, thread.id, body, function(err)
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
    { "git", "diff-tree", "--no-commit-id", "--name-status", "-r", "-M", commit.oid },
    { text = true, cwd = cwd }
  ):wait()

  if status_result.code ~= 0 then
    vim.notify("GHReview: git diff-tree failed: " .. (status_result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  -- Get line counts via numstat
  local numstat_result = vim.system(
    { "git", "diff-tree", "--no-commit-id", "--numstat", "-r", "-M", commit.oid },
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

--- Refresh all views after commit selection change
function M._refresh_views()
  -- Close diff split
  require("gh-review.ui.diff_review").close()

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

  map(km.files, M.files, "Toggle file tree")
  map(km.commits, M.commits_panel, "Toggle commits panel")
  map(km.comments, M.comments, "Toggle comments panel")
  map(km.reply, M.reply, "Reply to thread")
  map(km.new_thread, M.new_thread, "New comment thread")
  map(km.toggle_resolve, M.resolve, "Toggle resolve")
  map(km.hover, M.show_hover, "View comment at cursor")
  map(km.description, M.description, "PR description")
  map(km.toggle_overlay, M.toggle_overlay, "Toggle diff overlay")
  map(km.open_minidiff, M.open_minidiff, "Open file with diff overlay")
  map(km.refresh, M.refresh, "Refresh PR data")
  map(km.close, M.close, "Close review")

  -- ]c / [c with fallthrough
  vim.keymap.set("n", km.next_comment, M.next_comment, { desc = "Next comment", silent = true })
  vim.keymap.set("n", km.prev_comment, M.prev_comment, { desc = "Prev comment", silent = true })

  -- ]d / [d cross-file diff hunk navigation
  vim.keymap.set("n", km.next_diff, M.next_diff, { desc = "Next diff hunk", silent = true })
  vim.keymap.set("n", km.prev_diff, M.prev_diff, { desc = "Prev diff hunk", silent = true })
end

return M
