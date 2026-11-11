---@module 'luassert'

local gh_stack = require("gh-review.gh_stack")

--- Stack with open PRs { number, head } bottom first
local function make_stack(prs)
  local nodes = {}
  for i, p in ipairs(prs) do
    table.insert(nodes, { position = i, pullRequest = {
      number = p[1], title = "", state = p[3] or "OPEN", author = { login = "d" },
      headRefOid = "h" .. p[1], baseRefOid = "b" .. p[1],
    } })
  end
  return gh_stack.parse_stack({ number = 1, size = #prs, baseRefName = "main", entries = { nodes = nodes } })
end

local function status_node(n, overrides)
  return vim.tbl_extend("force", {
    number = n, headRefOid = "h" .. n, baseRefOid = "b" .. n, mergeable = "MERGEABLE",
    mergeStateStatus = "CLEAN", reviewDecision = "APPROVED", statusCheckRollup = { state = "SUCCESS" },
  }, overrides or {})
end

describe("stack_status", function()
  local stack_status, graphql, cache, asked

  before_each(function()
    package.loaded["gh-review.graphql"] = nil
    package.loaded["gh-review.stack_status"] = nil
    graphql = require("gh-review.graphql")
    stack_status = require("gh-review.stack_status")
    cache = require("gh-review.cache")
    cache.clear()
    asked = {}
    graphql.fetch_pr_statuses = function(owner, name, numbers, cb)
      assert.are.equal("o", owner)
      assert.are.equal("r", name)
      table.insert(asked, numbers)
      local nodes = {}
      for _, n in ipairs(numbers) do
        nodes[n] = status_node(n, n == 2 and { statusCheckRollup = { state = "PENDING" } } or nil)
      end
      cb(nil, nodes)
    end
  end)

  it("fetches missing statuses, applies them, and caches settled ones", function()
    local stack = make_stack({ { 1 }, { 2 }, { 3, nil, "MERGED" } })
    local updated = false
    local missing = stack_status.load("o/r", { stack }, {}, function(err)
      assert.is_nil(err)
      updated = true
    end)
    assert.are.equal(2, missing)
    assert.is_true(updated)
    assert.are.same({ { 1, 2 } }, asked)
    assert.are.same({ "ready", "blocked", "merged" }, vim.tbl_map(function(e) return e.status end, stack.entries))
    assert.is_not_nil(cache.get("status", "o/r#1@h1-b1"))
    assert.is_nil(cache.get("status", "o/r#2@h2-b2"))
  end)

  it("serves cached statuses without asking GitHub", function()
    stack_status.load("o/r", { make_stack({ { 1 } }) }, {}, function() end)
    asked = {}
    local stack = make_stack({ { 1 } })
    local called = false
    local missing = stack_status.load("o/r", { stack }, {}, function() called = true end)
    assert.are.equal(0, missing)
    assert.is_false(called)
    assert.are.same({}, asked)
    assert.are.equal("ready", stack.entries[1].status)
  end)

  it("force refetches every open PR", function()
    stack_status.load("o/r", { make_stack({ { 1 } }) }, {}, function() end)
    asked = {}
    stack_status.load("o/r", { make_stack({ { 1 } }) }, { force = true }, function() end)
    assert.are.same({ { 1 } }, asked)
  end)

  it("reports fetch errors", function()
    graphql.fetch_pr_statuses = function(_, _, _, cb) cb("HTTP 502", nil) end
    local err
    stack_status.load("o/r", { make_stack({ { 1 } }) }, {}, function(e) err = e end)
    assert.are.equal("HTTP 502", err)
  end)
end)
