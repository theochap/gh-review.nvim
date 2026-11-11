--- PR fuzzy picker using snacks.nvim
local M = {}

local gh = require("gh-review.gh")
local scope_mod = require("gh-review.scope")
local util = require("gh-review.util")
-- Number search only; redraws go through `require` (tests replace the module).
local number_search = require("gh-review.ui.picker_util")

--- Scope the picker last showed, so reopening it lands where the user left off.
---@type GHReviewScope
M.last_scope = { kind = "all" }

--- Build preview lines for a PR
---@param pr table
---@return string[]
local function build_preview(pr)
  local lines = {}
  local author = pr.author and pr.author.login or "unknown"

  table.insert(lines, "# #" .. pr.number .. " " .. (pr.title or ""))
  table.insert(lines, "")
  table.insert(lines, "**Author:** @" .. author)
  table.insert(lines, "**Branch:** " .. (pr.headRefName or ""))
  table.insert(lines, "**State:** " .. (pr.state or ""))

  if pr.isDraft then
    table.insert(lines, "**Draft:** yes")
  end
  if pr.reviewDecision and pr.reviewDecision ~= "" then
    table.insert(lines, "**Review:** " .. pr.reviewDecision)
  end
  if pr.createdAt then
    local date = util.format_time(pr.createdAt)
    if date ~= pr.createdAt then
      table.insert(lines, "**Created:** " .. date)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  local body = pr.body or ""
  if body ~= "" then
    for line in body:gmatch("[^\n]*") do
      table.insert(lines, line)
    end
  else
    table.insert(lines, "_No description_")
  end

  return lines
end

--- Position of `pr_number` in its stack, e.g. "10/12" (1 is the PR closest
--- to the base). Nil when the stack does not list the PR.
---@param pr_number number
---@param stack GHReviewStack
---@return string?
function M.stack_position(pr_number, stack)
  for _, e in ipairs(stack.entries) do
    if e.pr.number == pr_number then
      return e.position .. "/" .. math.max(stack.size or 0, #stack.entries)
    end
  end
  return nil
end

--- Show the PR picker.
---
--- `scope` picks which PRs are listed (default: all open PRs). The scope keys in
--- `picker_keys` switch it without leaving the picker. `on_checkout`, when set,
--- is bound to `picker_keys.checkout`. `on_own_stack_pr`, when set, is bound
--- to `picker_keys.first_mine` / `last_mine`: it gets the stack of the PR under
--- the cursor.
---@param opts { on_select: fun(pr_number: number), on_checkout?: fun(pr_number: number), on_own_stack_pr?: fun(stack: GHReviewStack, which: "first"|"last"), scope?: GHReviewScope, title?: string }
function M.show(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for PR picker", vim.log.levels.ERROR)
    return
  end

  local scope = opts.scope or { kind = "all" }
  M.last_scope = scope
  vim.notify("GHReview: fetching PRs (" .. scope_mod.label(scope) .. ")...", vim.log.levels.INFO)

  scope_mod.fetch_all(scope, function(term, cb) gh.pr_list(cb, term) end, function(err, prs)
    if err then
      vim.notify("GHReview: failed to list PRs: " .. err, vim.log.levels.ERROR)
      return
    end
    if not prs or #prs == 0 then
      vim.notify("GHReview: no open PRs found (" .. scope_mod.label(scope) .. ")", vim.log.levels.INFO)
      return
    end

    local items = {}
    for _, pr in ipairs(prs) do
      local author = pr.author and pr.author.login or "unknown"
      local draft = pr.isDraft and "[DRAFT] " or ""
      -- text includes all searchable fields
      local text = string.format(
        "#%d %s%s @%s %s",
        pr.number, draft, pr.title or "", author, pr.body or ""
      )
      table.insert(items, {
        text = text,
        -- Matched by a query that is a PR number (see `picker_util.pr_number_filter`).
        pr = pr.number,
        _pr = pr,
        _author = author,
        _draft = draft,
      })
    end

    local actions, keys = scope_mod.picker_actions(function(new_scope)
      M.show(vim.tbl_extend("force", opts, { scope = new_scope }))
    end, scope)
    if opts.on_checkout then
      actions.checkout_pr = function(picker, item)
        if not item then return end
        picker:close()
        opts.on_checkout(item._pr.number, item._pr)
      end
      local lhs = require("gh-review.config").get().picker_keys.checkout
      if lhs and lhs ~= "" then
        keys[lhs] = { "checkout_pr", mode = { "i", "n" }, desc = "Checkout PR only" }
      end
    end
    if opts.on_own_stack_pr then
      local pk = require("gh-review.config").get().picker_keys
      for which, lhs in pairs({ first = pk.first_mine, last = pk.last_mine }) do
        local name = "own_" .. which
        actions[name] = function(picker, item)
          if not item then return end
          if not item._stack then
            vim.notify("GHReview: PR #" .. item._pr.number .. " is not in a GitHub stack (or its stack is still loading)", vim.log.levels.INFO)
            return
          end
          picker:close()
          opts.on_own_stack_pr(item._stack, which)
        end
        if lhs and lhs ~= "" then
          keys[lhs] = { name, mode = { "i", "n" }, desc = "Review the " .. which .. " PR of mine in this stack" }
        end
      end
    end

    local picker = Snacks.picker.pick({
      title = scope_mod.title(opts.title or "Checkout PR", scope),
      items = items,
      -- "123" or "#123" matches the PRs whose number starts with 123.
      filter = number_search.pr_number_filter(function(n) return "pr:^" .. n end),
      actions = actions,
      win = { input = { keys = keys }, list = { keys = keys } },
      format = function(item)
        local pr = item._pr
        -- Review states arrive after the picker opens (see below).
        local icon = util.review_icon(pr.reviewDecision)
        local tag, tag_hl = M.viewer_tag(pr._viewer_review)
        local chunks = {
          { "#" .. pr.number, "Number" },
          { "  " .. item._draft, "WarningMsg" },
          { tag ~= "" and (tag .. " ") or "", tag_hl },
          { util.crop_title(pr.title), "Normal" },
        }
        -- Stacks also arrive after the picker opens.
        local position = item._stack and M.stack_position(pr.number, item._stack)
        if position then table.insert(chunks, { "  ⧉ " .. position, "Comment", virtual = true }) end
        table.insert(chunks, { "  @" .. item._author .. (icon ~= "" and (" " .. icon) or ""), "Special", virtual = true })
        return chunks
      end,
      preview = function(ctx)
        local item = ctx.item
        if not item or not item._pr then return end
        local lines = build_preview(item._pr)
        ctx.preview:set_lines(lines)
        ctx.preview:highlight({ ft = "markdown" })
      end,
      confirm = function(picker, item)
        if not item then
          -- A PR number the list does not hold (older than the newest 50, or
          -- outside the scope): open that PR anyway.
          local number = number_search.pr_number_query(number_search.query(picker))
          if number and opts.on_select then
            picker:close()
            opts.on_select(tonumber(number), nil)
          end
          return
        end
        picker:close()
        if opts.on_select and item._pr then
          opts.on_select(item._pr.number, item._pr)
        end
      end,
    })

    M._load_review_states(scope, items, picker)
    M._load_stacks(scope, items, picker)
  end)
end

--- Fill in the native stack of each stacked PR, then redraw the picker. The
--- position ("stack 10/12") joins the searchable text. Errors are dropped: a
--- host without native stacks, or a slow search, only loses the stack column.
---@param scope GHReviewScope
---@param items table[] Picker items (`_stack` is set on them)
---@param picker table? snacks picker
function M._load_stacks(scope, items, picker)
  local by_number = {}
  for _, item in ipairs(items) do by_number[item._pr.number] = item end
  if next(by_number) == nil then return end
  local gh_stack = require("gh-review.gh_stack")
  for _, term in ipairs(scope_mod.search_terms(scope)) do
    gh.pr_stacks(function(err, stacks)
      if err then return end
      for number, raw in pairs(stacks or {}) do
        local item = by_number[number]
        if item and not item._stack then
          item._stack = gh_stack.parse_stack(raw)
          local position = M.stack_position(number, item._stack)
          if position then item.text = item.text .. " stack " .. position end
        end
      end
      require("gh-review.ui.picker_util").redraw(picker)
    end, term)
  end
end

---@type table<string, string>
local VIEWER_TAG_HL = {
  APPROVED = "DiagnosticOk",
  CHANGES_REQUESTED = "DiagnosticError",
  COMMENTED = "DiagnosticInfo",
}

--- Tag for the state of your own latest review on a PR, e.g. "[Approved]".
---@param state string?
---@return string tag, string hl ("" when there is none)
function M.viewer_tag(state)
  local tags = require("gh-review.config").get().viewer_review_tags or {}
  local tag = state and tags[state] or ""
  return tag, VIEWER_TAG_HL[state] or "Comment"
end

--- Fill in review decisions and your own latest reviews, then redraw the
--- picker. A PR that already carries a decision keeps it. The tag is also
--- added to the searchable text, so typing "approved" finds those PRs.
---@param scope GHReviewScope
---@param items table[] Picker items (their `_pr` is mutated)
---@param picker table? snacks picker
function M._load_review_states(scope, items, picker)
  local by_number = {}
  for _, item in ipairs(items) do by_number[item._pr.number] = item end
  if next(by_number) == nil then return end
  for _, term in ipairs(scope_mod.search_terms(scope)) do
    gh.pr_review_states(function(err, states)
      if err then return end
      for number, st in pairs(states or {}) do
        local item = by_number[number]
        if item then
          local pr = item._pr
          if pr.reviewDecision == nil then pr.reviewDecision = st.decision end
          if st.viewer and not pr._viewer_review then
            pr._viewer_review = st.viewer
            local tag = M.viewer_tag(st.viewer)
            if tag ~= "" then item.text = item.text .. " " .. tag end
          end
        end
      end
      require("gh-review.ui.picker_util").redraw(picker)
    end, term)
  end
end

return M
