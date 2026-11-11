--- Pickers over native GitHub PR stacks: a list of the stacks in a scope, and a
--- panel over one stack that shows which PRs can merge and merges them.
local M = {}

local config = require("gh-review.config")
local gh_stack = require("gh-review.gh_stack")
local picker_util = require("gh-review.ui.picker_util")
local scope_mod = require("gh-review.scope")
local util = require("gh-review.util")

local PANEL_SOURCE = "gh_review_gh_stack"

---@type table<string, { icon: string, hl: string }>
local STATUS = {
  merged = { icon = "✓", hl = "DiagnosticOk" },
  ready = { icon = "●", hl = "DiagnosticOk" },
  blocked = { icon = "✗", hl = "DiagnosticError" },
  closed = { icon = "⊘", hl = "Comment" },
  loading = { icon = "…", hl = "Comment" },
}

--- Short status text of an entry, given the highest mergeable position.
---@param entry GHReviewStackEntry
---@param through number?
---@return string text, string hl
local function entry_status(entry, through)
  if entry.status == "merged" then return "merged", "DiagnosticOk" end
  if entry.status == "loading" then return "loading…", "Comment" end
  if entry.status == "ready" then
    if through and entry.position <= through then return "mergeable", "DiagnosticOk" end
    return "ready, waits on PRs below", "DiagnosticWarn"
  end
  return table.concat(entry.blockers, ", "), "DiagnosticError"
end

--- Lines describing a stack, top PR first.
---@param stack GHReviewStack
---@return string[]
function M.describe(stack)
  local through = gh_stack.mergeable_through(stack)
  local lines = {
    "# Stack #" .. stack.number .. " → " .. stack.base,
    "",
    gh_stack.summary(stack),
    "",
  }
  for i = #stack.entries, 1, -1 do
    local e = stack.entries[i]
    local text = entry_status(e, through)
    table.insert(lines, string.format(
      "%d. %s #%d %s (@%s) — %s",
      e.position, STATUS[e.status].icon, e.pr.number, util.crop_title(e.pr.title), e.pr.author, text
    ))
  end
  return lines
end

--- Show the list of stacks in `scope`.
---@param stacks GHReviewStack[]
---@param opts { scope: GHReviewScope, on_select: fun(stack: GHReviewStack), on_checkout: fun(stack: GHReviewStack), on_scope: fun(scope: GHReviewScope), on_own?: fun(stack: GHReviewStack, which: "first"|"last") }
---@return table? picker
function M.show_list(stacks, opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for the stack list", vim.log.levels.ERROR)
    return
  end

  local items = {}
  for _, stack in ipairs(stacks) do
    local top = stack.entries[#stack.entries]
    local words = { "#" .. stack.number, stack.base }
    for _, e in ipairs(stack.entries) do
      vim.list_extend(words, { "#" .. e.pr.number, e.pr.title, "@" .. e.pr.author })
    end
    local numbers = {}
    for _, e in ipairs(stack.entries) do table.insert(numbers, "#" .. e.pr.number .. " ") end
    table.insert(items, {
      text = table.concat(words, " "),
      -- Matched by a query that is a PR number (see `picker_util.pr_number_filter`).
      prs = table.concat(numbers),
      _stack = stack,
      _top_title = top and top.pr.title or "",
    })
  end

  local actions, keys = scope_mod.picker_actions(opts.on_scope, opts.scope)
  actions.checkout_stack = function(picker, item)
    if not item then return end
    picker:close()
    opts.on_checkout(item._stack)
  end
  local lhs = config.get().picker_keys.checkout
  if lhs and lhs ~= "" then
    keys[lhs] = { "checkout_stack", mode = { "i", "n" }, desc = "Checkout stack" }
  end
  if opts.on_own then
    local pk = config.get().picker_keys
    for which, own_lhs in pairs({ first = pk.first_mine, last = pk.last_mine }) do
      local name = "own_" .. which
      actions[name] = function(picker, item)
        if not item then return end
        picker:close()
        opts.on_own(item._stack, which)
      end
      if own_lhs and own_lhs ~= "" then
        keys[own_lhs] = { name, mode = { "i", "n" }, desc = "Review the " .. which .. " PR of mine in this stack" }
      end
    end
  end

  return Snacks.picker.pick({
    title = scope_mod.title("GitHub stacks", opts.scope),
    items = items,
    -- "123" or "#123" matches the stacks holding a PR whose number starts with 123.
    filter = picker_util.pr_number_filter(function(n) return "prs:'#" .. n end),
    actions = actions,
    win = { input = { keys = keys }, list = { keys = keys } },
    format = function(item)
      local stack = item._stack
      return {
        { "#" .. stack.number, "Number" },
        { "  " .. util.crop_title(item._top_title), "Normal" },
        { "  " .. #stack.entries .. " PRs → " .. stack.base .. " · " .. gh_stack.summary(stack), "Comment", virtual = true },
      }
    end,
    preview = function(ctx)
      if not ctx.item or not ctx.item._stack then return end
      ctx.preview:set_lines(M.describe(ctx.item._stack))
      ctx.preview:highlight({ ft = "markdown" })
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      opts.on_select(item._stack)
    end,
  })
end

--- Close the stack panel.
---@return boolean closed Whether a panel was open
function M.close_panel()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then return false end
  local pickers = Snacks.picker.get({ source = PANEL_SOURCE }) or {}
  for _, picker in ipairs(pickers) do picker:close() end
  return #pickers > 0
end

--- Title of the stack panel.
---@param stack GHReviewStack
---@return string
function M.panel_title(stack)
  return "GitHub stack #" .. stack.number .. " → " .. stack.base .. " · " .. gh_stack.summary(stack)
end

--- Show one stack: every PR top first with its merge status. The cursor opens on
--- the highest PR that can be merged, else on the PR under review. Entries are
--- read on every draw, so statuses applied later show after `picker_util.redraw`.
---@param stack GHReviewStack
---@param opts { current_pr?: number, on_review: fun(entry: GHReviewStackEntry), on_merge: fun(entry: GHReviewStackEntry), on_checkout: fun(), on_refresh: fun(), on_details: fun(entry: GHReviewStackEntry), on_own?: fun(which: "first"|"last") }
---@return table? picker
function M.show_panel(stack, opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for the stack panel", vim.log.levels.ERROR)
    return
  end
  picker_util.ensure_highlights()

  local focus = gh_stack.mergeable_through(stack)
  if not focus and opts.current_pr then
    for _, e in ipairs(stack.entries) do
      if e.pr.number == opts.current_pr then focus = e.position end
    end
  end

  local items = {}
  for i = #stack.entries, 1, -1 do
    local e = stack.entries[i]
    table.insert(items, {
      text = table.concat({ "#" .. e.pr.number, e.pr.title, e.pr.author, e.pr.head_ref }, " "),
      _entry = e,
      _is_current = e.pr.number == opts.current_pr,
      _focus = e.position == focus,
    })
  end

  local pk = config.get().picker_keys
  local keys = {}
  local function bind(lhs, action, desc)
    if lhs and lhs ~= "" then keys[lhs] = { action, desc = desc } end
  end
  bind(pk.merge, "merge_stack", "Merge up to this PR")
  bind(pk.checkout, "checkout_stack", "Checkout stack")
  bind("o", "checkout_stack", "Checkout stack")
  bind(pk.refresh, "refresh_stack", "Refresh")
  bind(pk.details, "pr_details", "Checks of this PR")
  if opts.on_own then
    bind(pk.first_mine, "own_first", "Review the first PR of mine in this stack")
    bind(pk.last_mine, "own_last", "Review the last PR of mine in this stack")
  end

  return Snacks.picker.pick({
    source = PANEL_SOURCE,
    title = M.panel_title(stack),
    items = items,
    focus = "list",
    -- The checks window opens on top; the panel must survive losing focus.
    auto_close = false,
    layout = { preset = "select", preview = false },
    on_show = function(picker)
      picker_util.focus_current(picker, function(item) return item._focus end)
    end,
    format = function(item)
      local e = item._entry
      local st = STATUS[e.status]
      local text, hl = entry_status(e, gh_stack.mergeable_through(stack))
      local entry_hl = item._is_current and picker_util.ACTIVE_ENTRY or nil
      return {
        { item._is_current and "> " or "  ", item._is_current and picker_util.ACTIVE or "SnacksPickerIdx" },
        { st.icon .. " ", st.hl },
        { "#" .. e.pr.number, entry_hl or "Number" },
        { " " .. util.crop_title(e.pr.title), entry_hl },
        { "  " .. text, hl, virtual = true },
        { "  @" .. e.pr.author, "Comment", virtual = true },
      }
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      opts.on_review(item._entry)
    end,
    actions = {
      merge_stack = function(picker, item)
        if not item then return end
        picker:close()
        opts.on_merge(item._entry)
      end,
      checkout_stack = function(picker)
        picker:close()
        opts.on_checkout()
      end,
      refresh_stack = function(picker)
        picker:close()
        opts.on_refresh()
      end,
      pr_details = function(_, item)
        if not item then return end
        opts.on_details(item._entry)
      end,
      own_first = function(picker)
        picker:close()
        opts.on_own("first")
      end,
      own_last = function(picker)
        picker:close()
        opts.on_own("last")
      end,
    },
    win = { list = { keys = keys } },
  })
end

return M
