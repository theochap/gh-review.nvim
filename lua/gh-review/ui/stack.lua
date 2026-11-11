--- Floating picker over the jj stack: every commit between trunk and the tip of
--- the branch the review sits on, tip first. Doubles as a preview of a stacked
--- PR series and as the way to jump between its commits.
local M = {}

local state = require("gh-review.state")
local picker_util = require("gh-review.ui.picker_util")
local util = require("gh-review.util")

local SOURCE = "gh_review_stack"

---@return table[] pickers Open stack pickers (empty when snacks is absent)
local function open_pickers()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then return {} end
  local pickers = Snacks.picker.get({ source = SOURCE })
  return pickers or {}
end

--- Close the stack picker.
---@return boolean closed Whether a picker was open
function M.close()
  local pickers = open_pickers()
  for _, picker in ipairs(pickers) do
    picker:close()
  end
  return #pickers > 0
end

--- Oids of the commits belonging to the PR under review, for marking which part
--- of the stack the loaded PR covers.
---@return table<string, true>
local function loaded_pr_oids()
  local oids = {}
  for _, commit in ipairs(state.get_commits()) do
    oids[commit.oid] = true
  end
  return oids
end

--- The head bookmarks of the PR each commit belongs to: those of the nearest
--- bookmarked commit at or above it, since a PR's head branch sits on the top
--- commit of its range. Commits above the topmost bookmark belong to no PR
--- (not pushed yet).
---@param commits GHReviewJJCommit[] Tip first
---@return table<number, string[]> heads By index into `commits`
function M.pr_heads(commits)
  local heads, current = {}, nil
  for i, commit in ipairs(commits) do
    if #commit.bookmarks > 0 then current = commit.bookmarks end
    heads[i] = current
  end
  return heads
end

--- Fill in the PR number of every commit, and the position of its PR in the
--- stack ("2/5"), then redraw. The numbers come from one query over every
--- head bookmark. The position is the PR's in its native GitHub stack when
--- there is one, else its order among the PRs of this jj stack.
---@param items table[] Picker items, tip first (`_pr_number`, `_pr_position` are set)
---@param picker table?
function M.load_prs(items, picker)
  local branches, seen = {}, {}
  for _, item in ipairs(items) do
    for _, name in ipairs(item._heads or {}) do
      if not seen[name] then
        seen[name] = true
        table.insert(branches, name)
      end
    end
  end
  if #branches == 0 then return end
  local gh = require("gh-review.gh")
  gh.prs_by_head(branches, function(err, numbers)
    if err or not numbers then return end
    -- PRs bottom first, for the local positions.
    local order, counted = {}, {}
    for i = #items, 1, -1 do
      local item = items[i]
      for _, name in ipairs(item._heads or {}) do
        if numbers[name] then
          item._pr_number = numbers[name]
          break
        end
      end
      if item._pr_number and not counted[item._pr_number] then
        counted[item._pr_number] = true
        table.insert(order, item._pr_number)
      end
      if item._pr_number then item.text = item.text .. " #" .. item._pr_number end
    end
    if #order == 0 then return end

    local function apply(position_of)
      for _, item in ipairs(items) do
        item._pr_position = item._pr_number and position_of[item._pr_number] or nil
      end
      require("gh-review.ui.picker_util").redraw(picker)
    end
    local local_positions = {}
    for i, number in ipairs(order) do local_positions[number] = i .. "/" .. #order end

    gh.repo_name(function(repo_err, repo)
      local owner, name = (repo or ""):match("^(.+)/(.+)$")
      if repo_err or not owner then
        apply(local_positions)
        return
      end
      require("gh-review.graphql").fetch_pr_stack(owner, name, order[1], function(stack_err, raw)
        if stack_err or not raw then
          apply(local_positions)
          return
        end
        local stack = require("gh-review.gh_stack").parse_stack(raw)
        local total = math.max(stack.size or 0, #stack.entries)
        local positions = {}
        for _, e in ipairs(stack.entries) do positions[e.pr.number] = e.position .. "/" .. total end
        -- PRs outside the native stack keep their local order.
        for number, pos in pairs(local_positions) do
          if not positions[number] then positions[number] = pos end
        end
        apply(positions)
      end)
    end)
  end)
end

--- Show the stack picker.
---
--- `current_change_id` and `pr_change_ids` exist because the oids GitHub reports
--- are the commits as pushed: after a local amend or rebase the stack holds their
--- replacements, which carry the same change ids but new commit ids. Matching on
--- both means the marker and the badges survive a rewrite.
---@param commits GHReviewJJCommit[] from vcs.jj_stack, tip first
---@param opts { current_oid?: string, current_change_id?: string, pr_change_ids?: table<string, true>, truncated?: boolean, on_select: fun(commit: GHReviewJJCommit) }
---@return table? picker
function M.show(commits, opts)
  if #commits == 0 then
    vim.notify("GHReview: no commits between trunk and the tip", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for the stack picker", vim.log.levels.ERROR)
    return
  end

  picker_util.ensure_highlights()

  local pr = state.get_pr()
  local in_pr = loaded_pr_oids()
  local pr_changes = opts.pr_change_ids or {}

  local heads = M.pr_heads(commits)
  local items = {}
  for i, commit in ipairs(commits) do
    local bookmarks = table.concat(commit.bookmarks, ", ")
    local change_id = commit.change_id
    local is_current = (opts.current_oid ~= nil and commit.commit_id == opts.current_oid)
      or (opts.current_change_id ~= nil and change_id ~= nil and change_id == opts.current_change_id)
    local in_loaded_pr = in_pr[commit.commit_id] or (change_id ~= nil and pr_changes[change_id])
    table.insert(items, {
      text = table.concat({ commit.commit_id:sub(1, 8), commit.description, bookmarks, commit.author }, " "),
      _commit = commit,
      _is_current = is_current,
      -- Known at once for the loaded PR; `load_prs` fills in the others.
      _pr_number = in_loaded_pr and pr and pr.number or nil,
      _heads = heads[i],
    })
  end

  local title = "jj Stack — trunk..tip"
  if opts.truncated then
    title = title .. " (first " .. #commits .. " from the tip)"
  end

  local picker = Snacks.picker.pick({
    source = SOURCE,
    title = title,
    items = items,
    layout = { preset = "select", preview = false },
    -- The commit the review sits on opens under the cursor, highlighted across
    -- the whole entry so its place in the stack is obvious at a glance.
    on_show = function(picker)
      picker_util.focus_current(picker, function(item) return item._is_current end)
    end,
    format = function(item)
      local commit = item._commit
      local current = item._is_current
      local entry_hl = current and picker_util.ACTIVE_ENTRY or nil
      -- Same layout as the PR list: PR number first, its place in the stack,
      -- then the cropped title.
      local parts = {
        { current and "> " or "  ", current and picker_util.ACTIVE or "SnacksPickerIdx" },
        { ("%-7s"):format(item._pr_number and ("#" .. item._pr_number) or ""), entry_hl or "Number" },
        { ("%-6s"):format(item._pr_position or ""), entry_hl or "Comment" },
        { commit.commit_id:sub(1, 8), entry_hl or "Identifier" },
        { " " .. util.crop_title(commit.description ~= "" and commit.description or "(no description)"), entry_hl },
      }
      if #commit.bookmarks > 0 then
        table.insert(parts, {
          "  " .. table.concat(commit.bookmarks, ", "),
          entry_hl or "Special",
          virtual = true,
        })
      end
      local meta = { commit.author, commit.when }
      table.insert(parts, {
        "  @" .. table.concat(vim.tbl_filter(function(s) return s ~= "" end, meta), " "),
        entry_hl or "Comment",
        virtual = true,
      })
      return parts
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      opts.on_select(item._commit)
    end,
    actions = {
      clear_commit = function(picker)
        picker:close()
        require("gh-review").clear_commit()
      end,
    },
    win = {
      input = {
        keys = {
          ["x"] = { "clear_commit", desc = "Clear commit filter" },
        },
      },
      list = {
        keys = {
          ["x"] = { "clear_commit", desc = "Clear commit filter" },
        },
      },
    },
  })
  M.load_prs(items, picker)
  return picker
end

return M
