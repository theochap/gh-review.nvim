---@module 'luassert'

local config = require("gh-review.config")

describe("health", function()
  local health
  local captured_health
  local orig_health

  before_each(function()
    config.setup()

    captured_health = {}
    orig_health = {
      start = vim.health.start,
      ok = vim.health.ok,
      error = vim.health.error,
      info = vim.health.info,
    }
    vim.health.start = function(msg) table.insert(captured_health, { type = "start", msg = msg }) end
    vim.health.ok = function(msg) table.insert(captured_health, { type = "ok", msg = msg }) end
    vim.health.error = function(msg, advice) table.insert(captured_health, { type = "error", msg = msg, advice = advice }) end
    vim.health.info = function(msg) table.insert(captured_health, { type = "info", msg = msg }) end

    package.loaded["gh-review.health"] = nil
    health = require("gh-review.health")
  end)

  after_each(function()
    vim.health.start = orig_health.start
    vim.health.ok = orig_health.ok
    vim.health.error = orig_health.error
    vim.health.info = orig_health.info
  end)

  --- Run health check with stubs for gh CLI
  local function run_check(opts)
    opts = opts or {}
    local orig_executable = vim.fn.executable
    local orig_system_fn = vim.fn.system
    local orig_system = vim.system

    vim.fn.executable = function() return opts.executable or 1 end
    vim.fn.system = function() return opts.version or "gh version 2.40.0\n" end
    vim.system = function()
      return { wait = function() return { code = opts.auth_code or 0 } end }
    end

    health.check()

    vim.fn.executable = orig_executable
    vim.fn.system = orig_system_fn
    vim.system = orig_system
  end

  it("reports start with plugin name", function()
    run_check()
    assert.are.equal("start", captured_health[1].type)
    assert.are.equal("gh-review.nvim", captured_health[1].msg)
  end)

  it("reports gh CLI found when executable", function()
    run_check({ version = "gh version 2.40.0 (2024-01-15)\n" })
    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "ok" and h.msg:find("gh CLI found") then found = true end
    end
    assert.is_true(found)
  end)

  it("reports error when gh CLI not found", function()
    run_check({ executable = 0 })
    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "error" and h.msg:find("gh CLI not found") then found = true end
    end
    assert.is_true(found)
    -- Should have advice
    for _, h in ipairs(captured_health) do
      if h.type == "error" then
        assert.is_table(h.advice)
      end
    end
  end)

  it("returns early when gh CLI not found (no auth check)", function()
    run_check({ executable = 0 })
    -- Should only have start + error, no auth check
    local has_auth = false
    for _, h in ipairs(captured_health) do
      if h.msg and h.msg:find("authenticated") then has_auth = true end
    end
    assert.is_false(has_auth)
  end)

  it("reports gh authenticated on success", function()
    run_check({ auth_code = 0 })
    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "ok" and h.msg == "gh authenticated" then found = true end
    end
    assert.is_true(found)
  end)

  it("reports error when not authenticated", function()
    run_check({ auth_code = 1 })
    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "error" and h.msg:find("not authenticated") then found = true end
    end
    assert.is_true(found)
  end)

  it("reports neovim version check", function()
    run_check()
    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "ok" and h.msg:find("Neovim >= 0.10") then found = true end
    end
    assert.is_true(found)
  end)

  it("reports optional dependencies", function()
    run_check()
    -- Some optional deps should be reported
    local info_count = 0
    for _, h in ipairs(captured_health) do
      if h.type == "info" then info_count = info_count + 1 end
    end
    assert.is_true(info_count > 0)
  end)

  it("reports found optional deps", function()
    -- Pre-load one optional dep
    package.loaded["diffview"] = {}
    run_check()
    package.loaded["diffview"] = nil

    local found = false
    for _, h in ipairs(captured_health) do
      if h.type == "ok" and h.msg:find("diffview.nvim found") then found = true end
    end
    assert.is_true(found)
  end)
end)
