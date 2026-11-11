---@module 'luassert'

local config = require("gh-review.config")

describe("scope", function()
  local scope

  before_each(function()
    config.setup()
    package.loaded["gh-review.scope"] = nil
    scope = require("gh-review.scope")
  end)

  describe("parse", function()
    it("defaults to all", function()
      assert.are.same({ kind = "all" }, scope.parse(nil))
    end)

    it("parses simple kinds", function()
      assert.are.same({ kind = "mine" }, scope.parse({ "mine" }))
      assert.are.same({ kind = "review" }, scope.parse({ "review" }))
    end)

    it("parses author with login and strips @", function()
      assert.are.same({ kind = "author", login = "alice" }, scope.parse({ "author", "@alice" }))
    end)

    it("rejects author without login", function()
      local s, err = scope.parse({ "author" })
      assert.is_nil(s)
      assert.is_truthy(err:find("needs a login"))
    end)

    it("rejects unknown kinds", function()
      local s, err = scope.parse({ "bogus" })
      assert.is_nil(s)
      assert.is_truthy(err:find("unknown scope"))
    end)
  end)

  describe("search_terms", function()
    it("maps each kind to search qualifiers", function()
      assert.are.same({ "" }, scope.search_terms({ kind = "all" }))
      assert.are.same({ "author:@me" }, scope.search_terms({ kind = "mine" }))
      assert.are.same({ "author:bob" }, scope.search_terms({ kind = "author", login = "bob" }))
    end)

    it("splits review into requested and reviewed, excluding my PRs", function()
      assert.are.same(
        { "review-requested:@me -author:@me", "reviewed-by:@me -author:@me", "assignee:@me -author:@me" },
        scope.search_terms({ kind = "review" })
      )
    end)
  end)

  describe("label", function()
    it("describes each kind", function()
      assert.are.equal("all open", scope.label({ kind = "all" }))
      assert.are.equal("mine", scope.label({ kind = "mine" }))
      assert.are.equal("author @bob", scope.label({ kind = "author", login = "bob" }))
      assert.is_truthy(scope.label({ kind = "review" }):find("review"))
    end)
  end)

  describe("merge_results", function()
    it("keeps a single list as is", function()
      local list = { { number = 1 }, { number = 5 } }
      assert.are.equal(list, scope.merge_results({ list }))
    end)

    it("dedupes and sorts several lists newest first", function()
      local merged = scope.merge_results({
        { { number = 3, src = "a" }, { number = 1 } },
        { { number = 3, src = "b" }, { number = 7 } },
      })
      assert.are.same({ 7, 3, 1 }, vim.tbl_map(function(p) return p.number end, merged))
      assert.are.equal("a", merged[2].src)
    end)
  end)

  describe("fetch_all", function()
    it("runs one fetch per term and merges", function()
      local terms = {}
      local result
      scope.fetch_all({ kind = "review" }, function(term, cb)
        table.insert(terms, term)
        cb(nil, { { number = #terms } })
      end, function(err, prs)
        assert.is_nil(err)
        result = prs
      end)
      assert.are.equal(3, #terms)
      assert.are.same({ 3, 2, 1 }, vim.tbl_map(function(p) return p.number end, result))
    end)

    it("reports the first error once", function()
      local calls = 0
      scope.fetch_all({ kind = "review" }, function(_, cb)
        cb("boom", nil)
      end, function(err)
        calls = calls + 1
        assert.are.equal("boom", err)
      end)
      assert.are.equal(1, calls)
    end)
  end)

  describe("picker_actions", function()
    it("binds the configured keys and reopens with the new scope", function()
      local reopened
      local actions, keys = scope.picker_actions(function(s) reopened = s end)
      assert.are.equal("scope_mine", keys["<a-m>"][1])
      assert.are.equal("scope_all", keys["<a-a>"][1])
      local closed = false
      actions.scope_mine({ close = function() closed = true end })
      assert.is_true(closed)
      assert.are.same({ kind = "mine" }, reopened)
    end)

    it("prompts for the author login", function()
      local reopened
      local orig = vim.ui.input
      vim.ui.input = function(_, cb) cb(" @carol ") end
      local actions = scope.picker_actions(function(s) reopened = s end)
      actions.scope_author({ close = function() end })
      vim.ui.input = orig
      assert.are.same({ kind = "author", login = "carol" }, reopened)
    end)

    it("skips keys set to empty", function()
      config.setup({ picker_keys = { scope_mine = "" } })
      local _, keys = scope.picker_actions(function() end)
      for _, v in pairs(keys) do
        assert.are_not.equal("scope_mine", v[1])
      end
    end)
  end)

  describe("filters", function()
    it("parses qualifiers after the scope, or alone", function()
      local s = scope.parse({ "review", "author:alice", "draft:false" })
      assert.are.equal("review", s.kind)
      assert.are.same({ "author", "status" }, vim.tbl_map(function(f) return f.kind end, s.filters))
      assert.are.equal("ready for review", s.filters[2].text)
      local only = scope.parse({ "review:required" })
      assert.are.equal("all", only.kind)
      assert.are.equal("review required", only.filters[1].text)
      local by = scope.parse({ "author", "bob", "label:bug" })
      assert.are.equal("bob", by.login)
      assert.are.equal("label", by.filters[1].kind)
    end)

    it("rejects words that are not qualifiers, and an author scope without a login", function()
      local s, err = scope.parse({ "review", "alice" })
      assert.is_nil(s)
      assert.is_truthy(err:find("search qualifier", 1, true))
      s, err = scope.parse({ "author", "draft:false" })
      assert.is_nil(s)
      assert.is_truthy(err:find("needs a login", 1, true))
    end)

    it("adds filters to every search term and to the label", function()
      local s = scope.with_filter({ kind = "review" }, { kind = "review", qualifier = "review:required", text = "review required" })
      assert.are.same({
        "review-requested:@me -author:@me review:required",
        "reviewed-by:@me -author:@me review:required",
        "assignee:@me -author:@me review:required",
      }, scope.search_terms(s))
      assert.are.equal("review requested, reviewed or assigned to me · review required", scope.label(s))
      assert.are.same({ "draft:true" }, scope.search_terms(scope.parse({ "draft:true" })))
    end)

    it("replaces a filter of the same kind, but stacks custom ones", function()
      local s = scope.parse({ "review:required" })
      s = scope.with_filter(s, scope.filter_from_qualifier("review:approved"))
      assert.are.same({ "review:approved" }, vim.tbl_map(function(f) return f.qualifier end, s.filters))
      s = scope.with_filter(s, scope.filter_from_qualifier("sort:updated-desc"))
      s = scope.with_filter(s, scope.filter_from_qualifier("in:title"))
      assert.are.equal(3, #s.filters)
      assert.are.same({ kind = "all", filters = {} }, scope.without_filters({ kind = "all", filters = s.filters }))
    end)

    it("maps known qualifiers to their kind and menu text", function()
      assert.are.same({ kind = "my_review", qualifier = "-reviewed-by:@me", text = "not reviewed by me" },
        scope.filter_from_qualifier("-reviewed-by:@me"))
      assert.are.same({ kind = "checks", qualifier = "status:failure", text = "checks failing" },
        scope.filter_from_qualifier("status:failure"))
      assert.are.same({ kind = "base", qualifier = "base:develop", text = "base:develop" },
        scope.filter_from_qualifier("base:develop"))
    end)

    it("prompts for a fixed choice or a free value", function()
      local orig_select, orig_input = vim.ui.select, vim.ui.input
      local picks = { "Checks", "checks failing" }
      vim.ui.select = function(items, opts, cb)
        local want = table.remove(picks, 1)
        for _, it in ipairs(items) do
          if opts.format_item(it) == want then return cb(it) end
        end
        cb(nil)
      end
      local got
      scope.prompt_filter({ kind = "mine" }, function(s) got = s end)
      assert.are.equal("mine", got.kind)
      assert.are.same({ "status:failure" }, vim.tbl_map(function(f) return f.qualifier end, got.filters))

      picks = { "Label" }
      vim.ui.input = function(_, cb) cb(" needs review ") end
      scope.prompt_filter(got, function(s) got = s end)
      assert.are.equal('label:"needs review"', got.filters[2].qualifier)
      assert.are.equal("mine · checks failing · label needs review", scope.label(got))

      picks = { "Author" }
      vim.ui.input = function(_, cb) cb("@carol") end
      scope.prompt_filter({ kind = "all" }, function(s) got = s end)
      assert.are.equal("author:carol", got.filters[1].qualifier)

      local called = false
      picks = {}
      scope.prompt_filter({ kind = "all" }, function() called = true end)
      assert.is_false(called)
      vim.ui.select, vim.ui.input = orig_select, orig_input
    end)

    it("picker keys add and clear filters, and scope switches keep them", function()
      local current = scope.parse({ "review", "draft:false" })
      local reopened
      local actions, keys = scope.picker_actions(function(s) reopened = s end, current)
      assert.are.equal("add_filter", keys["<a-s>"][1])
      assert.are.equal("clear_filters", keys["<a-x>"][1])
      local p = { close = function() end }
      actions.scope_mine(p)
      assert.are.equal("mine", reopened.kind)
      assert.are.equal("draft:false", reopened.filters[1].qualifier)
      actions.clear_filters(p)
      assert.are.same({}, reopened.filters)
      assert.are.equal("review", reopened.kind)
      local orig = vim.ui.select
      vim.ui.select = function(items, opts, cb)
        if opts.prompt == "Filter PRs by" then return cb(items[2]) end -- Status
        cb(items[2]) -- draft
      end
      actions.add_filter(p)
      vim.ui.select = orig
      assert.are.same({ "draft:true" }, vim.tbl_map(function(f) return f.qualifier end, reopened.filters))
    end)
  end)

  describe("filter manager", function()
    local approved = { kind = "review", qualifier = "review:approved", text = "approved" }
    local label = { kind = "label", qualifier = "label:bug", text = "label bug" }

    it("lists the active filters first, then the choices the scope lacks", function()
      local options = scope.filter_options({ kind = "all", filters = { approved, label } })
      assert.are.same({ label = "Review decision: approved", active = true, filter = approved }, options[1])
      assert.are.same({ label = "Label: label bug", active = true, filter = label }, options[2])
      local labels = vim.tbl_map(function(o) return o.label end, options)
      assert.is_truthy(vim.tbl_contains(labels, "Status: draft"))
      assert.is_false(vim.tbl_contains(vim.list_slice(labels, 3), "Review decision: approved"))
      assert.is_truthy(vim.tbl_contains(labels, "Author: enter a value…"))
      assert.is_truthy(vim.tbl_contains(labels, "Search qualifier: enter a value…"))
    end)

    it("removes the active options picked and adds the others, in one go", function()
      local base = { kind = "mine", filters = { approved, label } }
      local options = scope.filter_options(base)
      local picked = {}
      for _, o in ipairs(options) do
        if o.label == "Review decision: approved" or o.label == "Label: label bug"
          or o.label == "Status: draft" or o.label == "Base branch: enter a value…" then
          table.insert(picked, o)
        end
      end
      local new, prompts = scope.toggle_filters(base, picked)
      assert.are.same({ kind = "mine", filters = { { kind = "status", qualifier = "draft:true", text = "draft" } } }, new)
      assert.are.equal(1, #prompts)
      assert.are.equal("base", prompts[1].kind)
      -- The scope passed in is left as it was.
      assert.are.equal(2, #base.filters)
    end)

    it("asks the values in turn, skipping empty answers", function()
      local defs = {}
      for _, def in ipairs(scope.FILTERS) do
        if def.kind == "author" or def.kind == "label" then table.insert(defs, def) end
      end
      local answers = { "@alice", "" }
      local orig = vim.ui.input
      vim.ui.input = function(_, cb) cb(table.remove(answers, 1)) end
      local got
      scope.prompt_values({ kind = "all" }, defs, function(s) got = s end)
      vim.ui.input = orig
      assert.are.same({ kind = "all", filters = { { kind = "author", qualifier = "author:alice", text = "by @alice" } } }, got)
    end)

    it("names the filter keys in picker titles", function()
      assert.are.equal("PRs — all open  (<a-s> filters)", scope.title("PRs", { kind = "all" }))
      assert.are.equal(
        "PRs — all open · approved  (<a-s> filters · <a-x> clear)",
        scope.title("PRs", { kind = "all", filters = { approved } })
      )
    end)

    it("opens the filter manager from the add filter key", function()
      local shown
      package.loaded["gh-review.ui.filters"] = { show = function(s, cb) shown = { scope = s, cb = cb } end }
      local reopened
      local actions = scope.picker_actions(function(s) reopened = s end, { kind = "mine", filters = { approved } })
      actions.add_filter({ close = function() end })
      package.loaded["gh-review.ui.filters"] = nil
      assert.are.same({ kind = "mine", filters = { approved } }, shown.scope)
      shown.cb({ kind = "mine" })
      assert.are.same({ kind = "mine" }, reopened)
    end)
  end)
end)
