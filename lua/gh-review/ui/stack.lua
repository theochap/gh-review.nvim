--- Floating picker over the jj stack: every commit between trunk and the tip of
--- the branch the review sits on, tip first. Doubles as a preview of a stacked
--- PR series and as the way to jump between its commits.
local M = {}

local state = require("gh-review.state")
local picker_util = require("gh-review.ui.picker_util")

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

--- Show the stack picker.
---
--- `current_change_id` and `pr_change_ids` exist because the oids GitHub reports
--- are the commits as pushed: after a local amend or rebase the stack holds their
--- replacements, which carry the same change ids but new commit ids. Matching on
--- both means the marker and the badges survive a rewrite.
---@param commits GHReviewJJCommit[] from vcs.jj_stack, tip first
---@param opts { current_oid?: string, current_change_id?: string, pr_change_ids?: table<string, true>, truncated?: boolean, on_select: fun(commit: GHReviewJJCommit) }
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

  local items = {}
  for _, commit in ipairs(commits) do
    local bookmarks = table.concat(commit.bookmarks, ", ")
    local change_id = commit.change_id
    local is_current = (opts.current_oid ~= nil and commit.commit_id == opts.current_oid)
      or (opts.current_change_id ~= nil and change_id ~= nil and change_id == opts.current_change_id)
    local in_loaded_pr = in_pr[commit.commit_id] or (change_id ~= nil and pr_changes[change_id])
    table.insert(items, {
      text = table.concat({ commit.commit_id:sub(1, 8), commit.description, bookmarks, commit.author }, " "),
      _commit = commit,
      _is_current = is_current,
      _pr_number = in_loaded_pr and pr and pr.number or nil,
    })
  end

  local title = "jj Stack — trunk..tip"
  if opts.truncated then
    title = title .. " (first " .. #commits .. " from the tip)"
  end

  Snacks.picker.pick({
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
      local parts = {
        { current and "> " or "  ", current and picker_util.ACTIVE or "SnacksPickerIdx" },
        { commit.commit_id:sub(1, 8), entry_hl or "Identifier" },
        { " " .. (commit.description ~= "" and commit.description or "(no description)"), entry_hl },
      }
      if #commit.bookmarks > 0 then
        table.insert(parts, {
          "  " .. table.concat(commit.bookmarks, ", "),
          entry_hl or "Special",
          virtual = true,
        })
      end
      if item._pr_number then
        table.insert(parts, { "  #" .. item._pr_number, entry_hl or "DiagnosticInfo", virtual = true })
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
end

return M
