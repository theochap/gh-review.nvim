---@module 'luassert'

local diagnostics = require("gh-review.ui.diagnostics")
local state = require("gh-review.state")
local config = require("gh-review.config")

describe("diagnostics", function()
  before_each(function()
    config.setup()
    state.clear()
    diagnostics.setup()
  end)

  after_each(function()
    diagnostics.clear_all()
    state.clear()
  end)

  describe("refresh_buf", function()
    it("sets diagnostics for threads in a buffer", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          mapped_line = 5,
          is_resolved = false,
          comments = { { author = "alice", body = "Fix this" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/test.lua")
      vim.bo[buf].buftype = ""

      diagnostics.refresh_buf(buf)

      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(1, #diags)
      assert.are.equal(4, diags[1].lnum) -- 0-indexed
      assert.is_truthy(diags[1].message:find("Fix this"))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows [resolved] prefix for resolved threads", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          mapped_line = 5,
          is_resolved = true,
          comments = { { author = "alice", body = "LGTM" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/test.lua")
      vim.bo[buf].buftype = ""

      diagnostics.refresh_buf(buf)
      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(1, #diags)
      assert.is_truthy(diags[1].message:find("^%[resolved%]"))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("clears diagnostics when no active review", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = ""
      diagnostics.refresh_buf(buf)
      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(0, #diags)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("clears diagnostics for files with no threads", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({})

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/clean.lua")
      vim.bo[buf].buftype = ""

      diagnostics.refresh_buf(buf)
      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(0, #diags)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("truncates long messages to 80 chars", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      local long_body = string.rep("x", 120)
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          mapped_line = 1,
          is_resolved = false,
          comments = { { author = "alice", body = long_body } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/test.lua")
      vim.bo[buf].buftype = ""

      diagnostics.refresh_buf(buf)
      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.is_true(#diags[1].message <= 83) -- 80 chars + "..."

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("refresh_all", function()
    it("refreshes all loaded normal buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/a.lua",
          mapped_line = 1,
          is_resolved = false,
          comments = { { author = "alice", body = "Comment A" } },
        },
        {
          id = "t2",
          path = "src/b.lua",
          mapped_line = 2,
          is_resolved = false,
          comments = { { author = "bob", body = "Comment B" } },
        },
      })

      local buf_a = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf_a, vim.fn.getcwd() .. "/src/a.lua")
      vim.bo[buf_a].buftype = ""

      local buf_b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf_b, vim.fn.getcwd() .. "/src/b.lua")
      vim.bo[buf_b].buftype = ""

      diagnostics.refresh_all()

      local diags_a = vim.diagnostic.get(buf_a, { namespace = diagnostics.namespace() })
      local diags_b = vim.diagnostic.get(buf_b, { namespace = diagnostics.namespace() })
      assert.are.equal(1, #diags_a)
      assert.are.equal(1, #diags_b)

      vim.api.nvim_buf_delete(buf_a, { force = true })
      vim.api.nvim_buf_delete(buf_b, { force = true })
    end)
  end)

  describe("clear_all", function()
    it("removes all diagnostics", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          mapped_line = 1,
          is_resolved = false,
          comments = { { author = "alice", body = "Note" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/test.lua")
      vim.bo[buf].buftype = ""

      diagnostics.refresh_buf(buf)
      assert.are.equal(1, #vim.diagnostic.get(buf, { namespace = diagnostics.namespace() }))

      diagnostics.clear_all()
      assert.are.equal(0, #vim.diagnostic.get(buf, { namespace = diagnostics.namespace() }))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
