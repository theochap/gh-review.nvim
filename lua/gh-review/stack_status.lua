--- Fill native stacks with merge status. Cached statuses apply at once; the
--- rest come from GitHub in the background, and settled ones are cached under
--- the PR's head and base oids.
local M = {}

local cache = require("gh-review.cache")
local gh_stack = require("gh-review.gh_stack")

--- Apply cached statuses, then fetch the missing ones.
---
--- Returns after the cached statuses are applied, so the caller can draw right
--- away. `on_update` runs once the fetch is done (not at all when nothing was
--- missing).
---@param repo string owner/name
---@param stacks GHReviewStack[]
---@param opts { force?: boolean } `force` skips the cache and refetches every open PR
---@param on_update fun(err: string?)
---@return number missing How many statuses are being fetched
function M.load(repo, stacks, opts, on_update)
  local owner, name = repo:match("^(.+)/(.+)$")
  local prs
  if opts.force then
    prs = {}
    for _, stack in ipairs(stacks) do
      for _, e in ipairs(stack.entries) do
        if e.pr.state == "OPEN" then table.insert(prs, e.pr) end
      end
    end
  else
    prs = gh_stack.pending_status(stacks)
  end

  local cached, missing = {}, {}
  for _, pr in ipairs(prs) do
    local key = gh_stack.status_key(repo, pr)
    local hit = not opts.force and key and cache.get("status", key) or nil
    if type(hit) == "table" then
      cached[pr.number] = hit
    else
      table.insert(missing, pr.number)
    end
  end
  for _, stack in ipairs(stacks) do gh_stack.apply_statuses(stack, cached) end

  if #missing == 0 or not owner then return 0 end
  require("gh-review.graphql").fetch_pr_statuses(owner, name, missing, function(err, nodes)
    if err then
      on_update(err)
      return
    end
    local statuses = {}
    for number, node in pairs(nodes or {}) do
      local st = gh_stack.parse_status(node)
      statuses[number] = st
      local key = gh_stack.status_key(repo, { number = number, head_oid = st.head_oid, base_oid = st.base_oid })
      if key and gh_stack.is_settled(st) then cache.set("status", key, st) end
    end
    for _, stack in ipairs(stacks) do gh_stack.apply_statuses(stack, statuses) end
    on_update(nil)
  end)
  return #missing
end

return M
