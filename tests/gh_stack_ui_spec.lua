---@module 'luassert'

local config = require("gh-review.config")
local gh_stack = require("gh-review.gh_stack")

--- Build a parsed stack from { number, overrides } pairs, bottom first
local function make_stack(prs)
  local nodes = {}
  for i, p in ipairs(prs) do
    table.insert(nodes, {
      position = i,
      pullRequest = vim.tbl_extend("force", {
        number = p[1],
        title = "PR " .. p[1],
        state = "OPEN",
        isDraft = false,
        author = { login = "dev" },
        headRefName = "b" .. p[1],
        mergeable = "MERGEABLE",
        mergeStateStatus = "CLEAN",
        reviewDecision = "APPROVED",
        statusCheckRollup = { state = "SUCCESS" },
      }, p[2] or {}),
    })
  end
  local stack = gh_stack.parse_stack({ number = 4, size = #prs, baseRefName = "main", entries = { nodes = nodes } })
  local statuses = {}
  for _, n in ipairs(nodes) do statuses[n.pullRequest.number] = gh_stack.parse_status(n.pullRequest) end
  gh_stack.apply_statuses(stack, statuses)
  return stack
end

--- Concatenate the text of formatted picker parts
local function text_of(parts)
  return table.concat(vim.tbl_map(function(p) return p[1] end, parts), "")
end

describe("ui.gh_stack", function()
  local ui, picker_config, open_pickers

  before_each(function()
    config.setup()
    picker_config = nil
    open_pickers = {}
    package.loaded["snacks"] = {
      picker = {
        pick = function(opts) picker_config = opts end,
        get = function() return open_pickers end,
        actions = {},
      },
    }
    package.loaded["gh-review.ui.gh_stack"] = nil
    ui = require("gh-review.ui.gh_stack")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
  end)

  local function mock_picker()
    local p = { closed = false }
    p.close = function() p.closed = true end
    return p
  end

  describe("describe", function()
    it("lists PRs top first with their status", function()
      local lines = ui.describe(make_stack({ { 1, { state = "MERGED" } }, { 2 }, { 3, { isDraft = true } } }))
      assert.are.equal("# Stack #4 → main", lines[1])
      assert.is_truthy(lines[5]:find("^3%. ✗ #3 PR 3 %(@dev%) — draft"))
      assert.is_truthy(lines[6]:find("#2 .* — mergeable"))
      assert.is_truthy(lines[7]:find("#1 .* — merged"))
    end)
  end)

  describe("show_panel", function()
    it("lists entries top first and focuses the highest mergeable PR", function()
      local stack = make_stack({ { 1 }, { 2 }, { 3, { isDraft = true } } })
      ui.show_panel(stack, {
        current_pr = 3,
        on_review = function() end,
        on_merge = function() end,
        on_checkout = function() end,
        on_refresh = function() end,
        on_details = function() end,
      })
      assert.are.equal("gh_review_gh_stack", picker_config.source)
      assert.are.equal("list", picker_config.focus)
      assert.are.same({ 3, 2, 1 }, vim.tbl_map(function(i) return i._entry.pr.number end, picker_config.items))
      assert.is_true(picker_config.items[2]._focus)
      assert.is_true(picker_config.items[1]._is_current)
      assert.is_truthy(picker_config.title:find("mergeable through #2", 1, true))
    end)

    it("formats status, blockers and the current marker", function()
      local stack = make_stack({ { 1, { isDraft = true } }, { 2 } })
      ui.show_panel(stack, {
        current_pr = 1,
        on_review = function() end,
        on_merge = function() end,
        on_checkout = function() end,
        on_refresh = function() end,
        on_details = function() end,
      })
      local top = text_of(picker_config.format(picker_config.items[1]))
      local bottom = text_of(picker_config.format(picker_config.items[2]))
      assert.is_truthy(top:find("ready, waits on PRs below", 1, true))
      assert.is_truthy(bottom:find("^> ✗ #1 PR 1  draft"))
    end)

    it("falls back to the current PR when nothing can merge", function()
      local stack = make_stack({ { 1, { isDraft = true } }, { 2 } })
      ui.show_panel(stack, {
        current_pr = 2,
        on_review = function() end,
        on_merge = function() end,
        on_checkout = function() end,
        on_refresh = function() end,
        on_details = function() end,
      })
      assert.is_true(picker_config.items[1]._focus)
    end)

    it("wires review, merge, checkout and refresh", function()
      local calls = {}
      local stack = make_stack({ { 1 }, { 2 } })
      ui.show_panel(stack, {
        on_review = function(e) calls.review = e.pr.number end,
        on_merge = function(e) calls.merge = e.position end,
        on_checkout = function() calls.checkout = true end,
        on_refresh = function() calls.refresh = true end,
        on_details = function(e) calls.details = e.pr.number end,
      })
      local keys = picker_config.win.list.keys
      assert.are.equal("merge_stack", keys["M"][1])
      assert.are.equal("checkout_stack", keys["o"][1])
      assert.are.equal("checkout_stack", keys["<c-o>"][1])
      assert.are.equal("refresh_stack", keys["R"][1])

      local p = mock_picker()
      picker_config.confirm(p, picker_config.items[1])
      assert.is_true(p.closed)
      picker_config.actions.merge_stack(mock_picker(), picker_config.items[1])
      picker_config.actions.checkout_stack(mock_picker())
      picker_config.actions.refresh_stack(mock_picker())
      local kept = mock_picker()
      picker_config.actions.pr_details(kept, picker_config.items[2])
      assert.is_false(kept.closed)
      assert.are.equal("pr_details", keys["d"][1])
      assert.is_false(picker_config.auto_close)
      assert.are.same({ review = 2, merge = 2, checkout = true, refresh = true, details = 1 }, calls)
    end)
  end)

  describe("loading entries", function()
    it("show a loading marker until statuses arrive, then redraw with them", function()
      local stack = gh_stack.parse_stack({ number = 4, size = 1, baseRefName = "main", entries = { nodes = {
        { position = 1, pullRequest = { number = 1, title = "PR 1", state = "OPEN", author = { login = "dev" }, headRefOid = "h" } },
      } } })
      ui.show_panel(stack, {
        on_review = function() end, on_merge = function() end, on_checkout = function() end,
        on_refresh = function() end, on_details = function() end,
      })
      assert.is_truthy(text_of(picker_config.format(picker_config.items[1])):find("… #1 PR 1  loading…", 1, true))
      gh_stack.apply_statuses(stack, { [1] = { head_oid = "h", checks = "SUCCESS", mergeable = "MERGEABLE", merge_state = "CLEAN" } })
      assert.is_truthy(text_of(picker_config.format(picker_config.items[1])):find("mergeable", 1, true))
      assert.is_truthy(ui.panel_title(stack):find("mergeable through #1", 1, true))
    end)
  end)

  describe("long titles", function()
    it("are cropped in panel rows, list rows and the preview, but not in search text", function()
      config.setup({ title_max_length = 8 })
      local stack = make_stack({ { 1, { title = "A very long pull request title" } } })
      ui.show_panel(stack, {
        on_review = function() end, on_merge = function() end, on_checkout = function() end,
        on_refresh = function() end, on_details = function() end,
      })
      assert.is_truthy(text_of(picker_config.format(picker_config.items[1])):find(" A very …", 1, true))
      assert.is_truthy(picker_config.items[1].text:find("A very long pull request title", 1, true))
      assert.is_truthy(ui.describe(stack)[5]:find("#1 A very … (@dev)", 1, true))

      ui.show_list({ stack }, {
        scope = { kind = "all" }, on_select = function() end, on_checkout = function() end, on_scope = function() end,
      })
      assert.is_truthy(text_of(picker_config.format(picker_config.items[1])):find("#4  A very …", 1, true))
    end)
  end)

  describe("close_panel", function()
    it("closes open panels and reports whether any was open", function()
      assert.is_false(ui.close_panel())
      local p = mock_picker()
      open_pickers = { p }
      assert.is_true(ui.close_panel())
      assert.is_true(p.closed)
    end)
  end)

  describe("show_list", function()
    it("shows one item per stack and wires select, checkout and scope keys", function()
      local calls = {}
      local stacks = { make_stack({ { 1 }, { 2 } }) }
      ui.show_list(stacks, {
        scope = { kind = "mine" },
        on_select = function(s) calls.select = s.number end,
        on_checkout = function(s) calls.checkout = s.number end,
        on_scope = function(s) calls.scope = s.kind end,
      })
      assert.are.equal("GitHub stacks — mine  (<a-s> filters)", picker_config.title)
      assert.are.equal(1, #picker_config.items)
      assert.is_truthy(picker_config.items[1].text:find("#1 PR 1 @dev #2 PR 2", 1, true))
      local formatted = text_of(picker_config.format(picker_config.items[1]))
      assert.is_truthy(formatted:find("#4  PR 2  2 PRs → main", 1, true))

      picker_config.confirm(mock_picker(), picker_config.items[1])
      picker_config.actions.checkout_stack(mock_picker(), picker_config.items[1])
      picker_config.actions.scope_all(mock_picker())
      assert.are.same({ select = 4, checkout = 4, scope = "all" }, calls)
      assert.are.equal("checkout_stack", picker_config.win.input.keys["<c-o>"][1])
    end)

    it("finds stacks by the number of a PR they hold", function()
      ui.show_list({ make_stack({ { 12 }, { 13 } }) }, {
        scope = { kind = "all" },
        on_select = function() end,
        on_checkout = function() end,
        on_scope = function() end,
      })
      assert.are.equal("#12 #13 ", picker_config.items[1].prs)
      local f = { pattern = "#12" }
      picker_config.filter.transform(nil, f)
      assert.are.equal("prs:'#12", f.pattern)
    end)

    it("previews the stack", function()
      ui.show_list({ make_stack({ { 1 } }) }, {
        scope = { kind = "all" },
        on_select = function() end,
        on_checkout = function() end,
        on_scope = function() end,
      })
      local set
      picker_config.preview({
        item = picker_config.items[1],
        preview = { set_lines = function(_, l) set = l end, highlight = function() end },
      })
      assert.are.equal("# Stack #4 → main", set[1])
    end)
  end)

  describe("first and last PR of mine", function()
    it("binds the keys in the stack list", function()
      local got = {}
      ui.show_list({ make_stack({ { 1 }, { 2 } }) }, {
        scope = { kind = "all" },
        on_select = function() end,
        on_checkout = function() end,
        on_scope = function() end,
        on_own = function(stack, which) table.insert(got, stack.number .. which) end,
      })
      assert.are.equal("own_first", picker_config.win.input.keys["<a-f>"][1])
      assert.are.equal("own_last", picker_config.win.input.keys["<a-l>"][1])
      picker_config.actions.own_first(mock_picker(), picker_config.items[1])
      picker_config.actions.own_last(mock_picker(), picker_config.items[1])
      assert.are.same({ "4first", "4last" }, got)
    end)

    it("binds the keys in the stack panel", function()
      local got = {}
      ui.show_panel(make_stack({ { 1 } }), {
        on_review = function() end,
        on_merge = function() end,
        on_checkout = function() end,
        on_refresh = function() end,
        on_details = function() end,
        on_own = function(which) table.insert(got, which) end,
      })
      assert.are.equal("own_first", picker_config.win.list.keys["<a-f>"][1])
      picker_config.actions.own_first(mock_picker())
      picker_config.actions.own_last(mock_picker())
      assert.are.same({ "first", "last" }, got)
    end)
  end)
end)
