---@module 'luassert'

describe("health", function()
  it("can be loaded without error", function()
    local ok, health = pcall(require, "gh-review.health")
    assert.is_true(ok)
    assert.is_not_nil(health.check)
  end)
end)
