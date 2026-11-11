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
    callback = function()
      vcs.invalidate()
      gh.forget_repo_names()
      M._detected = nil
      M._sync_gh_repo_env()
    end,
  })

  -- Keep the file tree sidebar pointed at the file you are looking at. The
  -- plugin's own navigation syncs it from `_open_file`, but a file can also be
  -- reached by `:e`, `<C-o>`, `:bnext`, another picker or a window jump, and the
  -- sidebar was left behind on the previously opened file in all of those.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("GHReviewFileSync", { clear = true }),
    callback = function(args)
      if not state.is_active() then return end
      require("gh-review.ui.files").sync_current(args.buf)
    end,
  })

  -- Auto-detect PR for current branch after startup
  M._schedule_pr_detection()

  M._sync_gh_repo_env()

  -- Drop cache entries nobody read for a month, off the startup path.
  vim.defer_fn(function() pcall(require("gh-review.cache").prune) end, 5000)
end

--- $GH_REPO value this plugin set, so it can take it back.
---@type string?
M._exported_gh_repo = nil

--- In a jj workspace with no git worktree (a secondary `jj workspace add`,
--- or a non-colocated repo), `gh` cannot tell which repository it is in and
--- fails with "not a git repository". This plugin works around that for its
--- own calls; exporting $GH_REPO extends the fix to every child process —
--- snacks.nvim's `gh` pickers, terminals, other plugins. A $GH_REPO the user
--- set is never touched, and the exported one is removed on leaving.
function M._sync_gh_repo_env()
  if M._exported_gh_repo and vim.env.GH_REPO == M._exported_gh_repo then
    vim.env.GH_REPO = nil
  end
  M._exported_gh_repo = nil
  if not config.get().export_gh_repo then return end
  if vim.env.GH_REPO and vim.env.GH_REPO ~= "" then return end
  local ctx = vcs.context()
  if ctx.kind ~= "jj" then return end -- a git worktree: gh resolves the repo itself

  local cwd = vim.fn.getcwd()
  local function export(name)
    -- Drop a late answer for a directory we already left.
    if not name or name == "" or vim.fn.getcwd() ~= cwd then return end
    if vim.env.GH_REPO and vim.env.GH_REPO ~= "" then return end
    vim.env.GH_REPO = name
    M._exported_gh_repo = name
  end
  if ctx.gh_env and ctx.gh_env.GH_REPO then
    export(ctx.gh_env.GH_REPO)
    return
  end
  -- Colocated main workspace next to this one: ask gh there (it honours
  -- `gh repo set-default` and forks).
  gh.repo_name(function(err, name)
    if not err then export(name) end
  end)
end

--- Delete the commit-keyed cache (PR content, merge statuses, checks).
function M.clear_cache()
  require("gh-review.cache").clear()
  vim.notify("GHReview: cache cleared", vim.log.levels.INFO)
end

--- Check if the current branch has an open PR and notify the user
M._pr_detection_notified = false

--- Metadata of the PR found for the working copy (by startup detection or the
--- last `review_current`), and the commit the working copy was on. It is used
--- right away by the next `review_current` on that commit, and checked
--- against GitHub in the background.
---@type { data: table, head: string? }?
M._detected = nil

---@param data table `gh.pr_view` output
---@return { head_oid?: string, base_oid?: string }
local function hint_of(data)
  return {
    head_oid = type(data.headRefOid) == "string" and data.headRefOid or nil,
    base_oid = type(data.baseRefOid) == "string" and data.baseRefOid or nil,
  }
end

function M._schedule_pr_detection()
  local function check()
    if M._pr_detection_notified or state.is_active() then return end
    gh.pr_view_current(function(err, data)
      if err or not data then return end
      if M._pr_detection_notified or state.is_active() then return end
      M._pr_detection_notified = true
      -- Keep the metadata for review_current, and warm the repo name: the
      -- review this notification suggests needs both first.
      M._detected = { data = data, head = vcs.base_commit() }
      gh.repo_name(function() end)
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
---@param hint? { head_oid?: string, base_oid?: string } Commits of the PR, when known
function M.checkout(pr_number, hint)
  vim.notify("GHReview: checking out PR #" .. pr_number .. "...", vim.log.levels.INFO)

  gh.checkout(pr_number, function(err)
    if err then
      vim.notify("GHReview: checkout failed: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.notify("GHReview: checked out PR #" .. pr_number, vim.log.levels.INFO)
    M._load_pr_data(pr_number, function() M._after_review_load() end, hint)
  end, hint)
end

--- PR number the open views were last built for.
---@type number?
M._loaded_pr_number = nil

--- Rebuild the sidebars that are open from freshly loaded data, so a checkout
--- of another PR (or a reload) does not leave them listing the old files.
--- Closed sidebars stay closed. When the PR itself changed, the diff split and
--- the unified view show a file of the previous PR, so they are closed.
---@param pr_changed boolean
function M._reload_open_views(pr_changed)
  if pr_changed then
    require("gh-review.ui.diff_review").close()
    require("gh-review.ui.unified").close()
  end
  local files = require("gh-review.ui.files")
  local commits = require("gh-review.ui.commits")
  local files_open = files.is_open and files.is_open()
  local commits_open = commits.is_open and commits.is_open()
  if not (files_open or commits_open) then return end
  if files_open then close_snacks_picker("gh_review_files") end
  if commits_open then close_snacks_picker("gh_review_commits") end
  -- Same short delay as _refresh_views: let snacks finish closing first.
  -- Reopened without focus: the cursor stays where you are, or on the file
  -- a load opens (`open_first_file`).
  vim.defer_fn(function()
    if files_open then files.show({ focus = false }) end
    if commits_open then commits.show({ focus = false }) end
  end, 50)
end

--- Join step of `_load_pr_data`: map threads onto the diff and refresh views.
---@param errors string[]
---@param callback? fun()
function M._finish_load(errors, callback)
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

  local pr = state.get_pr()
  local number = pr and pr.number or nil
  M._reload_open_views(number ~= M._loaded_pr_number)
  M._loaded_pr_number = number

  local source = state.get_content_source()
  vim.notify(
    "GHReview: loaded " .. #state.get_files() .. " files, " .. #state.get_threads() .. " threads"
      .. (source and source ~= "network" and (" (diff from " .. source .. ")") or ""),
    vim.log.levels.INFO
  )

  if callback then callback() end
end

--- Load PR metadata, files, diff, and threads.
---
--- Files, diff and commits come from `pr_content` (cache, local repository, or
--- GitHub). They need the PR's head and base oids: when the caller already has
--- them (`hint`, e.g. from a picker), that load starts at once; otherwise it
--- starts as soon as the metadata names them.
---@param pr_number number
---@param callback? fun()
---@param hint? { head_oid?: string, base_oid?: string }
---@param meta? table `gh.pr_view` output the caller already has; skips that call
function M._load_pr_data(pr_number, callback, hint, meta)
  -- 3 parallel operations: metadata + threads, content (files+diff+commits), comments
  local pending = 3
  local errors = {}
  local content_started = false
  -- Merge base the local jj diff starts from; the base side of the views
  -- must use it instead of the one `set_pr` computes.
  local content_base

  local function done()
    pending = pending - 1
    if pending > 0 then return end
    M._finish_load(errors, callback)
  end

  ---@param content GHReviewPRContent
  local function apply_content(content)
    state.set_files(content.files or {})
    state.set_diff_text(content.diff_text or "")
    state.set_commits(content.commits or {})
    state.set_content_source(content.source)
  end

  local function load_remote_content(ref)
    require("gh-review.pr_content").load(ref, function(content_errors, content)
      if content_errors then
        vim.list_extend(errors, content_errors)
      elseif content then
        apply_content(content)
      end
      done()
    end)
  end

  --- The local jj version of the PR (`toggle_local_diff`), or GitHub's when
  --- there is none: the PR is not in this repository, or this is not jj.
  local function load_local_content(ref, refs)
    require("gh-review.pr_content").load_jj({
      head_ref = refs.head_ref,
      head_oid = ref.head_oid,
      base_ref = refs.base_ref,
      base_oid = ref.base_oid,
    }, function(err, content)
      if err or not content then
        vim.notify("GHReview: no local jj diff (" .. (err or "unknown") .. "), showing GitHub's", vim.log.levels.WARN)
        state.set_local_diff(false)
        load_remote_content(ref)
        return
      end
      apply_content(content)
      content_base = content.base_sha
      local pr = state.get_pr()
      if pr and pr.number == pr_number and content_base then pr.base_sha = content_base end
      done()
    end)
  end

  ---@param refs? { head_ref?: string, base_ref?: string } Branches, from the metadata
  local function load_content(head_oid, base_oid, repo, refs)
    if content_started then return end
    content_started = true
    local ref = {
      repo = repo ~= "" and repo or nil,
      number = pr_number,
      head_oid = head_oid,
      base_oid = base_oid,
    }
    if state.get_local_diff() and vcs.jj_root() then
      load_local_content(ref, refs or {})
    else
      load_remote_content(ref)
    end
  end

  -- The local diff needs the branch names, which only the metadata has.
  local early_content = not state.get_local_diff() and hint and hint.head_oid and hint.base_oid

  --- Nothing will name the commits (metadata or repo failed): the content
  --- load will not run, so count it as finished.
  local function skip_content()
    if content_started then return end
    content_started = true
    done()
  end

  -- Metadata and threads, counted as ONE pending item made of two parts:
  -- "pr" (set_pr, needs metadata and repo) and "threads" (needs repo only).
  -- `gh.repo_name` is memoized, so threads, the PR id and (with a hint) the
  -- content start at once, side by side with `pr_view` — or without it, when
  -- the caller already has the metadata (`meta`).
  local meta_data = meta
  local repo_value, node_id
  local parts_left = 2
  local finished = {}
  local function finish(part)
    if finished[part] then return end
    finished[part] = true
    parts_left = parts_left - 1
    if parts_left == 0 then done() end
  end

  local function apply_metadata()
    if not (meta_data and repo_value) then return end
    local data = meta_data
    load_content(
      type(data.headRefOid) == "string" and data.headRefOid or nil,
      type(data.baseRefOid) == "string" and data.baseRefOid or nil,
      repo_value,
      { head_ref = data.headRefName, base_ref = data.baseRefName }
    )

    state.set_pr({
      number = data.number,
      title = data.title,
      author = data.author and data.author.login or "unknown",
      base_ref = data.baseRefName,
      base_sha = content_base or util.git_merge_base(data.baseRefName, vim.fn.getcwd()),
      head_ref = data.headRefName,
      head_sha = type(data.headRefOid) == "string" and data.headRefOid or nil,
      url = data.url,
      body = data.body or "",
      review_decision = data.reviewDecision or "",
      repository = repo_value,
      node_id = node_id,
    })

    -- Seed view mode from config only on first PR load of the session
    -- so a user's toggle choice persists across refreshes.
    if not state.get_view_mode() then
      state.set_view_mode(config.get().default_view_mode or "split")
    end

    -- Apply default ignore-whitespace preference. Done here (rather than at
    -- plugin setup) so it only takes effect while a review is active;
    -- M.close reliably unwinds it.
    if config.get().default_ignore_whitespace and not util.ignore_whitespace_active() then
      util.enable_ignore_whitespace()
    end
    finish("pr")
  end

  gh.repo_name(function(repo_err, repo)
    if repo_err then
      table.insert(errors, "repo: " .. repo_err)
      finish("pr")
      finish("threads")
      skip_content()
      return
    end
    repo_value = repo

    if early_content then
      load_content(hint.head_oid, hint.base_oid, repo)
    end

    local owner, repo_name = repo:match("^(.+)/(.+)$")
    if not owner or not repo_name then
      table.insert(errors, "invalid repo format: " .. (repo or "nil"))
      finish("threads")
    else
      -- PR node ID for mutations (fire and forget). It may land before the
      -- metadata; set_pr picks it up then.
      graphql.fetch_pr_id(owner, repo_name, pr_number, function(id_err, pr_id)
        if id_err then
          table.insert(errors, "pr_id: " .. id_err)
          return
        end
        node_id = pr_id
        local pr = state.get_pr()
        if pr and pr.number == pr_number then pr.node_id = pr_id end
      end)

      graphql.fetch_threads(owner, repo_name, pr_number, function(t_err, threads)
        if t_err then
          table.insert(errors, "threads: " .. t_err)
        else
          state.set_threads(threads or {})
        end
        finish("threads")
      end)
    end

    apply_metadata()
  end)

  if not meta_data then
    gh.pr_view(pr_number, function(err, data)
      if err or not data then
        table.insert(errors, "metadata: " .. (err or "empty response"))
        finish("pr")
        if not early_content then skip_content() end
        return
      end
      meta_data = data
      apply_metadata()
    end)
  end

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

--- Switch the review between the PR as it is on GitHub and its local jj
--- version: the head branch as it is in this repository, plus unpushed commits
--- and working-copy edits on top of it, up to the last non-empty commit. The
--- threads stay those of GitHub. The choice holds across refreshes until the
--- review closes.
function M.toggle_local_diff()
  if not require_active() then return end
  local on = not state.get_local_diff()
  if on and not vcs.jj_root() then
    vim.notify("GHReview: the local diff requires a jj workspace", vim.log.levels.WARN)
    return
  end
  local pr = state.get_pr()
  state.set_local_diff(on)
  -- Commit oids differ between the two versions: a commit filter of one does
  -- not exist in the other.
  state.clear_active_commit()
  vim.notify(
    "GHReview: " .. (on and "loading the local jj diff" or "loading the GitHub diff") .. " of PR #" .. pr.number .. "...",
    vim.log.levels.INFO
  )
  M._load_pr_data(pr.number, function() M._refresh_views() end)
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

--- A window to open a file in: the current one, unless it is floating or a
--- picker (the files sidebar, an explorer), then the first normal window of
--- the tab. A start screen such as the snacks dashboard is fine: the file
--- replaces it.
---@return number? win
local function file_window()
  local function usable(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    return not ft:match("^snacks_picker")
  end
  local current = vim.api.nvim_get_current_win()
  if usable(current) then return current end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

--- What follows a review load (checkout, review of the current branch): the
--- first file of the diff list and the files sidebar, as configured. The
--- sidebar opens without taking the focus from the file.
function M._after_review_load()
  local cfg = config.get()
  if cfg.open_first_file then M._open_first_file() end
  if cfg.open_files_on_load then
    local files = require("gh-review.ui.files")
    if not (files.is_open and files.is_open()) then files.show({ focus = false }) end
  end
end

--- Open the first file of the diff list, in the order of the files sidebar.
function M._open_first_file()
  local first = require("gh-review.ui.files").display_order(state.get_effective_files())[1]
  if not first then return end
  local win = file_window()
  if not win then return end
  vim.api.nvim_set_current_win(win)
  M._open_file(first.path)
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
  if active_commit and not state.is_commit_on_disk() then
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
  M._loaded_pr_number = nil
  close_snacks_picker("gh_review_gh_stack")
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

--- Lines `start_line`..`end_line` of the current buffer, which a suggestion
--- replaces. Nil where the buffer does not hold the new version of the file
--- line for line: the base side of the split, the unified view.
---@param start_line number
---@param end_line number
---@return string[]?
local function suggestion_source(start_line, end_line)
  local name = vim.api.nvim_buf_get_name(0)
  if name:match("^ghreview://base/") or name:match("^ghreview://unified/") then return nil end
  return vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
end

--- `comment_input` options for a comment on `start_line`..`end_line`: the
--- key that inserts a suggestion block of those lines and, with `suggest`, a
--- body that starts as one, the cursor on its first line of code. Nil (after
--- a warning) when `suggest` is asked where there is nothing to suggest on.
---@param start_line number
---@param end_line number
---@param suggest? boolean
---@return table?
local function suggestion_input(start_line, end_line, suggest)
  local lines = suggestion_source(start_line, end_line)
  if suggest and not lines then
    vim.notify("GHReview: suggest a change from the new side of the diff (split right side or inline view)", vim.log.levels.WARN)
    return nil
  end
  return {
    suggestion_lines = lines,
    body_lines = suggest and util.suggestion_block(lines) or nil,
    cursor_line = suggest and 2 or nil,
  }
end

--- Start a new inline comment thread at cursor, or across a visual range.
--- When `start_line` and `end_line` are both given, creates a multi-line
--- thread spanning those lines. With no args, falls back to the cursor line.
--- `opts.suggest` opens the input on a suggestion block of those lines.
---@param start_line? number
---@param end_line? number
---@param opts? { suggest?: boolean }
function M.new_thread(start_line, end_line, opts)
  opts = opts or {}
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

  local input = suggestion_input(start_line, end_line, opts.suggest)
  if not input then return end

  require("gh-review.ui.comment_input").open(vim.tbl_extend("force", input, {
    title = (opts.suggest and "Suggest Change: " or "New Thread: ") .. rel_path .. ":" .. range_label,
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
  }))
end

--- Suggest a change to the line at the cursor, or to a visual range: a new
--- pending thread whose body starts as a GitHub suggestion block of those
--- lines. Edit the code in the block; GitHub offers to apply it on the PR.
---@param start_line? number
---@param end_line? number
function M.suggest_change(start_line, end_line)
  M.new_thread(start_line, end_line, { suggest = true })
end

--- Suggest a change like `M.suggest_change`, but post it immediately instead
--- of holding it in the pending review.
---@param start_line? number
---@param end_line? number
function M.suggest_change_direct(start_line, end_line)
  M.new_thread_direct(start_line, end_line, { suggest = true })
end

--- Start an inline comment that is published immediately, instead of being
--- held back in a pending review the way `M.new_thread` is. Same cursor /
--- visual-range semantics as `M.new_thread`, and the same `opts.suggest`.
---@param start_line? number
---@param end_line? number
---@param opts? { suggest?: boolean }
function M.new_thread_direct(start_line, end_line, opts)
  opts = opts or {}
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

  local input = suggestion_input(start_line, end_line, opts.suggest)
  if not input then return end

  require("gh-review.ui.comment_input").open(vim.tbl_extend("force", input, {
    title = (opts.suggest and "Suggest Change (direct): " or "Direct Comment: ") .. rel_path .. ":" .. range_label,
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
  }))
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
  -- `data` is the full metadata already: no second `gh pr view`.
  local function load(data, callback)
    vim.notify("GHReview: loading PR #" .. data.number .. " — " .. data.title, vim.log.levels.INFO)
    M._load_pr_data(data.number, function()
      M._after_review_load()
      if callback then callback() end
    end, hint_of(data), data)
  end

  -- The PR of this working copy was looked up before (startup detection or an
  -- earlier review): load it at once, and check the metadata in the
  -- background. A working copy on another commit may belong to another PR,
  -- so it gets a fresh lookup.
  local detected = M._detected
  local head = vcs.base_commit()
  if detected and detected.head and detected.head == head then
    local loaded, fresh = false, nil
    local function check()
      if not (loaded and fresh) then return end
      M._detected = { data = fresh, head = head }
      local pr = state.get_pr()
      if not pr or pr.number ~= fresh.number then return end
      if fresh.headRefOid ~= detected.data.headRefOid or fresh.baseRefOid ~= detected.data.baseRefOid then
        vim.notify("GHReview: PR #" .. fresh.number .. " changed on GitHub, reloading", vim.log.levels.INFO)
        state.clear_active_commit()
        M._load_pr_data(fresh.number, function() M._refresh_views() end, hint_of(fresh), fresh)
        return
      end
      -- Same commits: only the text may have changed.
      pr.title = fresh.title or pr.title
      pr.body = fresh.body or pr.body
      pr.review_decision = fresh.reviewDecision or pr.review_decision
    end
    load(detected.data, function()
      loaded = true
      check()
    end)
    gh.pr_view(detected.data.number, function(err, data)
      if err or not data then return end
      fresh = data
      check()
    end)
    return
  end

  vim.notify("GHReview: detecting PR for current branch...", vim.log.levels.INFO)
  -- Resolve the repo while the PR is looked up, not after.
  gh.repo_name(function() end)
  gh.pr_view_current(function(err, data)
    if err then
      vim.notify("GHReview: no PR for current branch: " .. err, vim.log.levels.ERROR)
      return
    end
    M._detected = { data = data, head = head }
    vim.schedule(function() load(data) end)
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

--- What a `gh pr list` entry tells about a PR's commits and branch.
---@param pr table?
---@return GHReviewCheckoutHint?
local function pr_hint(pr)
  if not pr then return nil end
  local function str(v) return type(v) == "string" and v ~= "" and v or nil end
  return { head_oid = str(pr.headRefOid), base_oid = str(pr.baseRefOid), head_ref = str(pr.headRefName) }
end

--- Checkout a PR without loading a review.
---@param pr_number number
---@param hint? GHReviewCheckoutHint
local function checkout_only(pr_number, hint)
  vim.notify("GHReview: checking out PR #" .. pr_number .. "...", vim.log.levels.INFO)
  gh.checkout(pr_number, function(err)
    if err then
      vim.notify("GHReview: checkout failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("GHReview: checked out PR #" .. pr_number, vim.log.levels.INFO)
  end, hint)
end

--- Checkout a PR and review it, dropping the commit filter of the PR before.
---@param pr_number number
---@param hint? { head_oid?: string, base_oid?: string }
local function checkout_and_review(pr_number, hint)
  state.clear_active_commit()
  M.checkout(pr_number, hint)
end

--- Check out and review the first (closest to the base) or last open PR of
--- yours in a native stack.
---@param stack GHReviewStack
---@param which "first"|"last"
function M._review_own_stack_pr(stack, which)
  gh.viewer_login(function(err, login)
    if err or not login then
      vim.notify("GHReview: could not resolve your GitHub login: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    local pr = require("gh-review.gh_stack").own_pr(stack, login, which)
    if not pr then
      vim.notify("GHReview: stack #" .. stack.number .. " has no open PR of yours", vim.log.levels.INFO)
      return
    end
    local function str(v) return v ~= "" and v or nil end
    checkout_and_review(pr.number, { head_oid = pr.head_oid, base_oid = pr.base_oid, head_ref = str(pr.head_ref) })
  end)
end

--- List open PRs in a scope (all, mine, involved in review, by author). The
--- scope keys switch it in place; with no scope the picker reopens on the last
--- one. `<cr>` checks out and reviews, the checkout key only checks out.
---@param scope? GHReviewScope
function M.pr_list(scope)
  local pr_picker = require("gh-review.ui.pr_picker")
  pr_picker.show({
    title = "PRs",
    scope = scope or pr_picker.last_scope,
    on_select = function(n, pr)
      checkout_and_review(n, pr_hint(pr))
    end,
    on_checkout = function(n, pr) checkout_only(n, pr_hint(pr)) end,
    on_own_stack_pr = M._review_own_stack_pr,
  })
end

--- Resolve owner/name of the current repo.
---@param callback fun(full: string, owner: string, name: string)
local function with_repo(callback)
  gh.repo_name(function(err, full)
    local owner, name = (full or ""):match("^(.+)/(.+)$")
    if err or not owner then
      vim.notify("GHReview: could not resolve the repository: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    callback(full, owner, name)
  end)
end

---@param err string
local function report_stack_error(err)
  if require("gh-review.gh_stack").is_unsupported_error(err) then
    vim.notify("GHReview: native PR stacks are not available on this GitHub host", vim.log.levels.WARN)
    return
  end
  if require("gh-review.gh_stack").is_timeout_error(err) then
    vim.notify(
      "GHReview: GitHub timed out loading stacks; narrow the scope (mine, review, author): " .. err,
      vim.log.levels.ERROR
    )
    return
  end
  vim.notify("GHReview: failed to load stacks: " .. err, vim.log.levels.ERROR)
end

---@type GHReviewScope
M._last_stack_scope = { kind = "all" }

--- List the native GitHub stacks that hold a PR in `scope`. `<cr>` opens the
--- stack panel, the checkout key checks the stack out.
---@param scope? GHReviewScope
function M.gh_stacks(scope)
  local gh_stack = require("gh-review.gh_stack")
  local scope_mod = require("gh-review.scope")
  scope = scope or M._last_stack_scope
  M._last_stack_scope = scope
  with_repo(function(_, owner, name)
    vim.notify("GHReview: fetching stacks (" .. scope_mod.label(scope) .. ")...", vim.log.levels.INFO)
    scope_mod.fetch_all(scope, function(term, cb)
      graphql.search_stacked_prs(owner, name, term, cb)
    end, function(err, nodes)
      if err then
        report_stack_error(err)
        return
      end
      local stacks = gh_stack.group(nodes or {})
      if #stacks == 0 then
        vim.notify("GHReview: no GitHub stacks found (" .. scope_mod.label(scope) .. ")", vim.log.levels.INFO)
        return
      end
      -- Draw the metadata now; merge statuses fill in when they arrive.
      local picker
      require("gh-review.stack_status").load(owner .. "/" .. name, stacks, {}, function(status_err)
        if status_err then
          report_stack_error(status_err)
          return
        end
        require("gh-review.ui.picker_util").redraw(picker)
      end)
      picker = require("gh-review.ui.gh_stack").show_list(stacks, {
        scope = scope,
        on_select = function(stack)
          M.gh_stack_panel(stack.entries[#stack.entries].pr.number)
        end,
        on_checkout = M._checkout_stack,
        on_scope = M.gh_stacks,
        on_own = M._review_own_stack_pr,
      })
    end)
  end)
end

--- Checkout a native stack (every open branch under jj, the top PR under git)
--- and review its topmost open PR.
---@param stack GHReviewStack
function M._checkout_stack(stack)
  local gh_stack = require("gh-review.gh_stack")
  local top = gh_stack.top_open(stack)
  if not top then
    vim.notify("GHReview: every PR of stack #" .. stack.number .. " is merged or closed", vim.log.levels.INFO)
    return
  end
  vim.notify("GHReview: checking out stack #" .. stack.number .. "...", vim.log.levels.INFO)
  gh.checkout_stack(top.number, gh_stack.open_branches(stack), function(err)
    if err then
      vim.notify("GHReview: stack checkout failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("GHReview: checked out stack #" .. stack.number .. " at PR #" .. top.number, vim.log.levels.INFO)
    state.clear_active_commit()
    M._load_pr_data(top.number, nil, { head_oid = top.head_oid, base_oid = top.base_oid })
  end, top.head_oid)
end

--- Delay between two polls of an async merge, and how many polls to make.
M._merge_poll_ms = 3000
M._merge_poll_limit = 100

--- Report an async merge result, polling again while it is pending.
---@param repo string owner/name
---@param pr_number number PR the merge was requested on
---@param result { status: string, details: table }?
---@param label string PRs being merged, e.g. "#1, #2"
---@param attempt number
function M._handle_merge_result(repo, pr_number, result, label, attempt)
  local status = result and result.status
  local details = result and result.details or {}
  if status == "merged" then
    vim.notify("GHReview: merged " .. label, vim.log.levels.INFO)
  elseif status == "enqueued" then
    vim.notify("GHReview: added " .. label .. " to the merge queue", vim.log.levels.INFO)
  elseif status == "failed" then
    vim.notify("GHReview: merge of " .. label .. " failed: " .. (details.message or "unknown error"), vim.log.levels.ERROR)
  elseif status == "pending" and details.uuid then
    if attempt == 0 then
      vim.notify("GHReview: merging " .. label .. "...", vim.log.levels.INFO)
    end
    if attempt >= M._merge_poll_limit then
      vim.notify("GHReview: merge of " .. label .. " still pending, check it on GitHub", vim.log.levels.WARN)
      return
    end
    vim.defer_fn(function()
      gh.pr_merge_async_status(repo, pr_number, details.uuid, function(err, next_result)
        if err then
          vim.notify("GHReview: could not poll the merge of " .. label .. ": " .. err, vim.log.levels.ERROR)
          return
        end
        M._handle_merge_result(repo, pr_number, next_result, label, attempt + 1)
      end)
    end, M._merge_poll_ms)
  else
    vim.notify("GHReview: unexpected merge status '" .. tostring(status) .. "'", vim.log.levels.WARN)
  end
end

--- Merge the PR at `position` of a stack, and with it every open PR below.
--- Asks for the merge method (unless a merge queue decides it) and a confirmation.
---@param repo string owner/name
---@param stack GHReviewStack
---@param settings GHReviewMergeSettings
---@param position number
function M._merge_stack(repo, stack, settings, position)
  local gh_stack = require("gh-review.gh_stack")
  local ok, reason = gh_stack.can_merge(stack, position)
  if not ok then
    vim.notify("GHReview: cannot merge yet — " .. reason, vim.log.levels.WARN)
    return
  end
  local target = gh_stack.entry_at(stack, position).pr
  local nums = {}
  for _, pr in ipairs(gh_stack.merge_set(stack, position)) do
    table.insert(nums, "#" .. pr.number)
  end
  local label = table.concat(nums, ", ")

  local function confirm(method)
    local prompt = settings.merge_queue
        and string.format("Add %s to the merge queue of %s?", label, stack.base)
      or string.format("Merge %s into %s (%s)?", label, stack.base, method or "default")
    vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
      if choice ~= "Yes" then return end
      gh.pr_merge_async(repo, target.number, { merge_method = method, sha = target.head_oid }, function(err, result)
        if err then
          vim.notify("GHReview: merge request failed: " .. err, vim.log.levels.ERROR)
          return
        end
        M._handle_merge_result(repo, target.number, result, label, 0)
      end)
    end)
  end

  -- A merge queue ignores the method, and a single allowed method needs no prompt.
  if settings.merge_queue then
    confirm(nil)
  elseif #settings.methods <= 1 then
    confirm(settings.methods[1])
  else
    vim.ui.select(settings.methods, { prompt = "Merge method" }, function(method)
      if method then confirm(method) end
    end)
  end
end

--- Open the checks window of a PR: failing jobs first. Checks of a head
--- commit are cached once none is pending; `R` in the window refetches.
---@param repo string owner/name
---@param pr GHReviewStackPR
---@param force? boolean Skip the cache
---@param win? GHReviewChecksWindow Window to refill instead of opening one
function M._show_checks(repo, pr, force, win)
  local cache = require("gh-review.cache")
  local owner, name = repo:match("^(.+)/(.+)$")
  win = win or require("gh-review.ui.pr_checks").open(pr, {
    on_refresh = function() M._show_checks(repo, pr, true, win) end,
  })
  local key = pr.head_oid and (repo .. "#" .. pr.number .. "@" .. pr.head_oid) or nil
  local hit = not force and key and cache.get("checks", key) or nil
  if type(hit) == "table" and hit.checks then
    win.set(hit)
    return
  end
  graphql.fetch_pr_checks(owner, name, pr.number, function(err, result)
    if err then
      win.set_error(err)
      return
    end
    win.set(result)
    local settled = true
    for _, c in ipairs(result.checks) do
      if c.state == "PENDING" then settled = false end
    end
    -- Cache under the commit the checks ran on, which may be newer than ours.
    if settled and result.head_oid then
      cache.set("checks", repo .. "#" .. pr.number .. "@" .. result.head_oid, result)
    end
  end)
end

--- Toggle the panel over a native GitHub stack: every PR with whether it can
--- merge. Defaults to the stack of the PR under review, else of the current
--- branch. `<cr>` checks out and reviews a PR, the merge key merges up to the PR
--- under the cursor, the checkout key checks out the whole stack.
---@param pr_number? number Any PR of the stack
function M.gh_stack_panel(pr_number)
  local ui = require("gh-review.ui.gh_stack")
  if not pr_number and ui.close_panel() then return end

  local function open(number, force)
    with_repo(function(full, owner, name)
      graphql.fetch_pr_stack(owner, name, number, function(err, raw, settings)
        if err then
          report_stack_error(err)
          return
        end
        if not raw then
          vim.notify("GHReview: PR #" .. number .. " is not part of a GitHub stack", vim.log.levels.INFO)
          return
        end
        local stack = require("gh-review.gh_stack").parse_stack(raw)
        local current = state.get_pr()
        local picker
        -- Cached statuses apply before the panel draws; the rest redraw it later.
        require("gh-review.stack_status").load(full, { stack }, { force = force }, function(status_err)
          if status_err then
            report_stack_error(status_err)
            return
          end
          require("gh-review.ui.picker_util").redraw(picker, ui.panel_title(stack))
        end)
        picker = ui.show_panel(stack, {
          current_pr = current and current.number or nil,
          on_review = function(entry)
            checkout_and_review(entry.pr.number, {
              head_oid = entry.pr.head_oid,
              base_oid = entry.pr.base_oid,
              head_ref = entry.pr.head_ref,
            })
          end,
          on_merge = function(entry) M._merge_stack(full, stack, settings, entry.position) end,
          on_checkout = function() M._checkout_stack(stack) end,
          on_own = function(which) M._review_own_stack_pr(stack, which) end,
          on_refresh = function() open(number, true) end,
          on_details = function(entry) M._show_checks(full, entry.pr) end,
        })
      end)
    end)
  end

  if pr_number then
    open(pr_number)
    return
  end
  local current = state.get_pr()
  if current then
    open(current.number)
    return
  end
  gh.pr_view_current(function(err, data)
    if err or not data then
      vim.notify("GHReview: no PR under review or for the current branch; list stacks instead", vim.log.levels.WARN)
      return
    end
    open(data.number)
  end)
end

--- Select a specific commit for filtered review
---@param commit GHReviewCommit
---@param after? fun() Runs once the views are rebuilt (see `_refresh_views`)
function M.select_commit(commit, after)
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

  -- After a stack step or `<leader>gpk`, the working copy sits on the commit:
  -- the views can then edit its files on disk.
  state.set_active_commit(commit, vcs.base_commit() == commit.oid)
  state.set_commit_files(files)
  M._refresh_views(after)
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

--- Whether `jj_commit` is the tip of the loaded PR: it carries the PR head
--- branch (which also holds after a local rewrite), or it is the PR head or
--- the last commit of the PR.
---@param jj_commit GHReviewJJCommit
---@return boolean
local function is_pr_tip(jj_commit)
  local pr = state.get_pr()
  if not pr then return false end
  if pr.head_ref and vim.tbl_contains(jj_commit.bookmarks or {}, pr.head_ref) then return true end
  if pr.head_sha == jj_commit.commit_id then return true end
  local commits = state.get_commits()
  local last = commits[#commits]
  return last ~= nil and last.oid == jj_commit.commit_id
end

--- Show the loaded PR as a whole, without a commit filter.
---@param after? fun()
local function show_whole_pr(after)
  state.clear_active_commit()
  M._refresh_views(after)
  vim.notify("GHReview: showing full PR #" .. state.get_pr().number, vim.log.levels.INFO)
end

---@class GHReviewStackGotoOpts
---@field whole_pr_at_tip? boolean Show the whole PR, not one commit, when the commit is the tip of its PR
---@field open_first_file? boolean Open the first file of the diff list afterwards (if `open_first_file` is on)

--- What to run once the review moved, per `opts.open_first_file`.
---@param opts GHReviewStackGotoOpts
---@return fun()?
local function after_goto(opts)
  if opts.open_first_file and config.get().open_first_file then return M._open_first_file end
  return nil
end

--- Load another PR of the stack and scope the review to `oid` once its data is in.
---@param pr_number number
---@param title string?
---@param jj_commit GHReviewJJCommit
---@param opts GHReviewStackGotoOpts
local function load_pr_at_commit(pr_number, title, jj_commit, opts)
  local oid = jj_commit.commit_id
  vim.notify(
    "GHReview: loading PR #" .. pr_number .. (title and title ~= "" and (" — " .. title) or "") .. "...",
    vim.log.levels.INFO
  )
  -- The old PR's commit filter must not survive into the new one.
  state.clear_active_commit()
  local after = after_goto(opts)
  M._load_pr_data(pr_number, function()
    if opts.whole_pr_at_tip and is_pr_tip(jj_commit) then
      M._refresh_views(after)
      return
    end
    local commit = pr_commit_by_oid(oid)
    if commit then
      M.select_commit(commit, after)
      return
    end
    -- The commit sits in this PR's stack range but is not one of its commits,
    -- which normally means it has not been pushed yet. Show the whole PR.
    M._refresh_views(after)
    vim.notify(
      "GHReview: PR #" .. pr_number .. " loaded; commit " .. oid:sub(1, 8) .. " is not part of it",
      vim.log.levels.WARN
    )
  end)
end

--- Put the jj working copy on `jj_commit`, so the files on disk (and the
--- right side of the diff views) are that commit's. A failure is reported but
--- does not stop the review from moving.
---@param jj_commit GHReviewJJCommit
---@param callback fun()
local function checkout_stack_commit(jj_commit, callback)
  vcs.jj_move_to(jj_commit.commit_id, function(err, moved)
    if err then
      vim.notify("GHReview: jj new " .. jj_commit_label(jj_commit) .. " failed: " .. err, vim.log.levels.WARN)
    elseif moved then
      -- Reload the buffers of files `jj new` rewrote.
      vim.cmd("silent! checktime")
    end
    callback()
  end)
end

--- Move the review onto a jj commit of the stack: check the commit out in jj,
--- then re-scope when it belongs to the PR already loaded, otherwise load the
--- PR of the stack that owns it.
---@param jj_commit GHReviewJJCommit
---@param opts? GHReviewStackGotoOpts
function M._goto_stack_commit(jj_commit, opts)
  checkout_stack_commit(jj_commit, function() M._review_stack_commit(jj_commit, opts or {}) end)
end

--- The review half of `_goto_stack_commit`.
---@param jj_commit GHReviewJJCommit
---@param opts GHReviewStackGotoOpts
function M._review_stack_commit(jj_commit, opts)
  local after = after_goto(opts)
  if opts.whole_pr_at_tip and is_pr_tip(jj_commit) then
    show_whole_pr(after)
    return
  end
  local commit = pr_commit_by_oid(jj_commit.commit_id)
  if commit then
    M.select_commit(commit, after)
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
      load_pr_at_commit(data.number, data.title, jj_commit, opts)
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
        M._goto_stack_commit(commit, { open_first_file = true })
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
        -- A PR's entry in the picker is its tip commit: picking it means the PR.
        on_select = function(commit)
          M._goto_stack_commit(commit, { whole_pr_at_tip = true, open_first_file = true })
        end,
      })
    end)
  end)
end

--- Refresh all views after commit selection change. `after`, when given, runs
--- once the views are rebuilt (it opens a file), and the files sidebar then
--- reopens without taking the focus from it.
---@param after? fun()
function M._refresh_views(after)
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
    if after then after() end
    require("gh-review.ui.files").show(after and { focus = false } or nil)
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
  map(km.suggest_change, M.suggest_change, "Suggest a change (pending review)")
  vim.keymap.set("x", prefix .. km.suggest_change, function()
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    M.suggest_change(math.min(a, b), math.max(a, b))
  end, vim.tbl_extend("force", opts, { desc = "Suggest a change to the selected lines" }))
  map(km.suggest_change_direct, M.suggest_change_direct, "Suggest a change (posted immediately)")
  vim.keymap.set("x", prefix .. km.suggest_change_direct, function()
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    M.suggest_change_direct(math.min(a, b), math.max(a, b))
  end, vim.tbl_extend("force", opts, { desc = "Suggest a change to the selected lines (posted immediately)" }))
  map(km.pending_review, M.pending_review, "Review/submit unsubmitted comments")
  map(km.review_pr, M.review_pr, "Approve / comment / request changes on the PR")
  map(km.next_stack, M.next_stack_commit, "Next commit in the jj stack")
  map(km.prev_stack, M.prev_stack_commit, "Previous commit in the jj stack")
  map(km.stack, M.stack_panel, "Toggle the jj stack picker")
  map(km.pr_list, function() M.pr_list() end, "List PRs (all / mine / review / author)")
  map(km.gh_stacks, function() M.gh_stacks() end, "List GitHub PR stacks")
  map(km.gh_stack, function() M.gh_stack_panel() end, "Toggle the GitHub stack panel (merge status)")
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
  map(km.local_diff, M.toggle_local_diff, "Toggle the local jj diff of the PR")
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
