---@module 'luassert'

local config = require("gh-review.config")

describe("config", function()
  before_each(function()
    config.setup()
  end)

  describe("defaults", function()
    it("has all expected keymap fields", function()
      local km = config.get().keymaps
      assert.is_not_nil(km.prefix)
      assert.is_not_nil(km.checkout)
      assert.is_not_nil(km.files)
      assert.is_not_nil(km.comments)
      assert.is_not_nil(km.reply)
      assert.is_not_nil(km.new_thread)
      assert.is_not_nil(km.toggle_resolve)
      assert.is_not_nil(km.hover)
      assert.is_not_nil(km.description)
      assert.is_not_nil(km.refresh)
      assert.is_not_nil(km.close)
      assert.is_not_nil(km.next_comment)
      assert.is_not_nil(km.prev_comment)
    end)

    it("includes toggle_overlay keymap", function()
      assert.are.equal("D", config.get().keymaps.toggle_overlay)
    end)

    it("includes open_minidiff keymap", function()
      assert.are.equal("e", config.get().keymaps.open_minidiff)
    end)
  end)

  describe("setup", function()
    it("deep merges user config", function()
      config.setup({ keymaps = { toggle_overlay = "X" } })
      local km = config.get().keymaps
      assert.are.equal("X", km.toggle_overlay)
      -- Other defaults preserved
      assert.are.equal("<leader>gp", km.prefix)
      assert.are.equal("e", km.open_minidiff)
    end)

    it("preserves defaults when no user config", function()
      config.setup()
      assert.are.equal("gh", config.get().gh_cmd)
      assert.are.equal("rounded", config.get().float.border)
    end)
  end)
end)
