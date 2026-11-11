---@module 'luassert'

local vcs = require("gh-review.vcs")

--- Create a directory tree under a fresh temp dir.
--- `files` maps relative paths to contents; directories are created as needed.
--- A path ending in "/" creates an empty directory.
---@param files table<string, string>
---@return string root
local function fixture(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  for path, content in pairs(files) do
    local full = root .. "/" .. path
    if path:sub(-1) == "/" then
      vim.fn.mkdir(full, "p")
    else
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      local fd = assert(io.open(full, "w"))
      fd:write(content)
      fd:close()
    end
  end
  return root
end

--- Stub vim.system, capturing commands and replying with `responses` in order.
---@param responses table[]
---@param capture table[]
---@return function restore
local function stub_system(responses, capture)
  local orig = vim.system
  local idx = 0
  vim.system = function(cmd, opts, callback)
    idx = idx + 1
    table.insert(capture, { cmd = cmd, opts = opts })
    local resp = responses[idx] or responses[#responses]
    if callback then
      callback(resp)
      return nil
    end
    return { wait = function() return resp end }
  end
  return orig
end

local GIT_CONFIG = table.concat({
  "[core]",
  "\trepositoryformatversion = 0",
  '[remote "origin"]',
  "\turl = https://github.com/theochap/gh-review.nvim.git",
  "\tfetch = +refs/heads/*:refs/remotes/origin/*",
  "",
}, "\n")

describe("vcs", function()
  local orig_system

  before_each(function()
    vcs.invalidate()
  end)

  after_each(function()
    if orig_system then
      vim.system = orig_system
      orig_system = nil
    end
    vcs.invalidate()
  end)

  describe("context", function()
    it("detects a plain git worktree", function()
      local root = fixture({
        [".git/HEAD"] = "ref: refs/heads/main\n",
        [".git/config"] = GIT_CONFIG,
        ["lua/init.lua"] = "",
      })
      local ctx = vcs.context(root)
      assert.are.equal("git", ctx.kind)
      assert.are.equal(root, ctx.root)
      assert.is_nil(ctx.jj_root)
      -- git and gh both work from the cwd: nothing to redirect
      assert.is_nil(ctx.git_dir)
      assert.is_nil(ctx.gh_cwd)
      assert.is_nil(ctx.gh_env)
    end)

    it("walks up from a subdirectory", function()
      local root = fixture({
        [".git/HEAD"] = "ref: refs/heads/main\n",
        ["lua/gh-review/"] = "",
      })
      assert.are.equal(root, vcs.context(root .. "/lua/gh-review").root)
    end)

    it("treats a colocated jj repo as git, but records the jj root", function()
      local root = fixture({
        [".git/HEAD"] = "ref: refs/heads/main\n",
        [".jj/repo/store/git_target"] = "../../../.git",
      })
      local ctx = vcs.context(root)
      assert.are.equal("git", ctx.kind)
      assert.are.equal(root, ctx.jj_root)
      assert.is_nil(ctx.git_dir)
    end)

    it("resolves a secondary jj workspace to the main repo's git dir", function()
      local root = fixture({
        ["main/.git/HEAD"] = "ref: refs/heads/main\n",
        ["main/.git/config"] = GIT_CONFIG,
        ["main/.jj/repo/store/git_target"] = "../../../.git",
        -- A secondary workspace has no .git; .jj/repo points at the main repo
        ["ws/.jj/repo"] = "../../main/.jj/repo",
        ["ws/.jj/working_copy/"] = "",
      })
      local ctx = vcs.context(root .. "/ws")
      assert.are.equal("jj", ctx.kind)
      assert.are.equal(root .. "/ws", ctx.root)
      assert.are.equal(root .. "/ws", ctx.jj_root)
      assert.are.equal(root .. "/main/.git", ctx.git_dir)
      -- The main workspace is colocated, so gh can run there normally
      assert.are.equal(root .. "/main", ctx.gh_cwd)
      assert.is_nil(ctx.gh_env)
      assert.are.equal("origin", ctx.remote)
    end)

    it("treats a jj workspace that is a git worktree as git, with the shared remote", function()
      local root = fixture({
        ["main/.git/HEAD"] = "ref: refs/heads/main\n",
        ["main/.git/config"] = GIT_CONFIG:gsub('"origin"', '"upstream"'),
        ["main/.git/worktrees/ws/HEAD"] = string.rep("a", 40) .. "\n",
        ["main/.git/worktrees/ws/commondir"] = "../..\n",
        ["main/.jj/repo/store/git_target"] = "../../../.git",
        -- jj >= 0.34: the secondary workspace is a git worktree too
        ["ws/.git"] = "gitdir: ../main/.git/worktrees/ws\n",
        ["ws/.jj/repo"] = "../../main/.jj/repo",
      })
      local ctx = vcs.context(root .. "/ws")
      assert.are.equal("git", ctx.kind)
      assert.are.equal(root .. "/ws", ctx.jj_root)
      assert.are.equal(root .. "/main/.git/worktrees/ws", ctx.dot_git)
      assert.is_nil(ctx.git_dir)
      assert.is_nil(ctx.gh_env)
      assert.are.equal("upstream", ctx.remote)
    end)

    it("identifies the repo via GH_REPO when the git store is bare", function()
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/HEAD"] = "ref: refs/heads/main\n",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
      local ctx = vcs.context(root)
      assert.are.equal("jj", ctx.kind)
      assert.are.equal(root .. "/.jj/repo/store/git", ctx.git_dir)
      assert.is_nil(ctx.gh_cwd)
      assert.are.same({ GH_REPO = "theochap/gh-review.nvim" }, ctx.gh_env)
    end)

    it("reports 'none' outside any repository", function()
      local root = fixture({ ["file.txt"] = "" })
      assert.are.equal("none", vcs.context(root).kind)
    end)

    it("caches per directory until invalidated", function()
      local root = fixture({ ["file.txt"] = "" })
      assert.are.equal("none", vcs.context(root).kind)

      vim.fn.mkdir(root .. "/.git", "p")
      assert.are.equal("none", vcs.context(root).kind, "cached result should be reused")

      vcs.invalidate()
      assert.are.equal("git", vcs.context(root).kind)
    end)
  end)

  describe("gh_context url parsing", function()
    --- Build a bare-store jj fixture whose remote uses `url`.
    local function ctx_for(url)
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = '[remote "origin"]\n\turl = ' .. url .. "\n",
      })
      return vcs.context(root)
    end

    it("parses https urls", function()
      assert.are.same({ GH_REPO = "owner/repo" }, ctx_for("https://github.com/owner/repo.git").gh_env)
    end)

    it("parses scp-style ssh urls", function()
      assert.are.same({ GH_REPO = "owner/repo" }, ctx_for("git@github.com:owner/repo.git").gh_env)
    end)

    it("parses ssh:// urls", function()
      assert.are.same({ GH_REPO = "owner/repo" }, ctx_for("ssh://git@github.com/owner/repo").gh_env)
    end)

    it("keeps the host for enterprise remotes", function()
      assert.are.same(
        { GH_REPO = "git.corp.example/owner/repo" },
        ctx_for("https://git.corp.example/owner/repo.git").gh_env
      )
    end)

    it("prefers origin over other remotes", function()
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = table.concat({
          '[remote "upstream"]',
          "\turl = https://github.com/upstream/repo.git",
          '[remote "origin"]',
          "\turl = https://github.com/mine/repo.git",
          "",
        }, "\n"),
      })
      assert.are.same({ GH_REPO = "mine/repo" }, vcs.context(root).gh_env)
    end)

    it("falls back to the only remote when there is no origin", function()
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = '[remote "fork"]\n\turl = git@github.com:me/repo.git\n',
      })
      local ctx = vcs.context(root)
      assert.are.equal("fork", ctx.remote)
      assert.are.same({ GH_REPO = "me/repo" }, ctx.gh_env)
    end)
  end)

  describe("git_cmd", function()
    it("leaves commands untouched inside a git worktree", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/main\n" })
      assert.are.same({ "git", "show", "HEAD:f" }, vcs.git_cmd({ "show", "HEAD:f" }, root))
    end)

    it("points git at the backing repo from a jj workspace", function()
      local root = fixture({
        ["main/.git/HEAD"] = "ref: refs/heads/main\n",
        ["main/.jj/repo/store/git_target"] = "../../../.git",
        ["ws/.jj/repo"] = "../../main/.jj/repo",
      })
      assert.are.same(
        { "git", "--git-dir", root .. "/main/.git", "merge-base", "origin/main", "abc" },
        vcs.git_cmd({ "merge-base", "origin/main", "abc" }, root .. "/ws")
      )
    end)
  end)

  describe("pr_branch_candidates", function()
    it("returns nothing when git HEAD is on a branch", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/feature/x\n" })
      assert.are.same({}, vcs.pr_branch_candidates(root))
    end)

    it("returns nothing for a detached HEAD outside jj", function()
      local root = fixture({ [".git/HEAD"] = "1234567890abcdef1234567890abcdef12345678\n" })
      assert.are.same({}, vcs.pr_branch_candidates(root))
    end)

    it("returns jj bookmarks when HEAD is detached in a colocated repo", function()
      local root = fixture({
        [".git/HEAD"] = "1234567890abcdef1234567890abcdef12345678\n",
        [".jj/repo/store/git_target"] = "../../../.git",
      })
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "feat/thing\n\nfeat/thing\n", stderr = "" },
      }, captured)

      local candidates = vcs.pr_branch_candidates(root)

      assert.are.same({ "feat/thing" }, candidates, "duplicate local/remote names collapse")
      assert.are.equal("jj", captured[1].cmd[1])
      -- Reads must not snapshot the working copy
      assert.are.equal("--ignore-working-copy", captured[1].cmd[2])
      assert.are.equal(root, captured[1].opts.cwd)
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "heads(::@ & (bookmarks() | remote_bookmarks()))"))
    end)

    it("orders local bookmarks before remote-only ones", function()
      local root = fixture({ [".jj/repo/store/git_target"] = "git" })
      orig_system = stub_system({ { code = 0, stdout = "local-b\nremote-b\n", stderr = "" } }, {})
      assert.are.same({ "local-b", "remote-b" }, vcs.pr_branch_candidates(root))
    end)

    it("returns nothing when jj fails", function()
      local root = fixture({ [".jj/repo/store/git_target"] = "git" })
      orig_system = stub_system({ { code = 1, stdout = "", stderr = "no jj" } }, {})
      assert.are.same({}, vcs.pr_branch_candidates(root))
    end)
  end)

  describe("pr_branch_candidates_async", function()
    --- @return string[]
    local function collect(root)
      local result, done = nil, false
      vcs.pr_branch_candidates_async(function(candidates)
        result = candidates
        done = true
      end, root)
      vim.wait(200, function() return done end)
      assert.is_true(done)
      return result
    end

    it("answers immediately without spawning jj when HEAD is on a branch", function()
      local root = fixture({
        [".git/HEAD"] = "ref: refs/heads/main\n",
        [".jj/repo/store/git_target"] = "../../../.git",
      })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)

      assert.are.same({}, collect(root))
      assert.are.equal(0, #captured, "jj should not run when git can answer")
    end)

    it("returns bookmarks when HEAD is detached", function()
      local root = fixture({
        [".git/HEAD"] = "1234567890abcdef1234567890abcdef12345678\n",
        [".jj/repo/store/git_target"] = "../../../.git",
      })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "feat/a\nfeat/b\n", stderr = "" } }, captured)

      assert.are.same({ "feat/a", "feat/b" }, collect(root))
      assert.are.equal(root, captured[1].opts.cwd)
    end)

    it("returns nothing when jj fails", function()
      local root = fixture({ [".jj/repo/store/git_target"] = "git" })
      orig_system = stub_system({ { code = 1, stdout = "", stderr = "boom" } }, {})
      assert.are.same({}, collect(root))
    end)
  end)

  describe("head_rev", function()
    it("is HEAD inside a git worktree", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/main\n" })
      assert.are.equal("HEAD", vcs.head_rev(root))
    end)

    it("is HEAD in a colocated jj repo", function()
      local root = fixture({
        [".git/HEAD"] = "1234567890abcdef1234567890abcdef12345678\n",
        [".jj/repo/store/git_target"] = "../../../.git",
      })
      assert.are.equal("HEAD", vcs.head_rev(root))
    end)

    it("is the working-copy commit in a jj workspace", function()
      local root = fixture({
        ["main/.git/HEAD"] = "ref: refs/heads/main\n",
        ["main/.jj/repo/store/git_target"] = "../../../.git",
        ["ws/.jj/repo"] = "../../main/.jj/repo",
      })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "deadbeef\n", stderr = "" } }, captured)

      assert.are.equal("deadbeef", vcs.head_rev(root .. "/ws"))
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "commit_id"))
    end)

    it("is nil when jj cannot resolve the working copy", function()
      local root = fixture({ ["ws/.jj/repo/store/git_target"] = "git" })
      orig_system = stub_system({ { code = 1, stdout = "", stderr = "boom" } }, {})
      assert.is_nil(vcs.head_rev(root .. "/ws"))
    end)
  end)

  describe("jj_checkout", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    it("fetches the branch then moves the working copy on top of it", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "", stderr = "" }, -- jj git fetch
        { code = 0, stdout = "", stderr = "" }, -- jj new
      }, captured)

      local done, err = false, "unset"
      vcs.jj_checkout("feat/x", function(e)
        err = e
        done = true
      end, root)
      vim.wait(200, function() return done end)

      assert.is_true(done)
      assert.is_nil(err)
      assert.are.same({ "jj", "git", "fetch", "--remote", "origin", "-b", "feat/x" }, captured[1].cmd)
      assert.are.equal(root, captured[1].opts.cwd)
      assert.are.same({ "jj", "new", "feat/x@origin" }, captured[2].cmd)
    end)

    it("fetches every given branch, then goes on top of the target", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)

      local done = false
      vcs.jj_checkout("b3", function() done = true end, root, { "b1", "b2", "b3" })
      vim.wait(200, function() return done end)

      assert.are.same(
        { "jj", "git", "fetch", "--remote", "origin", "-b", "b1", "-b", "b2", "-b", "b3" },
        captured[1].cmd
      )
      assert.are.same({ "jj", "new", "b3@origin" }, captured[2].cmd)
    end)

    it("skips the fetch and goes on the head when jj already has it", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "abc123", stderr = "" }, -- jj log present(abc123)
        { code = 0, stdout = "", stderr = "" }, -- jj new
      }, captured)
      local fetched = false
      local done, err = false, "unset"
      vcs.jj_checkout("feat/x", function(e) err = e; done = true end, root, nil, {
        head_oid = "abc123",
        on_fetch = function() fetched = true end,
      })
      vim.wait(200, function() return done end)
      assert.is_nil(err)
      assert.is_false(fetched)
      assert.are.same({ "jj", "--ignore-working-copy", "log", "-r", "present(abc123)", "--no-graph", "-T", "commit_id" }, captured[1].cmd)
      assert.are.same({ "jj", "new", "abc123" }, captured[2].cmd)
    end)

    it("fetches when jj does not have the head, announcing it", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "", stderr = "" }, -- present() is empty
        { code = 0, stdout = "", stderr = "" }, -- jj git fetch
        { code = 0, stdout = "", stderr = "" }, -- jj new
      }, captured)
      local fetched = false
      local done = false
      vcs.jj_checkout("feat/x", function() done = true end, root, nil, {
        head_oid = "abc123",
        on_fetch = function() fetched = true end,
      })
      vim.wait(200, function() return done end)
      assert.is_true(fetched)
      assert.are.same({ "jj", "git", "fetch", "--remote", "origin", "-b", "feat/x" }, captured[2].cmd)
      assert.are.same({ "jj", "new", "feat/x@origin" }, captured[3].cmd)
    end)

    it("does not pass a non-hex head to jj", function()
      local root = ws_fixture()
      local got
      vcs.jj_has_commit("main; rm", function(h) got = h end, root)
      assert.is_false(got)
    end)

    it("uses the repo's remote name when it is not origin", function()
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = '[remote "fork"]\n\turl = git@github.com:me/repo.git\n',
      })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)

      local done = false
      vcs.jj_checkout("feat/x", function() done = true end, root)
      vim.wait(200, function() return done end)

      assert.are.equal("fork", captured[1].cmd[5])
      assert.are.same({ "jj", "new", "feat/x@fork" }, captured[2].cmd)
    end)

    it("surfaces fetch failures without running jj new", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({ { code = 1, stdout = "", stderr = "no such remote\n" } }, captured)

      local done, err = false, nil
      vcs.jj_checkout("feat/x", function(e)
        err = e
        done = true
      end, root)
      vim.wait(200, function() return done end)

      assert.is_true(done)
      assert.are.equal("no such remote", err)
      assert.are.equal(1, #captured)
    end)

    it("surfaces jj new failures", function()
      local root = ws_fixture()
      orig_system = stub_system({
        { code = 0, stdout = "", stderr = "" },
        { code = 1, stdout = "", stderr = "revision not found\n" },
      }, {})

      local done, err = false, nil
      vcs.jj_checkout("feat/x", function(e)
        err = e
        done = true
      end, root)
      vim.wait(200, function() return done end)

      assert.is_true(done)
      assert.are.equal("revision not found", err)
    end)

    it("errors outside a jj workspace", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/main\n" })
      local err
      vcs.jj_checkout("feat/x", function(e) err = e end, root)
      assert.is_truthy(err and err:find("jj"))
    end)
  end)

  describe("jj_adjacent", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    --- Run jj_adjacent against stubbed output and return err, commits.
    local function collect(root, direction, response, capture)
      orig_system = stub_system({ response }, capture or {})
      local done, result, error_msg = false, nil, nil
      vcs.jj_adjacent("abc123", direction, function(e, commits)
        error_msg, result, done = e, commits, true
      end, root)
      vim.wait(200, function() return done end)
      assert.is_true(done)
      return error_msg, result
    end

    it("parses commit ids, bookmarks and descriptions of the children", function()
      local root = ws_fixture()
      local captured = {}
      local stdout = table.concat({
        "aaaa1111\tkkllmmnn\tfeat/two\tfeat/two\tAda\t2 hours ago\tsecond change",
        "bbbb2222\t\t\t\t\t\t",
        "",
      }, "\n")
      local err, commits = collect(root, "children", { code = 0, stdout = stdout, stderr = "" }, captured)

      assert.is_nil(err)
      assert.are.equal(2, #commits)
      assert.are.equal("aaaa1111", commits[1].commit_id)
      assert.are.equal("kkllmmnn", commits[1].change_id)
      assert.are.same({ "feat/two" }, commits[1].bookmarks)
      assert.are.equal("second change", commits[1].description)
      assert.are.equal("Ada", commits[1].author)
      assert.are.equal("2 hours ago", commits[1].when)
      -- A commit with no bookmark and no description still comes through
      assert.are.equal("bbbb2222", commits[2].commit_id)
      assert.are.same({}, commits[2].bookmarks)
      assert.are.equal("", commits[2].description)
      assert.are.equal("", commits[2].author)

      assert.are.equal("jj", captured[1].cmd[1])
      -- Empty working copies (what `jj new` leaves on a commit) are not stack commits.
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "children(abc123) ~ (working_copies() & empty())"))
      assert.are.equal(root, captured[1].opts.cwd)
    end)

    it("asks jj for parents when walking down the stack", function()
      local root = ws_fixture()
      local captured = {}
      collect(root, "parents", { code = 0, stdout = "cccc3333\tppqqrrss\t\t\tAda\tnow\tbase\n", stderr = "" }, captured)
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "parents(abc123) ~ (working_copies() & empty())"))
    end)

    it("does not count the empty working copy on a commit as its child (real jj)", function()
      if vim.fn.executable("jj") == 0 then return pending("jj is not installed") end
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local function jj(args)
        local r = vim.system(vim.list_extend({ "jj", "--config", "user.name=T", "--config", "user.email=t@t" }, args),
          { text = true, cwd = dir }):wait()
        assert(r.code == 0, table.concat(args, " ") .. ": " .. (r.stderr or ""))
        return vim.trim(r.stdout or "")
      end
      jj({ "git", "init", "--colocate" })
      for _, name in ipairs({ "one", "two" }) do
        local fd = assert(io.open(dir .. "/" .. name, "w"))
        fd:write(name)
        fd:close()
        jj({ "commit", "-m", name })
      end
      local one = jj({ "log", "-r", "@--", "--no-graph", "-T", "commit_id" })
      -- What a stack step does: an empty working copy on top of the commit.
      jj({ "new", one })
      orig_system = vim.system -- restored by after_each; nothing is stubbed here
      local done, commits
      vcs.jj_adjacent(one, "children", function(_, c) commits, done = c, true end, dir)
      vim.wait(5000, function() return done end)
      vim.fn.delete(dir, "rf")
      assert.are.same({ "two" }, vim.tbl_map(function(c) return c.description end, commits))
    end)

    it("returns an empty list at the tip of the stack", function()
      local root = ws_fixture()
      local err, commits = collect(root, "children", { code = 0, stdout = "", stderr = "" })
      assert.is_nil(err)
      assert.are.same({}, commits)
    end)

    it("surfaces jj failures", function()
      local root = ws_fixture()
      local err, commits = collect(root, "children", { code = 1, stdout = "", stderr = "bad revset\n" })
      assert.are.equal("bad revset", err)
      assert.is_nil(commits)
    end)

    it("errors outside a jj workspace without spawning jj", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/main\n" })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)
      local err
      vcs.jj_adjacent("abc123", "children", function(e) err = e end, root)
      assert.is_truthy(err and err:find("jj"))
      assert.are.equal(0, #captured)
    end)
  end)

  describe("jj_stack", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    --- Run jj_stack against stubbed output; returns err, commits, truncated.
    local function collect(root, response, capture, anchor)
      orig_system = stub_system({ response }, capture or {})
      local done, err, commits, truncated = false, nil, nil, nil
      vcs.jj_stack(anchor or "abc123", function(e, list, cut)
        err, commits, truncated, done = e, list, cut, true
      end, root)
      vim.wait(200, function() return done end)
      assert.is_true(done)
      return err, commits, truncated
    end

    --- The `-r` argument of the captured jj invocation.
    local function revset_of(captured)
      for i, arg in ipairs(captured[1].cmd) do
        if arg == "-r" then return captured[1].cmd[i + 1] end
      end
      return nil
    end

    it("lists the commits between trunk and the tip, tip first", function()
      local root = ws_fixture()
      local captured = {}
      local stdout = table.concat({
        "aaaa1111\tkkllmmnn\t\t\tAda\tnow\tthird change",
        "bbbb2222\toopprrss\tpr-two\tpr-two\tAda\t1 minute ago\tsecond change",
        "cccc3333\tttuuvvww\tpr-one\tpr-one\tGrace\t2 hours ago\tfirst change",
        "",
      }, "\n")
      local err, commits, truncated = collect(root, { code = 0, stdout = stdout, stderr = "" }, captured)

      assert.is_nil(err)
      assert.are.equal(3, #commits)
      assert.are.equal("aaaa1111", commits[1].commit_id)
      assert.are.equal("kkllmmnn", commits[1].change_id)
      assert.are.equal("third change", commits[1].description)
      assert.are.same({}, commits[1].bookmarks)
      assert.are.same({ "pr-two" }, commits[2].bookmarks)
      assert.are.equal("Grace", commits[3].author)
      assert.are.equal("2 hours ago", commits[3].when)
      assert.is_false(truncated)

      assert.are.equal("jj", captured[1].cmd[1])
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "--ignore-working-copy"))
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, tostring(vcs.STACK_LIMIT)))
      assert.are.equal(root, captured[1].opts.cwd)

      local revset = revset_of(captured)
      -- Descendants of the anchor as well as its ancestors, and the anchor is
      -- wrapped so an oid this repo has never seen yields nothing rather than
      -- failing the query. Rewritten-away commits are filtered out.
      assert.is_truthy(revset:find("present(abc123)::", 1, true))
      assert.is_truthy(revset:find("trunk()..heads(", 1, true))
      assert.is_truthy(revset:find("::visible_heads()", 1, true))
    end)

    it("anchors on bookmarks as well as commit ids", function()
      local root = ws_fixture()
      local captured = {}
      collect(root, { code = 0, stdout = "", stderr = "" }, captured, {
        revs = { "abc123", "def456" },
        bookmarks = { "feat/one" },
      })

      local revset = revset_of(captured)
      assert.is_truthy(revset:find("present(abc123)::", 1, true))
      assert.is_truthy(revset:find("present(def456)::", 1, true))
      -- Both the local bookmark and the same name on any remote
      assert.is_truthy(revset:find('bookmarks(exact:"feat/one")::', 1, true))
      assert.is_truthy(revset:find('remote_bookmarks(exact:"feat/one")::', 1, true))
    end)

    it("errors without spawning jj when there is nothing to anchor on", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)
      local err
      vcs.jj_stack({ revs = {}, bookmarks = {} }, function(e) err = e end, root)
      assert.is_truthy(err and err:find("locate the stack"))
      assert.are.equal(0, #captured)
    end)

    it("flags a stack cut short by the limit", function()
      local root = ws_fixture()
      local lines = {}
      for i = 1, vcs.STACK_LIMIT do
        table.insert(lines, ("%08d\tchange%04d\t\t\tAda\tnow\tchange %d"):format(i, i, i))
      end
      table.insert(lines, "")
      local _, commits, truncated = collect(root, { code = 0, stdout = table.concat(lines, "\n"), stderr = "" })
      assert.are.equal(vcs.STACK_LIMIT, #commits)
      assert.is_true(truncated)
    end)

    it("returns an empty list when the revision is trunk itself", function()
      local root = ws_fixture()
      local err, commits, truncated = collect(root, { code = 0, stdout = "", stderr = "" })
      assert.is_nil(err)
      assert.are.same({}, commits)
      assert.is_false(truncated)
    end)

    it("surfaces jj failures", function()
      local root = ws_fixture()
      local err, commits = collect(root, { code = 1, stdout = "", stderr = "Error: Revision doesn't exist\n" })
      assert.are.equal("Error: Revision doesn't exist", err)
      assert.is_nil(commits)
    end)

    it("errors outside a jj workspace without spawning jj", function()
      local root = fixture({ [".git/HEAD"] = "ref: refs/heads/main\n" })
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)
      local err
      vcs.jj_stack("abc123", function(e) err = e end, root)
      assert.is_truthy(err and err:find("jj"))
      assert.are.equal(0, #captured)
    end)
  end)

  describe("jj_change_id", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    local function collect(root, response, capture)
      orig_system = stub_system({ response }, capture or {})
      local done, err, id = false, nil, nil
      vcs.jj_change_id("abc123", function(e, change_id)
        err, id, done = e, change_id, true
      end, root)
      vim.wait(200, function() return done end)
      assert.is_true(done)
      return err, id
    end

    it("returns the change id of the revision", function()
      local root = ws_fixture()
      local captured = {}
      local err, id = collect(root, { code = 0, stdout = "vtwxtppqqmtknklz\n", stderr = "" }, captured)
      assert.is_nil(err)
      assert.are.equal("vtwxtppqqmtknklz", id)
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "present(abc123)"))
    end)

    it("returns nothing for a revision this workspace has never seen", function()
      local root = ws_fixture()
      local err, id = collect(root, { code = 0, stdout = "", stderr = "" })
      assert.is_nil(err)
      assert.is_nil(id)
    end)

    it("surfaces jj failures", function()
      local root = ws_fixture()
      local err, id = collect(root, { code = 1, stdout = "", stderr = "boom\n" })
      assert.are.equal("boom", err)
      assert.is_nil(id)
    end)
  end)

  describe("jj_change_ids", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    local function collect(root, revs, response, capture)
      orig_system = stub_system({ response }, capture or {})
      local done, err, ids = false, nil, nil
      vcs.jj_change_ids(revs, function(e, result)
        err, ids, done = e, result, true
      end, root)
      vim.wait(200, function() return done end)
      assert.is_true(done)
      return err, ids
    end

    it("resolves several revisions in one query", function()
      local root = ws_fixture()
      local captured = {}
      local err, ids = collect(
        root,
        { "aaaa1111", "bbbb2222" },
        { code = 0, stdout = "vtwxtppqqmtknklz\nrnssqtuslxwovplm\n", stderr = "" },
        captured
      )

      assert.is_nil(err)
      assert.are.same({ "vtwxtppqqmtknklz", "rnssqtuslxwovplm" }, ids)
      -- One `present()` term per revision, so unknown ones drop out silently
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "present(aaaa1111) | present(bbbb2222)"))
    end)

    it("does not spawn jj when there is nothing to resolve", function()
      local root = ws_fixture()
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, captured)
      local err, ids
      vcs.jj_change_ids({ "" }, function(e, result) err, ids = e, result end, root)
      assert.is_nil(err)
      assert.are.same({}, ids)
      assert.are.equal(0, #captured)
    end)

    it("returns fewer ids than revisions when the workspace has not seen them", function()
      local root = ws_fixture()
      local err, ids = collect(root, { "aaaa1111", "bbbb2222" }, { code = 0, stdout = "vtwxtppqqmtknklz\n", stderr = "" })
      assert.is_nil(err)
      assert.are.same({ "vtwxtppqqmtknklz" }, ids)
    end)

    it("surfaces jj failures", function()
      local root = ws_fixture()
      local err, ids = collect(root, { "aaaa1111" }, { code = 1, stdout = "", stderr = "boom\n" })
      assert.are.equal("boom", err)
      assert.is_nil(ids)
    end)
  end)

  describe("jj_downstream_bookmarks", function()
    local function ws_fixture()
      return fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
    end

    it("collects bookmark names from the nearest bookmarked descendants", function()
      local root = ws_fixture()
      local captured = {}
      -- Local and remote bookmarks of the same name must not be duplicated
      local stdout = "aaaa1111\tkkllmmnn\tfeat/two\tfeat/two,feat/two-old\tAda\tnow\ttop of PR 2\n"
      orig_system = stub_system({ { code = 0, stdout = stdout, stderr = "" } }, captured)

      local done, names = false, nil
      vcs.jj_downstream_bookmarks("abc123", function(_, result)
        names, done = result, true
      end, root)
      vim.wait(200, function() return done end)

      assert.are.same({ "feat/two", "feat/two-old" }, names)
      assert.is_truthy(vim.tbl_contains(captured[1].cmd, "roots(abc123:: & (bookmarks() | remote_bookmarks()))"))
    end)

    it("returns nothing when no descendant is bookmarked", function()
      local root = ws_fixture()
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, {})
      local done, names = false, nil
      vcs.jj_downstream_bookmarks("abc123", function(_, result)
        names, done = result, true
      end, root)
      vim.wait(200, function() return done end)
      assert.are.same({}, names)
    end)

    it("surfaces jj failures", function()
      local root = ws_fixture()
      orig_system = stub_system({ { code = 1, stdout = "", stderr = "boom\n" } }, {})
      local done, err = false, nil
      vcs.jj_downstream_bookmarks("abc123", function(e)
        err, done = e, true
      end, root)
      vim.wait(200, function() return done end)
      assert.are.equal("boom", err)
    end)
  end)

  describe("describe", function()
    it("summarizes a jj workspace layout", function()
      local root = fixture({
        [".jj/repo/store/git_target"] = "git",
        [".jj/repo/store/git/config"] = GIT_CONFIG,
      })
      local lines = table.concat(vcs.describe(root), "\n")
      assert.is_truthy(lines:find("jj", 1, true))
      assert.is_truthy(lines:find("backing git dir", 1, true))
      assert.is_truthy(lines:find("GH_REPO: theochap/gh%-review.nvim"))
    end)
  end)

  describe("base_commit", function()
    it("returns HEAD's commit id in a git repo and nil outside one", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local function git(args)
        return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
      end
      git({ "init", "-q" })
      git({ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "c" })
      local head = vim.trim(git({ "rev-parse", "HEAD" }).stdout)
      vcs.invalidate()
      assert.are.equal(head, vcs.base_commit(dir))
      vim.fn.delete(dir, "rf")

      local empty = vim.fn.tempname()
      vim.fn.mkdir(empty, "p")
      vcs.invalidate()
      assert.is_nil(vcs.base_commit(empty))
      vim.fn.delete(empty, "rf")
    end)
  end)
  describe("local PR revsets", function()
    it("takes the head bookmark, unpushed work above it, else the pushed head", function()
      local tip = 'coalesce(bookmarks(exact:"feat"), present(abc123))'
      local above = "(" .. tip .. "::@ ~ " .. tip .. ")"
      local marked = "(" .. above .. " & (bookmarks() | remote_bookmarks()))"
      local unpushed = "(" .. above .. " ~ ::" .. marked .. " ~ " .. marked .. "::)"
      assert.are.equal(
        "coalesce(heads((" .. tip .. " | " .. unpushed .. ") ~ empty()), " .. tip .. ")",
        vcs.local_pr_head_revset({ head_ref = "feat", head_oid = "abc123" })
      )
    end)

    it("quotes branch names and drops a non-hex oid", function()
      local revset = vcs.local_pr_head_revset({ head_ref = 'a"b', head_oid = "main; rm" })
      assert.is_truthy(revset:find('bookmarks(exact:"a\\"b")', 1, true))
      assert.is_nil(revset:find("rm", 1, true))
      assert.is_nil(vcs.local_pr_head_revset({}))
    end)

    it("takes the base branch, local and remote, and the pushed base", function()
      assert.are.equal(
        'bookmarks(exact:"main") | remote_bookmarks(exact:"main") | present(def456)',
        vcs.local_pr_base_revset({ base_ref = "main", base_oid = "def456" })
      )
      assert.is_nil(vcs.local_pr_base_revset({}))
    end)
  end)

  describe("jj_move_to", function()
    local function ws()
      return fixture({ [".jj/repo/store/git_target"] = "git" })
    end

    it("does nothing when the working copy is already on the commit", function()
      local captured = {}
      orig_system = stub_system({ { code = 0, stdout = "abc\n", stderr = "" } }, captured)
      local result
      vcs.jj_move_to("abc", function(err, moved) result = { err = err, moved = moved } end, ws())
      vim.wait(200, function() return result ~= nil end)
      assert.are.same({ moved = false }, result)
      assert.are.equal(1, #captured)
      assert.are.equal("--ignore-working-copy", captured[1].cmd[2])
      assert.are.equal("present(abc) & (@ | parents(@ & empty()))", captured[1].cmd[5])
    end)

    it("runs jj new on the commit otherwise", function()
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "", stderr = "" }, -- not there yet
        { code = 0, stdout = "", stderr = "" }, -- jj new
      }, captured)
      local result
      vcs.jj_move_to("abc", function(err, moved) result = { err = err, moved = moved } end, ws())
      vim.wait(200, function() return result ~= nil end)
      assert.are.same({ moved = true }, result)
      assert.are.same({ "jj", "new", "abc" }, captured[2].cmd)
    end)

    it("surfaces jj new failures", function()
      orig_system = stub_system({
        { code = 0, stdout = "", stderr = "" },
        { code = 1, stdout = "", stderr = "conflict\n" },
      }, {})
      local result
      vcs.jj_move_to("abc", function(err, moved) result = { err = err, moved = moved } end, ws())
      vim.wait(200, function() return result ~= nil end)
      assert.are.same({ err = "conflict", moved = false }, result)
    end)
  end)

  describe("jj_local_pr", function()
    local spec = { head_ref = "feat", head_oid = "abc", base_ref = "main", base_oid = "def" }

    it("snapshots, resolves the tip, then the merge base with the base", function()
      local root = fixture({ [".jj/repo/store/git_target"] = "git" })
      local captured = {}
      orig_system = stub_system({
        { code = 0, stdout = "1111\n", stderr = "" },
        { code = 0, stdout = "2222\n", stderr = "" },
      }, captured)
      local result
      vcs.jj_local_pr(spec, function(err, range) result = { err = err, range = range } end, root)
      vim.wait(200, function() return result ~= nil end)
      assert.are.same({ range = { head = "1111", base = "2222" } }, result)
      -- The first query records the edits on disk: no --ignore-working-copy.
      assert.are.equal("log", captured[1].cmd[2])
      assert.are.equal("--ignore-working-copy", captured[2].cmd[2])
      assert.are.equal(
        'heads(::1111 & ::(bookmarks(exact:"main") | remote_bookmarks(exact:"main") | present(def)))',
        captured[2].cmd[5]
      )
    end)

    it("errors when the PR head is not in the repository", function()
      local root = fixture({ [".jj/repo/store/git_target"] = "git" })
      orig_system = stub_system({ { code = 0, stdout = "", stderr = "" } }, {})
      local result
      vcs.jj_local_pr(spec, function(err) result = err end, root)
      vim.wait(200, function() return result ~= nil end)
      assert.is_truthy(result:find("not in this jj repository"))
    end)

    it("errors without branches or oids, without spawning jj", function()
      local spawned = false
      orig_system = vim.system
      vim.system = function() spawned = true end
      local result
      vcs.jj_local_pr({ head_ref = "feat" }, function(err) result = err end)
      assert.is_false(spawned)
      assert.is_truthy(result:find("unknown"))
    end)
  end)
end)
