---@module 'luassert'

local config = require("gh-review.config")

describe("ui.filters", function()
  local ui, picker_config

  before_each(function()
    config.setup()
    picker_config = nil
    package.loaded["snacks"] = { picker = { pick = function(opts) picker_config = opts end } }
    package.loaded["gh-review.ui.filters"] = nil
    ui = require("gh-review.ui.filters")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
  end)

  local approved = { kind = "review", qualifier = "review:approved", text = "approved" }

  --- A picker whose selection is `items` (snacks falls back to the cursor item).
  local function picker_with(items)
    return { close = function() end, selected = function() return items end }
  end

  local function item(label)
    for _, it in ipairs(picker_config.items) do
      if it.text == label then return it end
    end
    error("no option " .. label)
  end

  it("marks the active filters", function()
    ui.show({ kind = "all", filters = { approved } }, function() end)
    local first = picker_config.format(picker_config.items[1])
    assert.are.equal("✓ ", first[1][1])
    assert.are.equal("Review decision: approved", first[2][1])
    assert.are.equal("  ", picker_config.format(item("Status: draft"))[1][1])
    assert.is_truthy(picker_config.title:find("<Tab> select", 1, true))
  end)

  it("toggles every selected option at once", function()
    local got
    ui.show({ kind = "all", filters = { approved } }, function(s) got = s end)
    picker_config.confirm(picker_with({ item("Review decision: approved"), item("Status: draft"), item("Checks: checks failing") }))
    assert.are.same({ kind = "all", filters = {
      { kind = "status", qualifier = "draft:true", text = "draft" },
      { kind = "checks", qualifier = "status:failure", text = "checks failing" },
    } }, got)
  end)

  it("asks a value for the options that need one", function()
    local got
    ui.show({ kind = "all" }, function(s) got = s end)
    local orig = vim.ui.input
    vim.ui.input = function(_, cb) cb("dev") end
    picker_config.confirm(picker_with({ item("Base branch: enter a value…") }))
    vim.ui.input = orig
    assert.are.same({ kind = "all", filters = { { kind = "base", qualifier = "base:dev", text = "into dev" } } }, got)
  end)

  it("clears every filter with the clear key", function()
    local got
    ui.show({ kind = "mine", filters = { approved } }, function(s) got = s end)
    assert.are.equal("clear_filters", picker_config.win.input.keys["<a-x>"][1])
    picker_config.actions.clear_filters({ close = function() end })
    assert.are.same({ kind = "mine", filters = {} }, got)
  end)

  it("falls back to the one-filter prompts without snacks", function()
    package.loaded["snacks"] = nil
    package.loaded["gh-review.ui.filters"] = nil
    ui = require("gh-review.ui.filters")
    local scope_mod = require("gh-review.scope")
    local orig = scope_mod.prompt_filter
    local prompted = false
    scope_mod.prompt_filter = function() prompted = true end
    ui.show({ kind = "all" }, function() end)
    scope_mod.prompt_filter = orig
    assert.is_true(prompted)
  end)
end)
