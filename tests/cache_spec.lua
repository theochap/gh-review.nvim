---@module 'luassert'

describe("cache", function()
  local cache

  before_each(function()
    package.loaded["gh-review.cache"] = nil
    cache = require("gh-review.cache")
    cache.clear()
  end)

  it("stores and reads values across the memory copy", function()
    assert.is_nil(cache.get("status", "o/r#1@h-b"))
    cache.set("status", "o/r#1@h-b", { checks = "SUCCESS" })
    assert.are.same({ checks = "SUCCESS" }, cache.get("status", "o/r#1@h-b"))
    cache.forget()
    -- Read back from disk.
    assert.are.same({ checks = "SUCCESS" }, cache.get("status", "o/r#1@h-b"))
  end)

  it("keeps namespaces apart", function()
    cache.set("a", "k", 1)
    assert.is_nil(cache.get("b", "k"))
  end)

  it("ignores corrupt files", function()
    cache.set("ns", "bad", { x = 1 })
    cache.forget()
    local path = vim.fn.glob(cache.root() .. "/ns/*.json")
    local f = assert(io.open(path, "w"))
    f:write("{not json")
    f:close()
    assert.is_nil(cache.get("ns", "bad"))
  end)

  it("clear removes everything", function()
    cache.set("ns", "k", 1)
    cache.clear()
    assert.is_nil(cache.get("ns", "k"))
    assert.are.equal(0, vim.fn.isdirectory(cache.root()))
  end)

  it("prune deletes old entries only", function()
    cache.set("ns", "old", 1)
    cache.set("ns", "new", 2)
    local old = vim.fn.glob(cache.root() .. "/ns/old.json")
    local past = os.time() - (cache.MAX_AGE_DAYS + 1) * 86400
    vim.uv.fs_utime(old, past, past)
    cache.prune()
    cache.forget()
    assert.is_nil(cache.get("ns", "old"))
    assert.are.equal(2, cache.get("ns", "new"))
  end)
end)
