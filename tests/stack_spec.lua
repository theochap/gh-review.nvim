---@module 'luassert'

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Build a jj stack commit record as vcs.jj_stack returns them.
local function jj_commit(id, description, bookmarks, author, when, change_id)
  return {
    commit_id = id,
    change_id = change_id or ("change-" .. id),
    description = description or "",
    bookmarks = bookmarks or {},
    author = author or "dev",
    when = when or "now",
  }
end

describe("stack", function()
  local stack_ui
  local picker_config
  local gh, orig_prs_by_head

  before_each(function()
    config.setup()
    state.clear()
    picker_config = nil

    -- Stub snacks.nvim
    package.loaded["snacks"] = {
      picker = {
        get = function() return {} end,
        pick = function(opts) picker_config = opts end,
      },
    }

    -- PR numbers are looked up in the background; never reach the real gh.
    gh = require("gh-review.gh")
    orig_prs_by_head = gh.prs_by_head
    gh.prs_by_head = function(_, cb) cb(nil, {}) end

    package.loaded["gh-review.ui.stack"] = nil
    stack_ui = require("gh-review.ui.stack")
  end)

  after_each(function()
    gh.prs_by_head = orig_prs_by_head
    package.loaded["snacks"] = nil
    package.loaded["gh-review.ui.stack"] = nil
  end)

  describe("close", function()
    it("reports nothing closed when no picker is open", function()
      assert.is_false(stack_ui.close())
    end)

    it("closes an open picker and reports it", function()
      local closed = false
      package.loaded["snacks"] = {
        picker = {
          get = function()
            return { { close = function() closed = true end } }
          end,
          pick = function(opts) picker_config = opts end,
        },
      }
      package.loaded["gh-review.ui.stack"] = nil
      stack_ui = require("gh-review.ui.stack")

      assert.is_true(stack_ui.close())
      assert.is_true(closed)
    end)

    it("reports nothing closed when snacks is missing", function()
      package.loaded["snacks"] = nil
      package.loaded["gh-review.ui.stack"] = nil
      stack_ui = require("gh-review.ui.stack")
      assert.is_false(stack_ui.close())
    end)
  end)

  describe("show", function()
    it("notifies when the stack is empty", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      stack_ui.show({}, { on_select = function() end })

      vim.notify = orig_notify
      assert.is_nil(picker_config)
      assert.is_truthy(notifications[1].msg:find("no commits"))
    end)

    it("notifies when snacks is not available", function()
      package.loaded["snacks"] = nil
      package.loaded["gh-review.ui.stack"] = nil
      stack_ui = require("gh-review.ui.stack")

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      stack_ui.show({ jj_commit("aaaa1111aaaa", "tip") }, { on_select = function() end })

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("snacks.nvim required"))
    end)

    it("builds searchable items from the stack", function()
      stack_ui.show({
        jj_commit("aaaa1111aaaa", "third change"),
        jj_commit("bbbb2222bbbb", "second change", { "pr-two" }, "grace"),
      }, { on_select = function() end })

      assert.are.equal("gh_review_stack", picker_config.source)
      assert.are.equal(2, #picker_config.items)
      assert.is_truthy(picker_config.items[1].text:find("aaaa1111"))
      assert.is_truthy(picker_config.items[1].text:find("third change"))
      assert.is_truthy(picker_config.items[2].text:find("pr%-two"))
      assert.is_truthy(picker_config.items[2].text:find("grace"))
      assert.is_falsy(picker_config.title:find("first"))
    end)

    it("marks the current commit and the ones belonging to the loaded PR", function()
      state.set_pr({
        number = 7, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_commits({
        { sha = "bbbb222", oid = "bbbb2222bbbb", message = "second change", author = "dev", date = "" },
      })

      stack_ui.show({
        jj_commit("aaaa1111aaaa", "third change"),
        jj_commit("bbbb2222bbbb", "second change", { "pr-two" }),
      }, { current_oid = "bbbb2222bbbb", on_select = function() end })

      assert.is_false(picker_config.items[1]._is_current)
      assert.is_nil(picker_config.items[1]._pr_number)
      assert.is_true(picker_config.items[2]._is_current)
      assert.are.equal(7, picker_config.items[2]._pr_number)
    end)

    it("marks the commit and the PR by change when the stack was rewritten locally", function()
      state.set_pr({
        number = 7, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      -- The PR's commits as pushed; a local amend replaced them, so none of these
      -- oids is in the stack any more
      state.set_commits({
        { sha = "pushed1", oid = "pushed1pushed1", message = "second change", author = "dev", date = "" },
      })

      stack_ui.show({
        jj_commit("aaaa1111aaaa", "third change", nil, nil, nil, "change-top"),
        jj_commit("bbbb2222bbbb", "second change", { "pr-two" }, nil, nil, "change-two"),
      }, {
        current_oid = "pushed1pushed1",
        current_change_id = "change-two",
        pr_change_ids = { ["change-two"] = true },
        on_select = function() end,
      })

      assert.is_false(picker_config.items[1]._is_current)
      assert.is_nil(picker_config.items[1]._pr_number)
      assert.is_true(picker_config.items[2]._is_current)
      assert.are.equal(7, picker_config.items[2]._pr_number)
    end)

    it("says so in the title when the stack was truncated", function()
      stack_ui.show({ jj_commit("aaaa1111aaaa", "tip") }, { truncated = true, on_select = function() end })
      assert.is_truthy(picker_config.title:find("from the tip"))
    end)

    it("highlights the whole entry of the commit under review and opens on it", function()
      local picker_util = require("gh-review.ui.picker_util")
      stack_ui.show({
        jj_commit("aaaa1111aaaa", "third change"),
        jj_commit("bbbb2222bbbb", "second change", { "pr-two" }),
      }, { current_oid = "bbbb2222bbbb", on_select = function() end })

      local formatted = picker_config.format(picker_config.items[2])
      assert.are.equal(picker_util.ACTIVE, formatted[1][2])
      for i = 2, #formatted do
        assert.are.equal(picker_util.ACTIVE_ENTRY, formatted[i][2])
      end
      -- Ordinary entries keep their own highlights
      assert.are.equal("Number", picker_config.format(picker_config.items[1])[2][2])
      assert.are.equal("Identifier", picker_config.format(picker_config.items[1])[4][2])

      local viewed
      picker_config.on_show({
        items = function() return picker_config.items end,
        list = { view = function(_, idx) viewed = idx end },
      })
      assert.are.equal(2, viewed)
    end)

    it("formats an entry with the short id, description, bookmarks and author", function()
      state.set_pr({
        number = 7, title = "T", author = "a", base_ref = "m",
        head_ref = "f", url = "", body = "", review_decision = "", repository = "o/r",
      })
      state.set_commits({
        { sha = "aaaa111", oid = "aaaa1111aaaa", message = "tip", author = "dev", date = "" },
      })

      stack_ui.show(
        { jj_commit("aaaa1111aaaa", "tip", { "pr-two" }, "grace", "2 hours ago") },
        { current_oid = "aaaa1111aaaa", on_select = function() end }
      )

      local formatted = picker_config.format(picker_config.items[1])
      assert.are.equal("> ", formatted[1][1])
      assert.are.equal(require("gh-review.ui.picker_util").ACTIVE, formatted[1][2])
      -- PR number first, its place in the stack, then id and title.
      assert.are.equal("#7     ", formatted[2][1])
      assert.are.equal("aaaa1111", formatted[4][1])
      assert.are.equal(" tip", formatted[5][1])

      local rendered = table.concat(vim.tbl_map(function(part) return part[1] end, formatted), "")
      assert.is_truthy(rendered:find("pr%-two"))
      assert.is_truthy(rendered:find("#7"))
      assert.is_truthy(rendered:find("@grace 2 hours ago"))
    end)

    it("falls back to a placeholder when a commit has no description", function()
      stack_ui.show({ jj_commit("aaaa1111aaaa", "") }, { on_select = function() end })
      local formatted = picker_config.format(picker_config.items[1])
      assert.are.equal("  ", formatted[1][1])
      assert.is_truthy(formatted[5][1]:find("no description"))
    end)

    it("closes the picker and hands the commit to on_select on confirm", function()
      local selected, closed = nil, false
      stack_ui.show({ jj_commit("aaaa1111aaaa", "tip") }, {
        on_select = function(commit) selected = commit end,
      })

      picker_config.confirm({ close = function() closed = true end }, picker_config.items[1])

      assert.is_true(closed)
      assert.are.equal("aaaa1111aaaa", selected.commit_id)
    end)

    it("ignores confirm without an item", function()
      local calls = 0
      stack_ui.show({ jj_commit("aaaa1111aaaa", "tip") }, {
        on_select = function() calls = calls + 1 end,
      })
      picker_config.confirm({ close = function() end }, nil)
      assert.are.equal(0, calls)
    end)

    it("binds x to clearing the commit filter", function()
      stack_ui.show({ jj_commit("aaaa1111aaaa", "tip") }, { on_select = function() end })
      assert.are.equal("clear_commit", picker_config.win.input.keys["x"][1])
      assert.are.equal("clear_commit", picker_config.win.list.keys["x"][1])
      assert.is_function(picker_config.actions.clear_commit)
    end)
  end)

  describe("PR numbers and positions", function()
    local stack = {
      jj_commit("aaaa1111aaaa", "unpushed"),
      jj_commit("bbbb2222bbbb", "top of two", { "two" }),
      jj_commit("cccc3333cccc", "bottom of two"),
      jj_commit("dddd4444dddd", "one", { "one" }),
    }

    it("groups commits under the nearest bookmark at or above them", function()
      assert.are.same({ [2] = { "two" }, [3] = { "two" }, [4] = { "one" } }, stack_ui.pr_heads(stack))
    end)

    it("looks the PRs up by branch and numbers them in their native stack", function()
      local asked
      gh.prs_by_head = function(branches, cb) asked = branches; cb(nil, { one = 10, two = 11 }) end
      gh.repo_name = function(cb) cb(nil, "o/r") end
      local graphql = require("gh-review.graphql")
      local orig_fetch = graphql.fetch_pr_stack
      graphql.fetch_pr_stack = function(_, _, number, cb)
        assert.are.equal(10, number)
        cb(nil, { number = 3, size = 5, entries = { nodes = {
          { position = 2, pullRequest = { number = 10 } },
          { position = 3, pullRequest = { number = 11 } },
        } } })
      end
      local redrawn = 0
      local picker_util = require("gh-review.ui.picker_util")
      local orig_redraw = picker_util.redraw
      picker_util.redraw = function() redrawn = redrawn + 1 end

      stack_ui.show(stack, { on_select = function() end })

      graphql.fetch_pr_stack = orig_fetch
      picker_util.redraw = orig_redraw
      assert.are.same({ "two", "one" }, asked)
      local items = picker_config.items
      assert.is_nil(items[1]._pr_number)
      assert.are.same({ 11, "3/5" }, { items[2]._pr_number, items[2]._pr_position })
      assert.are.same({ 11, "3/5" }, { items[3]._pr_number, items[3]._pr_position })
      assert.are.same({ 10, "2/5" }, { items[4]._pr_number, items[4]._pr_position })
      assert.are.equal(1, redrawn)
      local row = table.concat(vim.tbl_map(function(p) return p[1] end, picker_config.format(items[2])), "")
      assert.is_truthy(row:find("#11    3/5   bbbb2222 top of two", 1, true))
      assert.is_truthy(items[2].text:find("#11", 1, true))
    end)

    it("falls back to the order in the jj stack without a native stack", function()
      gh.prs_by_head = function(_, cb) cb(nil, { one = 10, two = 11 }) end
      gh.repo_name = function(cb) cb(nil, "o/r") end
      local graphql = require("gh-review.graphql")
      local orig_fetch = graphql.fetch_pr_stack
      graphql.fetch_pr_stack = function(_, _, _, cb) cb(nil, nil) end
      stack_ui.show(stack, { on_select = function() end })
      graphql.fetch_pr_stack = orig_fetch
      assert.are.equal("2/2", picker_config.items[2]._pr_position)
      assert.are.equal("1/2", picker_config.items[4]._pr_position)
    end)

    it("crops long descriptions like the PR list", function()
      config.setup({ title_max_length = 10 })
      stack_ui.show({ jj_commit("aaaa1111aaaa", "a very long commit description") }, { on_select = function() end })
      assert.are.equal(" a very lo…", picker_config.format(picker_config.items[1])[5][1])
    end)
  end)
end)
