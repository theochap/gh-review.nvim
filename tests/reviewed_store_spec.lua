---@module 'luassert'

local store = require("gh-review.reviewed_store")

describe("reviewed_store", function()
  local original_stdpath
  local tmp_data

  before_each(function()
    tmp_data = vim.fn.tempname()
    vim.fn.mkdir(tmp_data, "p")
    original_stdpath = vim.fn.stdpath
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.stdpath = function(what)
      if what == "data" then return tmp_data end
      return original_stdpath(what)
    end
  end)

  after_each(function()
    vim.fn.stdpath = original_stdpath
    vim.fn.delete(tmp_data, "rf")
  end)

  describe("key_for", function()
    it("returns nil when PR lacks repository or number", function()
      assert.is_nil(store.key_for(nil))
      assert.is_nil(store.key_for({ number = 1 }))
      assert.is_nil(store.key_for({ repository = "o/r" }))
    end)

    it("builds owner/repo#number", function()
      assert.are.equal("owner/repo#42", store.key_for({ repository = "owner/repo", number = 42 }))
    end)
  end)

  describe("save + load roundtrip", function()
    it("persists and reloads path list", function()
      local key = "owner/repo#7"
      assert.is_true(store.save(key, { "src/a.lua", "src/b.lua" }))
      local loaded = store.load(key)
      table.sort(loaded)
      assert.are.same({ "src/a.lua", "src/b.lua" }, loaded)
    end)

    it("load returns empty list when the file doesn't exist", function()
      assert.are.same({}, store.load("owner/repo#nonexistent"))
    end)

    it("load returns empty list on malformed JSON", function()
      local key = "owner/repo#bad"
      local path = vim.fn.stdpath("data") .. "/gh-review/reviewed/" .. key:gsub("[^%w]", "_") .. ".json"
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      local f = io.open(path, "w")
      f:write("not json")
      f:close()
      assert.are.same({}, store.load(key))
    end)

    it("save overwrites previous state", function()
      local key = "owner/repo#42"
      store.save(key, { "a.lua", "b.lua" })
      store.save(key, { "c.lua" })
      assert.are.same({ "c.lua" }, store.load(key))
    end)

    it("delete removes the file", function()
      local key = "owner/repo#9"
      store.save(key, { "x.lua" })
      store.delete(key)
      assert.are.same({}, store.load(key))
    end)
  end)
end)
