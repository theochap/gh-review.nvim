--- Native GitHub PR stacks: parse the GraphQL `stack` objects and decide which
--- PRs of a stack can be merged. Merging a stacked PR also merges every PR below
--- it, so a PR can only be merged when it and every open PR below it are ready.
local M = {}

---@class GHReviewStackPR
---@field number number
---@field title string
---@field url string
---@field state string OPEN|CLOSED|MERGED
---@field is_draft boolean
---@field author string
---@field head_ref string
---@field head_oid string?
---@field base_ref string
---@field base_oid string?
---@field status_loaded boolean Whether the fields below are known yet
---@field mergeable string? MERGEABLE|CONFLICTING|UNKNOWN
---@field merge_state string? GitHub MergeStateStatus
---@field review_decision string?
---@field checks string? StatusCheckRollup state

---@class GHReviewStackEntry
---@field position number 1 is the PR closest to the base branch
---@field pr GHReviewStackPR
---@field status "merged"|"closed"|"ready"|"blocked"|"loading"
---@field blockers string[] Why the PR cannot merge (empty when ready)

---@class GHReviewStack
---@field number number
---@field size number
---@field base string Branch the stack targets
---@field entries GHReviewStackEntry[] Sorted by position, bottom first

--- Reasons a single open PR cannot be merged, from its own state only.
---@param pr GHReviewStackPR
---@return string[]
function M.blockers(pr)
  local reasons = {}
  if pr.is_draft then table.insert(reasons, "draft") end
  if pr.mergeable == "CONFLICTING" or pr.merge_state == "DIRTY" then
    table.insert(reasons, "conflicts")
  end
  if pr.review_decision == "CHANGES_REQUESTED" then
    table.insert(reasons, "changes requested")
  elseif pr.review_decision == "REVIEW_REQUIRED" then
    table.insert(reasons, "review required")
  end
  if pr.checks == "FAILURE" or pr.checks == "ERROR" then
    table.insert(reasons, "checks failing")
  elseif pr.checks == "PENDING" or pr.checks == "EXPECTED" then
    table.insert(reasons, "checks pending")
  end
  -- GitHub's own verdict covers rules the fields above do not show (required
  -- reviewers, rulesets). Only add it when nothing more specific explains it.
  if #reasons == 0 then
    if pr.merge_state == "BLOCKED" then
      table.insert(reasons, "blocked by branch rules")
    elseif pr.merge_state == "BEHIND" then
      table.insert(reasons, "behind base")
    elseif pr.merge_state == "UNKNOWN" or pr.mergeable == "UNKNOWN" then
      table.insert(reasons, "mergeability not computed yet")
    end
  end
  return reasons
end

local function str(v) return type(v) == "string" and v or nil end

---@param node table GraphQL PullRequest
---@return GHReviewStackPR
local function parse_pr(node)
  return {
    number = node.number,
    title = str(node.title) or "",
    url = str(node.url) or "",
    state = str(node.state) or "OPEN",
    is_draft = node.isDraft == true,
    author = type(node.author) == "table" and node.author.login or "ghost",
    head_ref = str(node.headRefName) or "",
    head_oid = str(node.headRefOid),
    base_ref = str(node.baseRefName) or "",
    base_oid = str(node.baseRefOid),
    status_loaded = false,
  }
end

--- Recompute an entry's status from its PR.
---@param entry GHReviewStackEntry
function M.update_entry(entry)
  local pr = entry.pr
  if pr.state == "MERGED" then
    entry.status, entry.blockers = "merged", {}
  elseif pr.state == "CLOSED" then
    entry.status, entry.blockers = "closed", { "closed" }
  elseif not pr.status_loaded then
    -- A draft is blocked whatever the rest says; anything else must wait.
    entry.blockers = pr.is_draft and { "draft" } or {}
    entry.status = pr.is_draft and "blocked" or "loading"
  else
    entry.blockers = M.blockers(pr)
    entry.status = #entry.blockers == 0 and "ready" or "blocked"
  end
end

--- Merge status of a PR as stored in the cache and applied to entries.
---@class GHReviewPRStatus
---@field head_oid string?
---@field base_oid string?
---@field mergeable string?
---@field merge_state string?
---@field review_decision string?
---@field checks string?

--- Convert a GraphQL status node (see `graphql.fetch_pr_statuses`).
---@param node table
---@return GHReviewPRStatus
function M.parse_status(node)
  local rollup = type(node.statusCheckRollup) == "table" and node.statusCheckRollup or nil
  return {
    head_oid = str(node.headRefOid),
    base_oid = str(node.baseRefOid),
    mergeable = str(node.mergeable),
    merge_state = str(node.mergeStateStatus),
    review_decision = str(node.reviewDecision),
    checks = rollup and str(rollup.state) or nil,
  }
end

--- Cache key of a PR's merge status: it holds for one head and one base
--- commit only. Nil when either is unknown.
---@param repo string owner/name
---@param pr { number: number, head_oid: string?, base_oid: string? }
---@return string?
function M.status_key(repo, pr)
  if not (pr.head_oid and pr.base_oid) then return nil end
  return repo .. "#" .. pr.number .. "@" .. pr.head_oid .. "-" .. pr.base_oid
end

--- Whether a status cannot change while the head and base commits stay the
--- same, and so may be cached. Pending checks, unknown mergeability, and every
--- verdict a review can still flip (review required, changes requested,
--- blocked) are not settled.
---@param status GHReviewPRStatus
---@return boolean
function M.is_settled(status)
  if status.checks == "PENDING" or status.checks == "EXPECTED" then return false end
  if status.mergeable == "UNKNOWN" or status.merge_state == "UNKNOWN" then return false end
  if status.merge_state == "BLOCKED" then return false end
  if status.review_decision == "REVIEW_REQUIRED" or status.review_decision == "CHANGES_REQUESTED" then
    return false
  end
  return true
end

--- Apply statuses to the entries they belong to. A status computed for other
--- commits than the entry's (the PR moved since the metadata was read) is
--- ignored.
---@param stack GHReviewStack
---@param statuses table<number, GHReviewPRStatus> by PR number
function M.apply_statuses(stack, statuses)
  for _, e in ipairs(stack.entries) do
    local st = statuses[e.pr.number]
    if st and (not st.head_oid or not e.pr.head_oid or st.head_oid == e.pr.head_oid) then
      e.pr.mergeable = st.mergeable
      e.pr.merge_state = st.merge_state
      e.pr.review_decision = st.review_decision
      e.pr.checks = st.checks
      e.pr.status_loaded = true
      M.update_entry(e)
    end
  end
end

--- Open PRs whose status is not loaded yet.
---@param stacks GHReviewStack[]
---@return GHReviewStackPR[]
function M.pending_status(stacks)
  local prs, seen = {}, {}
  for _, stack in ipairs(stacks) do
    for _, e in ipairs(stack.entries) do
      if e.status == "loading" or (e.pr.state == "OPEN" and not e.pr.status_loaded) then
        if not seen[e.pr.number] then
          seen[e.pr.number] = true
          table.insert(prs, e.pr)
        end
      end
    end
  end
  return prs
end

--- Parse a GraphQL PullRequestStack (metadata only: every open entry starts as
--- "loading", or "blocked" for drafts, until `apply_statuses`).
---@param node table
---@return GHReviewStack
function M.parse_stack(node)
  local entries = {}
  local nodes = node.entries and node.entries.nodes or {}
  for _, e in ipairs(nodes) do
    if type(e.pullRequest) == "table" then
      local entry = { position = e.position, pr = parse_pr(e.pullRequest), blockers = {} }
      M.update_entry(entry)
      table.insert(entries, entry)
    end
  end
  table.sort(entries, function(a, b) return a.position < b.position end)
  return {
    number = node.number,
    size = node.size or #entries,
    base = node.baseRefName or "",
    entries = entries,
  }
end

---@param stack GHReviewStack
---@param position number
---@return GHReviewStackEntry?
function M.entry_at(stack, position)
  for _, e in ipairs(stack.entries) do
    if e.position == position then return e end
  end
  return nil
end

--- Whether the PR at `position` can be merged, given that every open PR below it
--- merges along with it.
---@param stack GHReviewStack
---@param position number
---@return boolean ok, string? reason
function M.can_merge(stack, position)
  local target = M.entry_at(stack, position)
  if not target then return false, "no PR at position " .. position end
  if target.status == "merged" then
    return false, "#" .. target.pr.number .. " is already merged"
  end
  for _, e in ipairs(stack.entries) do
    if e.position > position then break end
    if e.status == "loading" then
      return false, "#" .. e.pr.number .. ": status still loading"
    end
    if e.status ~= "merged" and e.status ~= "ready" then
      return false, "#" .. e.pr.number .. ": " .. table.concat(e.blockers, ", ")
    end
  end
  return true, nil
end

--- Highest position that can be merged right now, or nil when the lowest open PR
--- is blocked (or everything is merged).
---@param stack GHReviewStack
---@return number?
function M.mergeable_through(stack)
  local best
  for _, e in ipairs(stack.entries) do
    if e.status == "ready" then
      best = e.position
    elseif e.status ~= "merged" then
      break
    end
  end
  return best
end

--- The open PRs that a merge up to `position` lands, bottom first.
---@param stack GHReviewStack
---@param position number
---@return GHReviewStackPR[]
function M.merge_set(stack, position)
  local prs = {}
  for _, e in ipairs(stack.entries) do
    if e.position > position then break end
    if e.status ~= "merged" then table.insert(prs, e.pr) end
  end
  return prs
end

--- The topmost open PR of the stack. Its head branch holds every open PR below.
---@param stack GHReviewStack
---@return GHReviewStackPR?
function M.top_open(stack)
  for i = #stack.entries, 1, -1 do
    if stack.entries[i].pr.state == "OPEN" then return stack.entries[i].pr end
  end
  return nil
end

--- The first (closest to the base) or last open PR of the stack authored by
--- `login`. Nil when `login` has no open PR in the stack.
---@param stack GHReviewStack
---@param login string
---@param which "first"|"last"
---@return GHReviewStackPR?
function M.own_pr(stack, login, which)
  local found
  for _, e in ipairs(stack.entries) do
    if e.pr.state == "OPEN" and e.pr.author == login then
      if which == "first" then return e.pr end
      found = e.pr
    end
  end
  return found
end

--- Head branches of the open PRs, bottom first.
---@param stack GHReviewStack
---@return string[]
function M.open_branches(stack)
  local branches = {}
  for _, e in ipairs(stack.entries) do
    if e.pr.state == "OPEN" and e.pr.head_ref ~= "" then
      table.insert(branches, e.pr.head_ref)
    end
  end
  return branches
end

--- Group search results (PRs carrying a `stack`) into distinct stacks, newest
--- first. PRs outside any stack are dropped.
---@param nodes table[] GraphQL PullRequest nodes
---@return GHReviewStack[]
function M.group(nodes)
  local by_number, stacks = {}, {}
  for _, node in ipairs(nodes) do
    local s = type(node.stack) == "table" and node.stack or nil
    if s and not by_number[s.number] then
      by_number[s.number] = true
      table.insert(stacks, M.parse_stack(s))
    end
  end
  table.sort(stacks, function(a, b) return a.number > b.number end)
  return stacks
end

--- One-line summary, e.g. "2/3 merged · 1 ready".
---@param stack GHReviewStack
---@return string
function M.summary(stack)
  local merged, ready, loading = 0, 0, 0
  for _, e in ipairs(stack.entries) do
    if e.status == "merged" then merged = merged + 1 end
    if e.status == "ready" then ready = ready + 1 end
    if e.status == "loading" then loading = loading + 1 end
  end
  local through = M.mergeable_through(stack)
  local parts = { merged .. "/" .. #stack.entries .. " merged" }
  if loading > 0 and not through then
    table.insert(parts, "status loading…")
  elseif through then
    table.insert(parts, "mergeable through #" .. M.entry_at(stack, through).pr.number)
  elseif ready > 0 then
    table.insert(parts, ready .. " ready, blocked below")
  end
  return table.concat(parts, " · ")
end

--- Whether an error is GitHub giving up on a query that took too long.
---@param err string
---@return boolean
function M.is_timeout_error(err)
  return err:find("HTTP 502", 1, true) ~= nil or err:find("HTTP 504", 1, true) ~= nil
    or err:find("timedout", 1, true) ~= nil
end

--- Whether a GraphQL error means the host has no native stacks (older GitHub
--- Enterprise Server versions).
---@param err string
---@return boolean
function M.is_unsupported_error(err)
  return err:find("Field 'stack' doesn't exist", 1, true) ~= nil
    or err:find("Field 'stackEntry' doesn't exist", 1, true) ~= nil
end

return M
