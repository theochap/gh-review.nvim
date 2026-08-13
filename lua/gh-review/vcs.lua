--- VCS context detection for git worktrees and jj (Jujutsu) repositories.
---
--- Everything in this plugin ultimately shells out to `git` (for base-side file
--- content) and `gh` (for PR data), and both assume the cwd is inside a git
--- worktree whose HEAD is on a branch. Neither holds under jj:
---
---   * jj leaves git HEAD detached, so `gh pr view` (no argument) fails with
---     "not on any branch" and PR auto-detection never fires. The branch a PR
---     was opened from lives in a jj *bookmark* instead.
---   * A secondary jj workspace (`jj workspace add`) contains only a `.jj/`
---     directory — no `.git` at all — so plain `git`/`gh` invocations fail with
---     "not a git repository". The backing git repo is reachable through
---     `.jj/repo` → `store/git_target`.
---   * A non-colocated jj repo keeps its git store as a bare repo under
---     `.jj/repo/store/git`, which `gh` cannot discover from the cwd.
---
--- This module resolves the layout using filesystem reads only (no
--- subprocesses, so it is cheap and safe to call from hot paths), and exposes:
---
---   * `git_cmd()`  — a `git` command pointed at the backing repo when needed
---   * `gh_context()` — cwd/env so `gh` can identify the repo
---   * `pr_branch_candidates()` — branch names to look a PR up by when git HEAD
---     is detached (jj bookmarks; requires running `jj`)
---   * `head_rev()` — the revision to diff against the base
local M = {}

local uv = vim.uv or vim.loop

---@class GHReviewVcsContext
---@field kind "git"|"jj"|"none" "git" when the cwd is inside a git worktree
---@field root string? Worktree root — where the reviewed files live
---@field jj_root string? jj workspace root, when inside jj (colocated included)
---@field dot_git string? Resolved `.git` directory of the cwd's worktree, if any
---@field git_dir string? Backing git directory; set only when `git` needs `--git-dir`
---@field gh_cwd string? Directory to run `gh` in; nil means inherit Neovim's cwd
---@field gh_env table? Extra environment for `gh` (GH_REPO) when it cannot self-resolve
---@field remote string? Git remote name backing the repo (usually "origin")

---@type table<string, GHReviewVcsContext>
local cache = {}

--- Read a whole file, returning nil when it doesn't exist or can't be read.
---@param path string
---@return string?
local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local content = fd:read("*a")
  fd:close()
  return content
end

---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

--- Join `rel` onto `base` unless `rel` is already absolute; always normalized.
---@param base string
---@param rel string
---@return string
local function join(base, rel)
  if is_absolute(rel) then return vim.fs.normalize(rel) end
  return vim.fs.normalize(base .. "/" .. rel)
end

--- Walk up from `cwd` looking for the nearest `.git` or `.jj` marker.
--- When a directory holds both (a colocated jj repo) git wins: git commands
--- work there directly, so there is nothing to redirect.
---@param cwd string
---@return string? dir, boolean has_git, boolean has_jj
local function nearest_marker(cwd)
  local dirs = { vim.fs.normalize(cwd) }
  for parent in vim.fs.parents(dirs[1]) do
    table.insert(dirs, parent)
  end
  for _, dir in ipairs(dirs) do
    local has_git = uv.fs_stat(dir .. "/.git") ~= nil
    local has_jj = uv.fs_stat(dir .. "/.jj") ~= nil
    if has_git or has_jj then
      return dir, has_git, has_jj
    end
  end
  return nil, false, false
end

--- Resolve a worktree's `.git` to a real directory. In linked worktrees and
--- submodules `.git` is a file containing `gitdir: <path>`.
---@param root string
---@return string?
local function resolve_dot_git(root)
  local path = root .. "/.git"
  local st = uv.fs_stat(path)
  if not st then return nil end
  if st.type == "directory" then return path end
  local target = (read_file(path) or ""):match("^gitdir:%s*(.-)%s*$")
  if not target then return nil end
  return join(root, target)
end

--- Resolve the git directory backing a jj repository.
--- `.jj/repo` is either the repo directory itself or, in a secondary workspace,
--- a file holding the path to the main workspace's `.jj/repo`. The git store
--- location then comes from `store/git_target` — `../../../.git` for a
--- colocated repo, `git` (a bare repo) otherwise.
---@param jj_root string
---@return string?
local function resolve_jj_git_dir(jj_root)
  local repo = jj_root .. "/.jj/repo"
  local st = uv.fs_stat(repo)
  if not st then return nil end
  if st.type ~= "directory" then
    local pointer = read_file(repo)
    if not pointer or vim.trim(pointer) == "" then return nil end
    repo = join(jj_root .. "/.jj", vim.trim(pointer))
  end
  local target = read_file(repo .. "/store/git_target")
  if not target or vim.trim(target) == "" then return nil end
  return join(repo .. "/store", vim.trim(target))
end

--- Turn a git remote URL into the `[HOST/]OWNER/REPO` form GH_REPO accepts.
---@param url string
---@return string?
local function gh_repo_from_url(url)
  local host, path
  -- scheme://[user[:password]@]host[:port]/path
  local rest = url:match("^%a[%w+.%-]*://(.+)$")
  if rest then
    host, path = rest:gsub("^[^/]*@", ""):match("^([^/]+)/(.+)$")
  else
    -- scp-style: [user@]host:path
    host, path = url:match("^[^@/]+@([^:/]+):(.+)$")
  end
  if not host or not path then return nil end
  host = host:gsub(":%d+$", "")
  path = path:gsub("%.git$", ""):gsub("^/+", ""):gsub("/+$", "")
  local owner, name = path:match("^([^/]+)/(.+)$")
  if not owner or not name then return nil end
  if host == "github.com" then
    return owner .. "/" .. name
  end
  return host .. "/" .. owner .. "/" .. name
end

--- Parse `<git_dir>/config` for the remote to talk to. Prefers "origin",
--- otherwise the first remote defined. Returns the remote name and the
--- GH_REPO-style identifier derived from its URL.
---@param git_dir string
---@return string? remote, string? gh_repo
local function remote_from_config(git_dir)
  local content = read_file(git_dir .. "/config")
  if not content then return nil, nil end

  local urls, order, section = {}, {}, nil
  for line in content:gmatch("[^\n]*") do
    local name = line:match('^%s*%[remote%s+"([^"]+)"%]')
    if name then
      section = name
      table.insert(order, name)
    elseif line:match("^%s*%[") then
      section = nil
    elseif section then
      local url = line:match("^%s*url%s*=%s*(.+)$")
      if url and not urls[section] then
        urls[section] = vim.trim(url)
      end
    end
  end

  local remote = urls.origin and "origin" or nil
  if not remote then
    for _, name in ipairs(order) do
      if urls[name] then
        remote = name
        break
      end
    end
  end
  if not remote then return nil, nil end
  return remote, gh_repo_from_url(urls[remote])
end

---@param cwd string
---@return GHReviewVcsContext
local function detect(cwd)
  local dir, has_git, has_jj = nearest_marker(cwd)
  if not dir then
    return { kind = "none" }
  end

  if has_git then
    -- Plain git worktree, or a colocated jj repo: `git` and `gh` both work from
    -- the cwd as-is. Only branch detection needs jj help (HEAD is detached),
    -- which `pr_branch_candidates` handles via `jj_root`.
    return {
      kind = "git",
      root = dir,
      jj_root = has_jj and dir or nil,
      dot_git = resolve_dot_git(dir),
    }
  end

  ---@type GHReviewVcsContext
  local ctx = { kind = "jj", root = dir, jj_root = dir }
  ctx.git_dir = resolve_jj_git_dir(dir)
  if not ctx.git_dir then return ctx end

  local remote, gh_repo = remote_from_config(ctx.git_dir)
  ctx.remote = remote

  -- A colocated main workspace ends in `.git` next to a real checkout: running
  -- `gh` there lets it resolve remotes (and honour `gh repo set-default`) the
  -- usual way. A bare store has no such directory, so identify the repo
  -- explicitly through GH_REPO instead.
  local parent = vim.fs.dirname(ctx.git_dir)
  if vim.fs.basename(ctx.git_dir) == ".git" and uv.fs_stat(parent .. "/.git") then
    ctx.gh_cwd = parent
  elseif gh_repo then
    ctx.gh_env = { GH_REPO = gh_repo }
  end

  return ctx
end

--- Resolved VCS context for a directory (defaults to Neovim's cwd). Cached per
--- directory; call `invalidate()` if the layout changes mid-session.
---@param cwd? string
---@return GHReviewVcsContext
function M.context(cwd)
  local key = vim.fs.normalize(cwd or vim.fn.getcwd())
  local ctx = cache[key]
  if not ctx then
    ctx = detect(key)
    cache[key] = ctx
  end
  return ctx
end

--- Drop cached contexts (used after operations that can change the layout, and
--- by tests).
function M.invalidate()
  cache = {}
end

--- Root of the checked-out tree, falling back to Neovim's cwd.
---@param cwd? string
---@return string
function M.root(cwd)
  local base = cwd or vim.fn.getcwd()
  return M.context(base).root or vim.fs.normalize(base)
end

--- The jj workspace root containing `cwd`, or nil when not inside jj.
---@param cwd? string
---@return string?
function M.jj_root(cwd)
  return M.context(cwd).jj_root
end

--- Build a `git` command, pointing it at the backing repository when the cwd
--- is not itself a git worktree (secondary jj workspace, non-colocated jj).
--- Only `--git-dir` is added — never `--work-tree`, because the backing repo's
--- index describes a different checkout and would mislead index-reading
--- commands. All callers use index-free commands (show, merge-base, diff-tree).
---@param args string[] Arguments after `git`
---@param cwd? string
---@return string[]
function M.git_cmd(args, cwd)
  local ctx = M.context(cwd)
  if not ctx.git_dir then
    return vim.list_extend({ "git" }, args)
  end
  return vim.list_extend({ "git", "--git-dir", ctx.git_dir }, args)
end

--- cwd/env that let `gh` identify the repository. Both are nil in a plain git
--- worktree, where `gh` resolves the repo from the cwd on its own.
---@param cwd? string
---@return { cwd: string?, env: table? }
function M.gh_context(cwd)
  local ctx = M.context(cwd)
  return { cwd = ctx.gh_cwd, env = ctx.gh_env }
end

--- Run a `jj` command synchronously in a jj workspace, returning trimmed
--- stdout or nil on failure. `--ignore-working-copy` keeps these reads from
--- snapshotting the working copy (faster, and no new commits as a side effect).
---@param jj_root string
---@param args string[]
---@return string?
local function jj_read(jj_root, args)
  local cmd = vim.list_extend({ "jj", "--ignore-working-copy" }, args)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, cwd = jj_root }):wait()
  end)
  if not ok or result.code ~= 0 or not result.stdout then return nil end
  local out = vim.trim(result.stdout)
  if out == "" then return nil end
  return out
end

--- Name of the git branch HEAD points at, or nil when detached / unreadable.
---@param dot_git string
---@return string?
local function head_branch(dot_git)
  local content = read_file(dot_git .. "/HEAD")
  if not content then return nil end
  return content:match("^ref:%s*refs/heads/(.-)%s*$")
end

--- `jj log` arguments listing bookmark names on the nearest bookmarked ancestor
--- of the working copy: jj's equivalent of "the current branch", and the only
--- way to find the PR when git HEAD is detached. Local bookmarks come first.
---@return string[]
local function bookmark_query()
  local template = 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"'
    .. ' ++ remote_bookmarks.map(|b| b.name()).join("\n") ++ "\n"'
  return {
    "log",
    "-r", "heads(::@ & (bookmarks() | remote_bookmarks()))",
    "--no-graph",
    "-T", template,
  }
end

--- Deduplicate bookmark names from a `bookmark_query` result, preserving order.
---@param out string?
---@return string[]
local function parse_bookmarks(out)
  if not out then return {} end
  local names, seen = {}, {}
  for line in out:gmatch("[^\n]+") do
    local name = vim.trim(line)
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(names, name)
      if #names >= 5 then break end
    end
  end
  return names
end

--- Whether jj has to be consulted for the current branch, i.e. git HEAD is not
--- on a branch (or absent) and we are inside jj. When false, `gh` works out the
--- branch itself — including fork remotes — so we stay out of the way.
---@param ctx GHReviewVcsContext
---@return boolean
local function needs_jj_branch_lookup(ctx)
  if ctx.dot_git and head_branch(ctx.dot_git) then return false end
  return ctx.jj_root ~= nil
end

--- Branch names a PR should be looked up by, most likely first; empty when git
--- can answer on its own. Spawns `jj` synchronously — prefer
--- `pr_branch_candidates_async` outside of blocking contexts like health checks.
---@param cwd? string
---@return string[]
function M.pr_branch_candidates(cwd)
  local ctx = M.context(cwd)
  if not needs_jj_branch_lookup(ctx) then return {} end
  return parse_bookmarks(jj_read(ctx.jj_root, bookmark_query()))
end

--- Async `pr_branch_candidates`. `jj` is only spawned when git HEAD cannot
--- answer, so the common case invokes `callback` immediately.
---@param callback fun(candidates: string[])
---@param cwd? string
function M.pr_branch_candidates_async(callback, cwd)
  local ctx = M.context(cwd)
  if not needs_jj_branch_lookup(ctx) then
    callback({})
    return
  end
  local cmd = vim.list_extend({ "jj", "--ignore-working-copy" }, bookmark_query())
  vim.system(cmd, { text = true, cwd = ctx.jj_root }, function(result)
    local out = result.code == 0 and result.stdout or nil
    vim.schedule(function()
      callback(parse_bookmarks(out and vim.trim(out) or nil))
    end)
  end)
end

---@class GHReviewJJCommit
---@field commit_id string Full git commit id of the jj commit
---@field change_id string Change id, stable across local rewrites of the commit
---@field bookmarks string[] Bookmark names on the commit, local ones first
---@field author string Author name
---@field when string Relative author timestamp ("2 hours ago")
---@field description string First line of the commit description

--- `jj log` template emitting one tab-separated record per commit:
--- `commit_id \t change_id \t locals \t remotes \t author \t when \t description`.
--- The description comes last because it is the only field that could contain a
--- tab; nothing can contain a newline, so records split on those.
local COMMIT_TEMPLATE = table.concat({
  "commit_id",
  "change_id",
  'local_bookmarks.map(|b| b.name()).join(",")',
  'remote_bookmarks.map(|b| b.name()).join(",")',
  "author.name()",
  "author.timestamp().ago()",
  "description.first_line()",
}, ' ++ "\\t" ++ ') .. ' ++ "\\n"'

--- Parse `COMMIT_TEMPLATE` output.
---@param out string?
---@return GHReviewJJCommit[]
local function parse_jj_commits(out)
  local commits = {}
  if not out then return commits end
  for line in out:gmatch("[^\n]+") do
    local id, change, locals, remotes, author, when, desc =
      line:match("^(%x*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if id and id ~= "" then
      local bookmarks, seen = {}, {}
      for _, list in ipairs({ locals, remotes }) do
        for name in list:gmatch("[^,]+") do
          name = vim.trim(name)
          if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(bookmarks, name)
          end
        end
      end
      table.insert(commits, {
        commit_id = id,
        change_id = vim.trim(change or ""),
        bookmarks = bookmarks,
        author = vim.trim(author or ""),
        when = vim.trim(when or ""),
        description = vim.trim(desc or ""),
      })
    end
  end
  return commits
end

--- Run a `jj` command asynchronously in the workspace containing `cwd`.
--- Like `jj_read`, the working copy is left unsnapshotted.
---@param args string[] Arguments after `jj`
---@param callback fun(err: string?, out: string?)
---@param cwd? string
local function jj_run_async(args, callback, cwd)
  local ctx = M.context(cwd)
  if not ctx.jj_root then
    callback("not inside a jj workspace")
    return
  end
  local cmd = vim.list_extend({ "jj", "--ignore-working-copy" }, args)
  vim.system(cmd, { text = true, cwd = ctx.jj_root }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local msg = vim.trim(result.stderr or "")
        callback(msg ~= "" and msg or ("jj exited with code " .. result.code))
        return
      end
      callback(nil, result.stdout)
    end)
  end)
end

--- Change id of `rev`, or nil when this workspace has never seen it.
--- Graph walks anchor on a change id rather than the commit id GitHub reports,
--- because the pushed commit id goes stale the moment the commit is rewritten
--- locally: a jj rebase keeps the change id but mints a new commit id, and the
--- rewritten-away commit has no descendants, so `children()` of it is empty even
--- though the stack continues. The change id still resolves to whichever commit
--- replaced it.
---@param rev string
---@param callback fun(err: string?, change_id: string?)
---@param cwd? string
function M.jj_change_id(rev, callback, cwd)
  M.jj_change_ids({ rev }, function(err, ids)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, (ids or {})[1])
  end, cwd)
end

--- Change ids of `revs`, in the order `jj` reports them. Revisions this
--- workspace has never seen are simply absent, so the result can be shorter than
--- the input; it carries no mapping back to the revisions asked for, because the
--- callers only test membership. Commits that were pushed and then rewritten
--- locally still resolve, to the change their replacement carries — which is the
--- point: it is the only identifier that survives a rebase or an amend.
---@param revs string[]
---@param callback fun(err: string?, change_ids: string[]?)
---@param cwd? string
function M.jj_change_ids(revs, callback, cwd)
  local terms = {}
  for _, rev in ipairs(revs) do
    if rev and rev ~= "" then
      table.insert(terms, ("present(%s)"):format(rev))
    end
  end
  if #terms == 0 then
    callback(nil, {})
    return
  end

  local args = { "log", "-r", table.concat(terms, " | "), "--no-graph", "-T", 'change_id ++ "\\n"' }
  jj_run_async(args, function(err, out)
    if err then
      callback(err, nil)
      return
    end
    local ids = {}
    for line in (out or ""):gmatch("[^\n]+") do
      local id = vim.trim(line)
      if id ~= "" then
        table.insert(ids, id)
      end
    end
    callback(nil, ids)
  end, cwd)
end

--- Commits immediately adjacent to `rev` in the jj graph: its children when
--- walking a stack upwards, its parents when walking down. Usually one of each,
--- but a stack can fork, so all of them are returned.
---@param rev string Revision to move from ("@", a commit id, a bookmark)
---@param direction "children"|"parents"
---@param callback fun(err: string?, commits: GHReviewJJCommit[]?)
---@param cwd? string
function M.jj_adjacent(rev, direction, callback, cwd)
  local revset = direction .. "(" .. rev .. ")"
  jj_run_async({ "log", "-r", revset, "--no-graph", "-T", COMMIT_TEMPLATE }, function(err, out)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, parse_jj_commits(out))
  end, cwd)
end

--- Upper bound on the commits `jj_stack` reports. The revset is only as narrow
--- as its anchor: anchored on trunk itself it would describe every open head in
--- the repository, which must not stall the picker.
M.STACK_LIMIT = 100

---@class GHReviewJJAnchor
---@field revs? string[] Commit ids to anchor on; ones the repo doesn't know are ignored
---@field bookmarks? string[] Bookmark names to anchor on, matched locally and on every remote

--- Quote a bookmark name for a revset string literal.
---@param name string
---@return string
local function revset_string(name)
  return '"' .. name:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Revset terms selecting each anchor and everything descending from it.
--- A commit id goes through `present()` so an oid the local repo has never seen
--- (an unfetched PR head) yields nothing instead of failing the whole query, and
--- bookmarks are matched with `bookmarks()`/`remote_bookmarks()` for the same
--- reason. Anchoring on the head bookmark as well as the head commit matters:
--- the oid GitHub reports is the commit as pushed, and once it has been
--- rewritten locally (a jj rebase keeps the change id but mints a new commit id)
--- the pushed commit no longer has any descendants, so a commit-only anchor
--- would show the stack below it and nothing above.
---@param anchor GHReviewJJAnchor|string
---@return string[]
local function anchor_terms(anchor)
  if type(anchor) == "string" then anchor = { revs = { anchor } } end
  local terms = {}
  for _, rev in ipairs(anchor.revs or {}) do
    if rev and rev ~= "" then
      table.insert(terms, ("present(%s)::"):format(rev))
    end
  end
  for _, name in ipairs(anchor.bookmarks or {}) do
    if name and name ~= "" then
      local quoted = revset_string(name)
      table.insert(terms, ("bookmarks(exact:%s)::"):format(quoted))
      table.insert(terms, ("remote_bookmarks(exact:%s)::"):format(quoted))
    end
  end
  return terms
end

--- The jj stack the anchor belongs to: every commit between trunk and the tip of
--- the branch(es) it sits on — those below it as well as its descendants — tip
--- first (the order `jj log` prints). `truncated` is true when `STACK_LIMIT` cut
--- the list short, in which case the commits nearest the tip are the ones kept.
---@param anchor GHReviewJJAnchor|string Commit ids and/or bookmarks locating the stack
---@param callback fun(err: string?, commits: GHReviewJJCommit[]?, truncated: boolean?)
---@param cwd? string
function M.jj_stack(anchor, callback, cwd)
  local terms = anchor_terms(anchor)
  if #terms == 0 then
    callback("no revision to locate the stack from", nil)
    return
  end
  -- `& ::visible_heads()` drops commits that have been rewritten locally: they
  -- are still resolvable by id but are no longer part of any branch, so listing
  -- them would show a stale duplicate of a commit already in the stack.
  local revset = ("(trunk()..heads(%s)) & ::visible_heads()"):format(table.concat(terms, " | "))
  local args = {
    "log", "-r", revset, "--no-graph", "-n", tostring(M.STACK_LIMIT), "-T", COMMIT_TEMPLATE,
  }
  jj_run_async(args, function(err, out)
    if err then
      callback(err, nil)
      return
    end
    local commits = parse_jj_commits(out)
    callback(nil, commits, #commits >= M.STACK_LIMIT)
  end, cwd)
end

--- Bookmarks nearest to `rev` looking downstream: the roots of the bookmarked
--- commits at or after it. In a stack of PRs each PR's head branch sits on the
--- top commit of its range, so this names the PR that contains `rev`.
---@param rev string
---@param callback fun(err: string?, bookmarks: string[]?)
---@param cwd? string
function M.jj_downstream_bookmarks(rev, callback, cwd)
  local revset = ("roots(%s:: & (bookmarks() | remote_bookmarks()))"):format(rev)
  jj_run_async({ "log", "-r", revset, "--no-graph", "-T", COMMIT_TEMPLATE }, function(err, out)
    if err then
      callback(err, nil)
      return
    end
    local names, seen = {}, {}
    for _, commit in ipairs(parse_jj_commits(out)) do
      for _, name in ipairs(commit.bookmarks) do
        if not seen[name] then
          seen[name] = true
          table.insert(names, name)
        end
      end
    end
    callback(nil, names)
  end, cwd)
end

--- Revision holding the current work, for diffing against the PR base.
--- "HEAD" everywhere git can answer; in a jj workspace HEAD belongs to another
--- workspace's checkout, so the working-copy commit is used instead.
---@param cwd? string
---@return string? rev nil when nothing can be resolved
function M.head_rev(cwd)
  local ctx = M.context(cwd)
  if ctx.kind ~= "jj" then
    return "HEAD"
  end
  return jj_read(ctx.jj_root, { "log", "-r", "@", "--no-graph", "-T", "commit_id" })
end

--- Fetch a PR branch and move the jj working copy on top of it. Used instead of
--- `gh pr checkout` when the cwd has no git worktree, where git cannot check
--- anything out. `jj new` leaves the PR head untouched and gives the reviewer
--- an empty change on top of it.
---@param branch string PR head branch name
---@param callback fun(err: string?)
---@param cwd? string
function M.jj_checkout(branch, callback, cwd)
  local ctx = M.context(cwd)
  if not ctx.jj_root then
    callback("not inside a jj workspace")
    return
  end
  local remote = ctx.remote or "origin"

  local function fail(result, what)
    local msg = result.stderr and vim.trim(result.stderr) or ""
    if msg == "" then msg = what .. " exited with code " .. result.code end
    vim.schedule(function() callback(msg) end)
  end

  vim.system({ "jj", "git", "fetch", "--remote", remote, "-b", branch }, {
    text = true,
    cwd = ctx.jj_root,
  }, function(fetch)
    if fetch.code ~= 0 then
      fail(fetch, "jj git fetch")
      return
    end
    vim.system({ "jj", "new", branch .. "@" .. remote }, {
      text = true,
      cwd = ctx.jj_root,
    }, function(new)
      if new.code ~= 0 then
        fail(new, "jj new")
        return
      end
      vim.schedule(function() callback(nil) end)
    end)
  end)
end

--- Human-readable summary of the detected layout, for :checkhealth.
---@param cwd? string
---@return string[]
function M.describe(cwd)
  local ctx = M.context(cwd)
  local lines = { "layout: " .. ctx.kind .. (ctx.jj_root and " (jj)" or "") }
  if ctx.root then table.insert(lines, "root: " .. ctx.root) end
  if ctx.git_dir then table.insert(lines, "backing git dir: " .. ctx.git_dir) end
  if ctx.gh_cwd then table.insert(lines, "gh runs in: " .. ctx.gh_cwd) end
  if ctx.gh_env and ctx.gh_env.GH_REPO then
    table.insert(lines, "GH_REPO: " .. ctx.gh_env.GH_REPO)
  end
  return lines
end

return M
