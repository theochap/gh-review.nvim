---@module 'luassert'

local config = require("gh-review.config")

describe("pr_picker", function()
  local pr_picker, gh
  local picker_config

  before_each(function()
    config.setup()
    picker_config = nil

    -- Stub snacks.nvim
    package.loaded["snacks"] = {
      picker = {
        pick = function(opts) picker_config = opts end,
      },
    }

    package.loaded["gh-review.gh"] = nil
    package.loaded["gh-review.ui.pr_picker"] = nil
    gh = require("gh-review.gh")
    -- The background review query must never reach the real gh.
    gh.pr_review_states = function(cb) cb(nil, {}) end
    gh.pr_stacks = function(cb) cb(nil, {}) end
    pr_picker = require("gh-review.ui.pr_picker")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
  end)

  describe("show", function()
    it("notifies when snacks not available", function()
      package.loaded["snacks"] = nil
      package.loaded["gh-review.ui.pr_picker"] = nil
      pr_picker = require("gh-review.ui.pr_picker")

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      assert.is_truthy(notifications[1].msg:find("snacks.nvim required"))
    end)

    it("shows error when pr_list fails", function()
      gh.pr_list = function(cb) cb("network error", nil) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("failed to list PRs") then found = true end
      end
      assert.is_true(found)
    end)

    it("shows info when no PRs found", function()
      gh.pr_list = function(cb) cb(nil, {}) end

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

      pr_picker.show({ on_select = function() end })

      vim.notify = orig_notify
      local found = false
      for _, n in ipairs(notifications) do
        if n.msg:find("no open PRs found") then found = true end
      end
      assert.is_true(found)
    end)

    it("builds picker items from PR list", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Add feature", author = { login = "dev1" },
            body = "Description", state = "OPEN", headRefName = "feature",
            isDraft = false, createdAt = "2024-01-15T10:00:00Z", reviewDecision = "APPROVED",
          },
          {
            number = 11, title = "Fix bug", author = { login = "dev2" },
            body = "", state = "OPEN", headRefName = "bugfix",
            isDraft = true, createdAt = "2024-01-16T10:00:00Z", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      assert.is_not_nil(picker_config)
      assert.are.equal(2, #picker_config.items)

      -- First PR
      assert.is_truthy(picker_config.items[1].text:find("#10"))
      assert.is_truthy(picker_config.items[1].text:find("Add feature"))
      assert.are.equal("dev1", picker_config.items[1]._author)
      assert.are.equal("", picker_config.items[1]._draft)

      -- Second PR (draft)
      assert.is_truthy(picker_config.items[2].text:find("#11"))
      assert.are.equal("[DRAFT] ", picker_config.items[2]._draft)
    end)

    it("format function produces expected output", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Test PR", author = { login = "dev" },
            body = "", state = "OPEN", headRefName = "feat",
            isDraft = false, createdAt = "2024-01-15T10:00:00Z", reviewDecision = "APPROVED",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local item = picker_config.items[1]
      local formatted = picker_config.format(item)
      assert.is_table(formatted)
      assert.are.equal("#10", formatted[1][1])
      assert.are.equal("Test PR", formatted[4][1])
    end)

    it("confirm calls on_select with PR number", function()
      local selected_number
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 42, title = "Test", author = { login = "dev" },
            body = "", state = "OPEN", headRefName = "feat",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function(n) selected_number = n end })

      local mock_picker = { close = function() end }
      picker_config.confirm(mock_picker, picker_config.items[1])

      assert.are.equal(42, selected_number)
    end)

    it("confirm does nothing with nil item", function()
      gh.pr_list = function(cb)
        cb(nil, { { number = 1, title = "", author = { login = "" }, body = "", state = "", headRefName = "", isDraft = false, createdAt = "", reviewDecision = "" } })
      end

      local called = false
      pr_picker.show({ on_select = function() called = true end })

      local mock_picker = { close = function() end }
      picker_config.confirm(mock_picker, nil)

      assert.is_false(called)
    end)

    it("handles PR with nil author", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 5, title = "No Author", author = nil,
            body = "", state = "OPEN", headRefName = "branch",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      assert.are.equal("unknown", picker_config.items[1]._author)
    end)

    it("preview function generates markdown content", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 10, title = "Feature PR", author = { login = "dev" },
            body = "PR description here", state = "OPEN", headRefName = "feature-branch",
            isDraft = false, createdAt = "2024-03-15T10:00:00Z", reviewDecision = "APPROVED",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      -- Call preview function
      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("#10"))
      assert.is_truthy(text:find("Feature PR"))
      assert.is_truthy(text:find("@dev"))
      assert.is_truthy(text:find("feature%-branch"))
      assert.is_truthy(text:find("APPROVED"))
      assert.is_truthy(text:find("PR description here"))
    end)

    it("preview shows 'No description' for empty body", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 1, title = "T", author = { login = "d" },
            body = "", state = "OPEN", headRefName = "b",
            isDraft = false, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("No description"))
    end)

    it("preview handles draft PR", function()
      gh.pr_list = function(cb)
        cb(nil, {
          {
            number = 1, title = "Draft", author = { login = "d" },
            body = "", state = "OPEN", headRefName = "b",
            isDraft = true, createdAt = "", reviewDecision = "",
          },
        })
      end

      pr_picker.show({ on_select = function() end })

      local preview_lines = {}
      local ctx = {
        item = picker_config.items[1],
        preview = {
          set_lines = function(_, lines) preview_lines = lines end,
          highlight = function() end,
        },
      }
      picker_config.preview(ctx)

      local text = table.concat(preview_lines, "\n")
      assert.is_truthy(text:find("Draft.*yes"))
    end)
  end)

  describe("scopes", function()
    local function pr(n)
      return { number = n, title = "T" .. n, author = { login = "d" }, body = "", isDraft = false }
    end

    it("defaults to all open PRs with no search and keeps the old title", function()
      local searches = {}
      gh.pr_list = function(cb, search) table.insert(searches, search or "nil"); cb(nil, { pr(1) }) end
      pr_picker.show({ on_select = function() end })
      assert.are.same({ "" }, searches)
      assert.are.equal("Checkout PR — all open  (<a-s> filters)", picker_config.title)
      assert.are.same({ kind = "all" }, pr_picker.last_scope)
    end)

    it("runs one search per term of the review scope and merges results", function()
      local searches = {}
      gh.pr_list = function(cb, search)
        table.insert(searches, search)
        cb(nil, #searches == 1 and { pr(3), pr(1) } or { pr(3), pr(8) })
      end
      pr_picker.show({ on_select = function() end, scope = { kind = "review" }, title = "PRs" })
      assert.are.equal(3, #searches)
      assert.are.same({ 8, 3, 1 }, vim.tbl_map(function(i) return i._pr.number end, picker_config.items))
      assert.is_truthy(picker_config.title:find("^PRs — review"))
    end)

    it("names the scope when nothing matches", function()
      gh.pr_list = function(cb) cb(nil, {}) end
      local msgs = {}
      local orig = vim.notify
      vim.notify = function(m) table.insert(msgs, m) end
      pr_picker.show({ on_select = function() end, scope = { kind = "author", login = "zed" } })
      vim.notify = orig
      assert.is_truthy(msgs[#msgs]:find("no open PRs found (author @zed)", 1, true))
    end)

    it("switches scope in place, keeping the callbacks", function()
      local searches = {}
      gh.pr_list = function(cb, search) table.insert(searches, search); cb(nil, { pr(1) }) end
      local selected
      pr_picker.show({ on_select = function(n) selected = n end })
      local closed = false
      picker_config.actions.scope_mine({ close = function() closed = true end })
      assert.is_true(closed)
      assert.are.equal("author:@me", searches[2])
      picker_config.confirm({ close = function() end }, picker_config.items[1])
      assert.are.equal(1, selected)
    end)

    it("binds the checkout key only when on_checkout is given", function()
      gh.pr_list = function(cb) cb(nil, { pr(5) }) end
      pr_picker.show({ on_select = function() end })
      assert.is_nil(picker_config.win.input.keys["<c-o>"])

      local checked, checked_pr
      pr_picker.show({ on_select = function() end, on_checkout = function(n, pr) checked = n; checked_pr = pr end })
      assert.are.equal("checkout_pr", picker_config.win.input.keys["<c-o>"][1])
      picker_config.actions.checkout_pr({ close = function() end }, picker_config.items[1])
      assert.are.equal(5, checked)
      assert.are.equal(5, checked_pr.number)
    end)
  end)

  describe("review decisions", function()
    it("opens without them, then fills badges per search term and redraws", function()
      gh.pr_list = function(cb) cb(nil, {
        { number = 1, title = "A", author = { login = "d" }, body = "" },
        { number = 2, title = "B", author = { login = "d" }, body = "", reviewDecision = "APPROVED" },
      }) end
      local searches = {}
      gh.pr_review_states = function(cb, search)
        table.insert(searches, search)
        cb(nil, {
          [1] = { decision = "CHANGES_REQUESTED", viewer = "APPROVED" },
          [2] = { decision = "REVIEW_REQUIRED" },
        })
      end
      local redrawn = 0
      package.loaded["gh-review.ui.picker_util"] = { redraw = function() redrawn = redrawn + 1 end }
      pr_picker.show({ on_select = function() end })
      package.loaded["gh-review.ui.picker_util"] = nil

      assert.are.same({ "" }, searches)
      -- Once for the review states, once for the (empty) stacks.
      assert.are.equal(2, redrawn)
      assert.are.equal("CHANGES_REQUESTED", picker_config.items[1]._pr.reviewDecision)
      -- A decision the list already had is kept.
      assert.are.equal("APPROVED", picker_config.items[2]._pr.reviewDecision)
      local text = table.concat(vim.tbl_map(function(p) return p[1] end, picker_config.format(picker_config.items[1])), "")
      assert.is_truthy(text:find("✗", 1, true))
      -- Your own approval shows as a tag before the title, and is searchable.
      assert.is_truthy(text:find("[Approved] A", 1, true))
      assert.is_truthy(picker_config.items[1].text:find("[Approved]", 1, true))
      local other = table.concat(vim.tbl_map(function(p) return p[1] end, picker_config.format(picker_config.items[2])), "")
      assert.is_nil(other:find("[", 1, true))
    end)

    it("maps each review state to its tag, and hides unknown or disabled ones", function()
      assert.are.equal("[Approved]", pr_picker.viewer_tag("APPROVED"))
      assert.are.equal("[Request Changes]", pr_picker.viewer_tag("CHANGES_REQUESTED"))
      assert.are.equal("[Reviewed]", pr_picker.viewer_tag("COMMENTED"))
      assert.are.equal("", pr_picker.viewer_tag("DISMISSED"))
      assert.are.equal("", pr_picker.viewer_tag(nil))
      config.setup({ viewer_review_tags = { APPROVED = "" } })
      assert.are.equal("", pr_picker.viewer_tag("APPROVED"))
    end)
  end)

  describe("long titles", function()
    it("crops the title in the row but keeps it whole for search and preview", function()
      config.setup({ title_max_length = 12 })
      local title = "Refactor the whole authentication layer"
      gh.pr_list = function(cb) cb(nil, { { number = 3, title = title, author = { login = "d" }, body = "" } }) end
      gh.pr_review_states = function(cb) cb(nil, {}) end
      pr_picker.show({ on_select = function() end })
      local row = picker_config.format(picker_config.items[1])
      assert.are.equal("Refactor th…", row[4][1])
      assert.is_truthy(picker_config.items[1].text:find(title, 1, true))
      local preview
      picker_config.preview({
        item = picker_config.items[1],
        preview = { set_lines = function(_, l) preview = l end, highlight = function() end },
      })
      assert.is_truthy(preview[1]:find(title, 1, true))
    end)
  end)

  describe("stacks", function()
    local function stack_node(numbers, merged)
      local nodes = {}
      for i, n in ipairs(numbers) do
        table.insert(nodes, {
          position = i,
          pullRequest = { number = n, state = merged == n and "MERGED" or "OPEN", author = { login = n % 2 == 0 and "me" or "you" } },
        })
      end
      return { number = 9, size = #numbers, baseRefName = "main", entries = { nodes = nodes } }
    end

    local function open_list(opts)
      gh.pr_list = function(cb) cb(nil, {
        { number = 12, title = "A", author = { login = "you" }, body = "" },
        { number = 50, title = "B", author = { login = "you" }, body = "" },
      }) end
      local stack = stack_node({ 11, 12, 13 }, 11)
      gh.pr_stacks = function(cb) cb(nil, { [12] = stack }) end
      local redrawn = 0
      package.loaded["gh-review.ui.picker_util"] = { redraw = function() redrawn = redrawn + 1 end }
      pr_picker.show(vim.tbl_extend("force", { on_select = function() end }, opts or {}))
      package.loaded["gh-review.ui.picker_util"] = nil
      return redrawn
    end

    it("shows the position of the PR in its stack after the title", function()
      -- Once for the review states, once for the stacks.
      assert.are.equal(2, open_list())
      local text = table.concat(vim.tbl_map(function(p) return p[1] end, picker_config.format(picker_config.items[1])), "")
      assert.is_truthy(text:find("A  ⧉ 2/3  @you", 1, true))
      assert.is_truthy(picker_config.items[1].text:find("stack 2/3", 1, true))
      local other = table.concat(vim.tbl_map(function(p) return p[1] end, picker_config.format(picker_config.items[2])), "")
      assert.is_nil(other:find("⧉", 1, true))
    end)

    it("counts the stack size GitHub reports when it lists more PRs than it returns", function()
      local gh_stack = require("gh-review.gh_stack")
      local stack = gh_stack.parse_stack(stack_node({ 11, 12 }))
      stack.size = 12
      assert.are.equal("2/12", pr_picker.stack_position(12, stack))
      assert.is_nil(pr_picker.stack_position(99, stack))
    end)

    it("hands the stack of the PR under the cursor to the first/last-of-mine keys", function()
      local got = {}
      open_list({ on_own_stack_pr = function(stack, which) table.insert(got, stack.number .. which) end })
      local closed = 0
      local picker = { close = function() closed = closed + 1 end }
      assert.are.equal("own_first", picker_config.win.input.keys["<a-f>"][1])
      assert.are.equal("own_last", picker_config.win.list.keys["<a-l>"][1])
      picker_config.actions.own_first(picker, picker_config.items[1])
      picker_config.actions.own_last(picker, picker_config.items[1])
      assert.are.same({ "9first", "9last" }, got)
      assert.are.equal(2, closed)
    end)

    it("says so when the PR under the cursor is not stacked", function()
      local called = false
      open_list({ on_own_stack_pr = function() called = true end })
      local notes = {}
      local orig = vim.notify
      vim.notify = function(m) table.insert(notes, m) end
      picker_config.actions.own_first({ close = function() end }, picker_config.items[2])
      vim.notify = orig
      assert.is_false(called)
      assert.is_truthy(notes[1]:find("not in a GitHub stack", 1, true))
    end)

    it("keeps the list when the stack query fails", function()
      gh.pr_list = function(cb) cb(nil, { { number = 1, title = "A", author = { login = "d" }, body = "" } }) end
      gh.pr_stacks = function(cb) cb("Field 'stack' doesn't exist", nil) end
      pr_picker.show({ on_select = function() end })
      assert.is_nil(picker_config.items[1]._stack)
    end)
  end)

  describe("search by PR number", function()
    before_each(function()
      gh.pr_list = function(cb) cb(nil, {
        { number = 123, title = "A", author = { login = "d" }, body = "see 99" },
        { number = 99, title = "B", author = { login = "d" }, body = "" },
      }) end
    end)

    it("turns a number query into a match on PR numbers only", function()
      pr_picker.show({ on_select = function() end })
      assert.are.equal(123, picker_config.items[1].pr)
      for query, want in pairs({ ["123"] = "pr:^123", ["#99"] = "pr:^99", [" 12 "] = "pr:^12" }) do
        local f = { pattern = query }
        picker_config.filter.transform(nil, f)
        assert.are.equal(want, f.pattern)
      end
      local f = { pattern = "login fix" }
      picker_config.filter.transform(nil, f)
      assert.are.equal("login fix", f.pattern)
    end)

    it("opens a PR the list does not hold when its number is typed", function()
      local selected
      pr_picker.show({ on_select = function(n, pr) selected = { n = n, pr = pr } end })
      local closed = false
      local picker = { close = function() closed = true end, input = { filter = { pattern = "#4567" } } }
      picker_config.confirm(picker, nil)
      assert.is_true(closed)
      assert.are.same({ n = 4567 }, selected)
    end)

    it("does nothing on an empty result for another query", function()
      local selected = false
      pr_picker.show({ on_select = function() selected = true end })
      picker_config.confirm({ close = function() end, input = { filter = { pattern = "nothing" } } }, nil)
      assert.is_false(selected)
    end)
  end)
end)
