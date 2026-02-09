---@module 'luassert'

local config = require("gh-review.config")

describe("which_key", function()
  local wk_module

  before_each(function()
    config.setup()
    package.loaded["gh-review.integrations.which_key"] = nil
  end)

  after_each(function()
    package.loaded["which-key"] = nil
  end)

  it("registers keybindings when which-key is available", function()
    local captured_entries
    package.loaded["which-key"] = {
      add = function(entries) captured_entries = entries end,
    }

    wk_module = require("gh-review.integrations.which_key")
    wk_module.register()

    assert.is_table(captured_entries)
    assert.are.equal("<leader>gp", captured_entries[1][1])
    assert.are.equal("PR Review", captured_entries[1].group)
    assert.is_true(#captured_entries > 10)
  end)

  it("does nothing when which-key is not available", function()
    package.loaded["which-key"] = nil

    wk_module = require("gh-review.integrations.which_key")
    assert.has_no.errors(function()
      wk_module.register()
    end)
  end)

  it("uses prefix from config", function()
    config.setup({ keymaps = { prefix = "<leader>pr" } })
    local captured_entries
    package.loaded["which-key"] = {
      add = function(entries) captured_entries = entries end,
    }

    wk_module = require("gh-review.integrations.which_key")
    wk_module.register()

    assert.are.equal("<leader>pr", captured_entries[1][1])
    assert.is_truthy(captured_entries[2][1]:find("^<leader>pr"))
  end)

  it("includes ]d and [d entries", function()
    local captured_entries
    package.loaded["which-key"] = {
      add = function(entries) captured_entries = entries end,
    }

    wk_module = require("gh-review.integrations.which_key")
    wk_module.register()

    local found_next, found_prev = false, false
    for _, entry in ipairs(captured_entries) do
      if entry[1] == "]d" then found_next = true end
      if entry[1] == "[d" then found_prev = true end
    end
    assert.is_true(found_next)
    assert.is_true(found_prev)
  end)
end)
