---@module 'luassert'

local gh_stack = require("gh-review.gh_stack")

--- Build a GraphQL PullRequest node for a stack entry
local function pr_node(number, overrides)
  return vim.tbl_extend("force", {
    number = number,
    title = "PR " .. number,
    url = "https://github.com/o/r/pull/" .. number,
    state = "OPEN",
    isDraft = false,
    author = { login = "dev" },
    headRefName = "branch-" .. number,
    headRefOid = "sha" .. number,
    baseRefName = "main",
    baseRefOid = "base" .. number,
    mergeable = "MERGEABLE",
    mergeStateStatus = "CLEAN",
    reviewDecision = "APPROVED",
    statusCheckRollup = { state = "SUCCESS" },
  }, overrides or {})
end

--- Build a GraphQL PullRequestStack from a list of PR nodes, bottom first
local function stack_node(prs, number)
  local nodes = {}
  for i, pr in ipairs(prs) do
    table.insert(nodes, { position = i, pullRequest = pr })
  end
  return { number = number or 7, size = #prs, baseRefName = "main", entries = { nodes = nodes } }
end

--- Parse a stack and apply the status fields its PR nodes carry, the way
--- `stack_status` does once statuses are fetched.
local function parse(node)
  local stack = gh_stack.parse_stack(node)
  local statuses = {}
  for _, e in ipairs(node.entries.nodes) do
    if type(e.pullRequest) == "table" then
      statuses[e.pullRequest.number] = gh_stack.parse_status(e.pullRequest)
    end
  end
  gh_stack.apply_statuses(stack, statuses)
  return stack
end

describe("gh_stack", function()
  describe("blockers", function()
    local function blockers(overrides)
      return gh_stack.blockers(parse(stack_node({ pr_node(1, overrides) })).entries[1].pr)
    end

    it("is empty for a clean, approved, green PR", function()
      assert.are.same({}, blockers())
    end)

    it("lists draft, conflicts, review and checks", function()
      assert.are.same(
        { "draft", "conflicts", "changes requested", "checks failing" },
        blockers({
          isDraft = true,
          mergeable = "CONFLICTING",
          reviewDecision = "CHANGES_REQUESTED",
          statusCheckRollup = { state = "FAILURE" },
        })
      )
    end)

    it("reports pending checks and missing review", function()
      assert.are.same(
        { "review required", "checks pending" },
        blockers({ reviewDecision = "REVIEW_REQUIRED", statusCheckRollup = { state = "PENDING" } })
      )
    end)

    it("falls back to GitHub's merge state", function()
      assert.are.same({ "blocked by branch rules" }, blockers({ mergeStateStatus = "BLOCKED" }))
      assert.are.same({ "behind base" }, blockers({ mergeStateStatus = "BEHIND" }))
      assert.are.same({ "mergeability not computed yet" }, blockers({ mergeStateStatus = "UNKNOWN" }))
    end)

    it("does not repeat the merge state when a specific reason exists", function()
      assert.are.same({ "draft" }, blockers({ isDraft = true, mergeStateStatus = "BLOCKED" }))
    end)

    it("handles null review decision and checks", function()
      assert.are.same({}, blockers({ reviewDecision = vim.NIL, statusCheckRollup = vim.NIL }))
    end)
  end)

  describe("parse_stack", function()
    it("sorts entries by position and sets status", function()
      local node = stack_node({
        pr_node(1, { state = "MERGED" }),
        pr_node(2),
        pr_node(3, { isDraft = true }),
        pr_node(4, { state = "CLOSED" }),
      })
      -- Shuffle the order GitHub returns
      node.entries.nodes = { node.entries.nodes[3], node.entries.nodes[1], node.entries.nodes[4], node.entries.nodes[2] }
      local stack = parse(node)
      assert.are.same({ 1, 2, 3, 4 }, vim.tbl_map(function(e) return e.position end, stack.entries))
      assert.are.same(
        { "merged", "ready", "blocked", "closed" },
        vim.tbl_map(function(e) return e.status end, stack.entries)
      )
      assert.are.equal("main", stack.base)
      assert.are.equal(7, stack.number)
      assert.are.equal("branch-2", stack.entries[2].pr.head_ref)
      assert.are.equal("sha2", stack.entries[2].pr.head_oid)
    end)

    it("skips entries without a pull request", function()
      local node = stack_node({ pr_node(1) })
      table.insert(node.entries.nodes, { position = 2, pullRequest = vim.NIL })
      assert.are.equal(1, #parse(node).entries)
    end)
  end)

  describe("merge rules", function()
    it("can merge through the highest ready PR above merged ones", function()
      local stack = parse(stack_node({
        pr_node(1, { state = "MERGED" }),
        pr_node(2),
        pr_node(3),
        pr_node(4, { isDraft = true }),
        pr_node(5),
      }))
      assert.are.equal(3, gh_stack.mergeable_through(stack))
      assert.is_true(gh_stack.can_merge(stack, 3))
      assert.are.same({ 2, 3 }, vim.tbl_map(function(p) return p.number end, gh_stack.merge_set(stack, 3)))
    end)

    it("refuses a ready PR that sits above a blocked one", function()
      local stack = parse(stack_node({
        pr_node(1, { isDraft = true }),
        pr_node(2),
      }))
      assert.is_nil(gh_stack.mergeable_through(stack))
      local ok, reason = gh_stack.can_merge(stack, 2)
      assert.is_false(ok)
      assert.are.equal("#1: draft", reason)
    end)

    it("refuses merged and missing positions", function()
      local stack = parse(stack_node({ pr_node(1, { state = "MERGED" }) }))
      local ok, reason = gh_stack.can_merge(stack, 1)
      assert.is_false(ok)
      assert.is_truthy(reason:find("already merged"))
      ok, reason = gh_stack.can_merge(stack, 9)
      assert.is_false(ok)
      assert.is_truthy(reason:find("no PR at position"))
    end)
  end)

  describe("top_open and open_branches", function()
    it("find the topmost open PR and the open branches bottom first", function()
      local stack = parse(stack_node({
        pr_node(1, { state = "MERGED" }),
        pr_node(2),
        pr_node(3),
        pr_node(4, { state = "CLOSED" }),
      }))
      assert.are.equal(3, gh_stack.top_open(stack).number)
      assert.are.same({ "branch-2", "branch-3" }, gh_stack.open_branches(stack))
    end)

    it("returns nil when nothing is open", function()
      local stack = parse(stack_node({ pr_node(1, { state = "MERGED" }) }))
      assert.is_nil(gh_stack.top_open(stack))
    end)
  end)

  describe("group", function()
    it("dedupes stacks and sorts newest first, dropping unstacked PRs", function()
      local a = stack_node({ pr_node(1), pr_node(2) }, 3)
      local b = stack_node({ pr_node(5) }, 9)
      local stacks = gh_stack.group({
        { number = 1, stack = a },
        { number = 2, stack = a },
        { number = 4, stack = vim.NIL },
        { number = 5, stack = b },
      })
      assert.are.same({ 9, 3 }, vim.tbl_map(function(s) return s.number end, stacks))
    end)
  end)

  describe("summary", function()
    it("reports merged count and the mergeable target", function()
      local stack = parse(stack_node({ pr_node(1, { state = "MERGED" }), pr_node(2) }))
      assert.are.equal("1/2 merged · mergeable through #2", gh_stack.summary(stack))
    end)

    it("reports ready PRs held back by a blocked one", function()
      local stack = parse(stack_node({ pr_node(1, { isDraft = true }), pr_node(2) }))
      assert.are.equal("0/2 merged · 1 ready, blocked below", gh_stack.summary(stack))
    end)
  end)

  describe("lazy status", function()
    it("starts open PRs as loading and drafts as blocked", function()
      local stack = gh_stack.parse_stack(stack_node({
        pr_node(1, { state = "MERGED" }), pr_node(2), pr_node(3, { isDraft = true }),
      }))
      assert.are.same({ "merged", "loading", "blocked" }, vim.tbl_map(function(e) return e.status end, stack.entries))
      assert.is_nil(gh_stack.mergeable_through(stack))
      local ok, reason = gh_stack.can_merge(stack, 2)
      assert.is_false(ok)
      assert.are.equal("#2: status still loading", reason)
      assert.is_truthy(gh_stack.summary(stack):find("status loading", 1, true))
      assert.are.equal("base2", stack.entries[2].pr.base_oid)
    end)

    it("lists the PRs still waiting for a status, once each", function()
      local a = gh_stack.parse_stack(stack_node({ pr_node(1), pr_node(2, { isDraft = true }) }, 1))
      local b = gh_stack.parse_stack(stack_node({ pr_node(1), pr_node(3, { state = "MERGED" }) }, 2))
      assert.are.same({ 1, 2 }, vim.tbl_map(function(p) return p.number end, gh_stack.pending_status({ a, b })))
    end)

    it("ignores a status computed for another head", function()
      local stack = gh_stack.parse_stack(stack_node({ pr_node(1) }))
      gh_stack.apply_statuses(stack, { [1] = { head_oid = "other", checks = "SUCCESS" } })
      assert.are.equal("loading", stack.entries[1].status)
      gh_stack.apply_statuses(stack, { [1] = { head_oid = "sha1", checks = "FAILURE" } })
      assert.are.same({ "checks failing" }, stack.entries[1].blockers)
    end)

    it("keys statuses on head and base", function()
      assert.are.equal("o/r#1@h-b", gh_stack.status_key("o/r", { number = 1, head_oid = "h", base_oid = "b" }))
      assert.is_nil(gh_stack.status_key("o/r", { number = 1, head_oid = "h" }))
    end)

    it("caches only statuses that cannot change for the same commits", function()
      local ok = { checks = "SUCCESS", mergeable = "MERGEABLE", merge_state = "CLEAN", review_decision = "APPROVED" }
      assert.is_true(gh_stack.is_settled(ok))
      assert.is_true(gh_stack.is_settled(vim.tbl_extend("force", ok, { checks = "FAILURE" })))
      assert.is_false(gh_stack.is_settled(vim.tbl_extend("force", ok, { checks = "PENDING" })))
      assert.is_false(gh_stack.is_settled(vim.tbl_extend("force", ok, { mergeable = "UNKNOWN" })))
      assert.is_false(gh_stack.is_settled(vim.tbl_extend("force", ok, { merge_state = "BLOCKED" })))
      assert.is_false(gh_stack.is_settled(vim.tbl_extend("force", ok, { review_decision = "REVIEW_REQUIRED" })))
    end)
  end)

  describe("is_timeout_error", function()
    it("matches gateway errors", function()
      assert.is_true(gh_stack.is_timeout_error("gh: HTTP 502"))
      assert.is_true(gh_stack.is_timeout_error("gh: Something went wrong (HTTP 504)"))
      assert.is_false(gh_stack.is_timeout_error("gh: Not Found (HTTP 404)"))
    end)
  end)

  describe("is_unsupported_error", function()
    it("matches the GHES schema error", function()
      assert.is_true(gh_stack.is_unsupported_error("gh: Field 'stack' doesn't exist on type 'PullRequest'"))
      assert.is_false(gh_stack.is_unsupported_error("HTTP 502"))
    end)
  end)

  describe("own_pr", function()
    local function stack(entries)
      local nodes = {}
      for i, e in ipairs(entries) do
        table.insert(nodes, { position = i, pullRequest = { number = e[1], author = { login = e[2] }, state = e[3] or "OPEN" } })
      end
      return gh_stack.parse_stack({ number = 1, entries = { nodes = nodes } })
    end

    it("finds the first and last open PR of the login", function()
      local s = stack({ { 1, "me", "MERGED" }, { 2, "me" }, { 3, "you" }, { 4, "me" }, { 5, "you" } })
      assert.are.equal(2, gh_stack.own_pr(s, "me", "first").number)
      assert.are.equal(4, gh_stack.own_pr(s, "me", "last").number)
      assert.is_nil(gh_stack.own_pr(s, "them", "first"))
    end)
  end)
end)
