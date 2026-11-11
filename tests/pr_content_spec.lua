---@module 'luassert'

local config = require("gh-review.config")

--- Run a git command in `dir`, failing the test on error
local function git(dir, args)
  local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  assert(r.code == 0, table.concat(args, " ") .. ": " .. (r.stderr or ""))
  return vim.trim(r.stdout or "")
end

local function write(dir, path, text)
  vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
  local f = assert(io.open(dir .. "/" .. path, "w"))
  f:write(text)
  f:close()
end

describe("pr_content", function()
  local pr_content, cache, gh

  before_each(function()
    config.setup()
    package.loaded["gh-review.pr_content"] = nil
    package.loaded["gh-review.gh"] = nil
    gh = require("gh-review.gh")
    pr_content = require("gh-review.pr_content")
    cache = require("gh-review.cache")
    cache.clear()
  end)

  describe("parsers", function()
    it("parses git name-status and numstat, renames included", function()
      local files = pr_content.parse_git_files(
        "M\0a.lua\0A\0new.lua\0D\0gone.lua\0R087\0old.lua\0moved.lua\0",
        "3\t1\ta.lua\0" .. "5\t0\tnew.lua\0" .. "0\t9\tgone.lua\0" .. "2\t2\t\0old.lua\0moved.lua\0"
      )
      assert.are.same({
        { path = "a.lua", status = "modified", additions = 3, deletions = 1 },
        { path = "new.lua", status = "added", additions = 5, deletions = 0 },
        { path = "gone.lua", status = "deleted", additions = 0, deletions = 9 },
        { path = "moved.lua", status = "renamed", additions = 2, deletions = 2, old_path = "old.lua" },
      }, files)
    end)

    it("counts binary files as zero lines", function()
      local files = pr_content.parse_git_files("A\0img.png\0", "-\t-\timg.png\0")
      assert.are.same({ { path = "img.png", status = "added", additions = 0, deletions = 0 } }, files)
    end)

    it("parses git log lines", function()
      local commits = pr_content.parse_git_log("abcdef1234\31Fix bug\31Ann\0312024-01-01T00:00:00Z\n")
      assert.are.same({
        { sha = "abcdef1", oid = "abcdef1234", message = "Fix bug", author = "Ann", date = "2024-01-01T00:00:00Z" },
      }, commits)
    end)

    it("parses gh files and commits", function()
      assert.are.same(
        { { path = "x", status = "added", additions = 1, deletions = 0, old_path = "y" } },
        pr_content.parse_files({ { path = "x", status = "ADDED", additions = 1, previousFilename = "y" } })
      )
      assert.are.equal("headline", pr_content.parse_commits({
        { oid = "abc", commit = { messageHeadline = "headline", authors = { { login = "a" } } } },
      })[1].message)
    end)
  end)

  describe("cache_key", function()
    it("needs repo, head and base", function()
      assert.are.equal("o/r#3@h-b", pr_content.cache_key({ repo = "o/r", number = 3, head_oid = "h", base_oid = "b" }))
      assert.is_nil(pr_content.cache_key({ repo = "o/r", number = 3, head_oid = "h" }))
      assert.is_nil(pr_content.cache_key({ number = 3, head_oid = "h", base_oid = "b" }))
    end)
  end)

  describe("compute_local", function()
    local dir, orig_cwd

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      git(dir, { "init", "-q", "-b", "main" })
      git(dir, { "config", "user.email", "t@t" })
      git(dir, { "config", "user.name", "Tester" })
      write(dir, "keep.lua", "a\nb\nc\n")
      write(dir, "old.lua", "x\ny\nz\nw\n")
      git(dir, { "add", "." })
      git(dir, { "commit", "-q", "-m", "base" })
      orig_cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      package.loaded["gh-review.vcs"] = nil
      package.loaded["gh-review.pr_content"] = nil
      pr_content = require("gh-review.pr_content")
    end)

    after_each(function()
      vim.cmd.cd(orig_cwd)
      package.loaded["gh-review.vcs"] = nil
      vim.fn.delete(dir, "rf")
    end)

    it("diffs the PR head against the merge base with the base tip", function()
      local base_start = git(dir, { "rev-parse", "HEAD" })
      git(dir, { "checkout", "-q", "-b", "feature" })
      write(dir, "keep.lua", "a\nB\nc\n")
      git(dir, { "mv", "old.lua", "new.lua" })
      write(dir, "added.lua", "hello\n")
      git(dir, { "add", "." })
      git(dir, { "commit", "-q", "-m", "feature work" })
      local head = git(dir, { "rev-parse", "HEAD" })
      -- The base moves on after the PR branched: its commits must not show up.
      git(dir, { "checkout", "-q", "main" })
      write(dir, "main_only.lua", "m\n")
      git(dir, { "add", "." })
      git(dir, { "commit", "-q", "-m", "main moves" })
      local base_tip = git(dir, { "rev-parse", "HEAD" })
      assert.are_not.equal(base_start, base_tip)

      local content
      pr_content.compute_local({ number = 1, head_oid = head, base_oid = base_tip }, function(c) content = c end)
      vim.wait(5000, function() return content ~= nil end)

      assert.are.equal("local", content.source)
      local paths = vim.tbl_map(function(f) return f.path .. ":" .. f.status end, content.files)
      table.sort(paths)
      assert.are.same({ "added.lua:added", "keep.lua:modified", "new.lua:renamed" }, paths)
      assert.is_nil(content.diff_text:find("main_only", 1, true))
      assert.is_truthy(content.diff_text:find("diff --git a/keep.lua b/keep.lua", 1, true))
      local parsed = require("gh-review.diff").parse(content.diff_text)
      assert.is_not_nil(parsed["keep.lua"])
      assert.are.same({ "feature work" }, vim.tbl_map(function(c) return c.message end, content.commits))
      assert.are.equal("Tester", content.commits[1].author)
    end)

    it("gives up when a commit is not in the local store", function()
      local head = git(dir, { "rev-parse", "HEAD" })
      local content = "unset"
      pr_content.compute_local({ number = 1, head_oid = head, base_oid = string.rep("1", 40) }, function(c) content = c end)
      vim.wait(5000, function() return content ~= "unset" end)
      assert.is_nil(content)
    end)

    it("gives up without oids", function()
      local content = "unset"
      pr_content.compute_local({ number = 1 }, function(c) content = c end)
      assert.is_nil(content)
    end)
  end)

  describe("load_jj", function()
    local dir, orig_cwd
    local has_jj = vim.fn.executable("jj") == 1

    local function jj(args)
      local r = vim.system(vim.list_extend({ "jj", "--config", "user.name=Tester", "--config", "user.email=t@t" }, args),
        { text = true, cwd = dir }):wait()
      assert(r.code == 0, table.concat(args, " ") .. ": " .. (r.stderr or ""))
      return vim.trim(r.stdout or "")
    end

    before_each(function()
      if not has_jj then return end
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      jj({ "git", "init", "--colocate" })
      write(dir, "keep.lua", "a\nb\nc\n")
      jj({ "commit", "-m", "base" })
      jj({ "bookmark", "create", "main", "-r", "@-" })
      write(dir, "keep.lua", "a\nB\nc\n")
      jj({ "commit", "-m", "feature work" })
      jj({ "bookmark", "create", "feat", "-r", "@-" })
      orig_cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      package.loaded["gh-review.vcs"] = nil
      package.loaded["gh-review.pr_content"] = nil
      pr_content = require("gh-review.pr_content")
    end)

    after_each(function()
      if not has_jj then return end
      vim.cmd.cd(orig_cwd)
      package.loaded["gh-review.vcs"] = nil
      vim.fn.delete(dir, "rf")
    end)

    local function load(spec)
      local result
      pr_content.load_jj(spec, function(err, content) result = { err = err, content = content } end)
      vim.wait(10000, function() return result ~= nil end)
      return result
    end

    it("diffs from the base bookmark to the last non-empty commit, edits on disk included", function()
      if not has_jj then return pending("jj is not installed") end
      local main = jj({ "log", "-r", "main", "--no-graph", "-T", "commit_id" })
      -- Edits jj has not recorded yet, on top of the head bookmark.
      write(dir, "wip.lua", "new\n")

      local result = load({ head_ref = "feat", base_ref = "main" })

      assert.is_nil(result.err)
      local content = result.content
      assert.are.equal("jj", content.source)
      assert.are.equal(main, content.base_sha)
      local paths = vim.tbl_map(function(f) return f.path .. ":" .. f.status end, content.files)
      table.sort(paths)
      assert.are.same({ "keep.lua:modified", "wip.lua:added" }, paths)
      assert.are.same({ "feature work", "" }, vim.tbl_map(function(c) return c.message end, content.commits))
    end)

    it("stops at the head bookmark when the working copy is empty", function()
      if not has_jj then return pending("jj is not installed") end
      local result = load({ head_ref = "feat", base_ref = "main" })
      assert.is_nil(result.err)
      assert.are.same({ "feature work" }, vim.tbl_map(function(c) return c.message end, result.content.commits))
    end)

    it("errors when the PR head is not in the repository", function()
      if not has_jj then return pending("jj is not installed") end
      local result = load({ head_ref = "missing", base_ref = "main" })
      assert.is_nil(result.content)
      assert.is_truthy(result.err:find("not in this jj repository"))
    end)
  end)

  describe("load", function()
    local network_calls

    before_each(function()
      network_calls = 0
      gh.pr_files = function(_, cb) network_calls = network_calls + 1; cb(nil, { { path = "f", status = "modified" } }) end
      gh.pr_diff = function(_, cb) cb(nil, "diff --git a/f b/f\n") end
      gh.pr_commits = function(_, cb) cb(nil, { { oid = "abc", commit = { messageHeadline = "m" } } }) end
    end)

    local ref = { repo = "o/r", number = 3, head_oid = "h", base_oid = "b" }

    it("prefers local content and does not cache it", function()
      pr_content.compute_local = function(_, cb) cb({ files = {}, diff_text = "", commits = {}, source = "local" }) end
      local content
      pr_content.load(ref, function(_, c) content = c end)
      assert.are.equal("local", content.source)
      assert.are.equal(0, network_calls)
      assert.is_nil(cache.get("content", pr_content.cache_key(ref)))
    end)

    it("falls back to the network, caches, then serves from the cache", function()
      pr_content.compute_local = function(_, cb) cb(nil) end
      local first, second
      pr_content.load(ref, function(_, c) first = c end)
      pr_content.load(ref, function(_, c) second = c end)
      assert.are.equal("network", first.source)
      assert.are.equal("cache", second.source)
      assert.are.equal(1, network_calls)
      assert.are.same(first.files, second.files)
    end)

    it("builds the diff from file patches without calling gh pr diff", function()
      pr_content.compute_local = function(_, cb) cb(nil) end
      gh.pr_files = function(_, cb)
        cb(nil, {
          { path = "a.lua", status = "modified", additions = 1, deletions = 1, patch = "@@ -1 +1 @@\n-x\n+y" },
          { path = "new.lua", status = "renamed", additions = 0, deletions = 0, previousFilename = "old.lua" },
        })
      end
      local diffed = false
      gh.pr_diff = function() diffed = true end
      local content
      pr_content.load({ repo = "o/r", number = 3 }, function(_, c) content = c end)
      assert.is_false(diffed)
      assert.are.equal("diff --git a/a.lua b/a.lua\n--- a/a.lua\n+++ b/a.lua\n@@ -1 +1 @@\n-x\n+y\n", content.diff_text)
      assert.are.equal(1, #require("gh-review.diff").parse(content.diff_text)["a.lua"].hunks)
    end)

    it("falls back to gh pr diff when a changed file has no patch, and reports its errors", function()
      pr_content.compute_local = function(_, cb) cb(nil) end
      gh.pr_files = function(_, cb) cb(nil, { { path = "huge.json", status = "modified", additions = 9000, deletions = 0 } }) end
      gh.pr_diff = function(_, cb) cb("HTTP 500", nil) end
      local errors
      pr_content.load({ repo = "o/r", number = 3 }, function(e) errors = e end)
      assert.are.same({ "diff: HTTP 500" }, errors)
    end)
  end)
end)
