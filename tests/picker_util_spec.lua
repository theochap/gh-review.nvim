---@module 'luassert'

describe("picker_util", function()
  local picker_util

  before_each(function()
    package.loaded["gh-review.ui.picker_util"] = nil
    picker_util = require("gh-review.ui.picker_util")
  end)

  describe("ensure_highlights", function()
    it("defines the picker highlight groups as links", function()
      picker_util.ensure_highlights()

      local marker = vim.api.nvim_get_hl(0, { name = picker_util.ACTIVE, link = true })
      local entry = vim.api.nvim_get_hl(0, { name = picker_util.ACTIVE_ENTRY, link = true })
      assert.are.equal("CurSearch", marker.link)
      assert.are.equal("Visual", entry.link)
    end)

    it("does not clobber a colorscheme override", function()
      -- `default = true` must lose against whatever is already defined
      vim.api.nvim_set_hl(0, picker_util.ACTIVE, { link = "IncSearch" })
      package.loaded["gh-review.ui.picker_util"] = nil
      local reloaded = require("gh-review.ui.picker_util")

      reloaded.ensure_highlights()

      local marker = vim.api.nvim_get_hl(0, { name = reloaded.ACTIVE, link = true })
      vim.api.nvim_set_hl(0, reloaded.ACTIVE, { link = "CurSearch" })
      assert.are.equal("IncSearch", marker.link)
    end)
  end)

  describe("focus_current", function()
    --- Picker double recording the row the list was scrolled to.
    local function fake_picker(items)
      local viewed
      return {
        items = function() return items end,
        list = { view = function(_, idx) viewed = idx end },
        viewed = function() return viewed end,
      }
    end

    it("moves the list onto the current entry", function()
      local picker = fake_picker({ { id = 1 }, { id = 2, current = true }, { id = 3 } })

      picker_util.focus_current(picker, function(item) return item.current end)

      assert.are.equal(2, picker.viewed())
    end)

    it("leaves the list alone when nothing is current", function()
      local picker = fake_picker({ { id = 1 }, { id = 2 } })

      picker_util.focus_current(picker, function(item) return item.current end)

      assert.is_nil(picker.viewed())
    end)

    it("stops at the first match", function()
      local picker = fake_picker({ { current = true }, { current = true } })

      picker_util.focus_current(picker, function(item) return item.current end)

      assert.are.equal(1, picker.viewed())
    end)

    it("survives snacks not exposing the centering action", function()
      package.loaded["snacks"] = { picker = {} }
      local picker = fake_picker({ { current = true } })

      picker_util.focus_current(picker, function(item) return item.current end)

      package.loaded["snacks"] = nil
      assert.are.equal(1, picker.viewed())
    end)
  end)
end)
