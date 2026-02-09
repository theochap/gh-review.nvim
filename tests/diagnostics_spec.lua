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

  describe("ghreview:// commit buffers", function()
    it("sets diagnostics on ghreview://commit/<sha>/<path> buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          line = 5,
          mapped_line = 7,
          is_resolved = false,
          comments = { { author = "alice", body = "Fix this" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "ghreview://commit/abc12345/src/test.lua")
      vim.bo[buf].buftype = "nofile"

      diagnostics.refresh_buf(buf)

      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(1, #diags)
      -- Commit buffers use thread.line (not mapped_line)
      assert.are.equal(4, diags[1].lnum) -- line 5, 0-indexed = 4

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses thread.line not mapped_line for commit diff buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          line = 10,
          mapped_line = 25,
          is_resolved = false,
          comments = { { author = "alice", body = "Commit comment" } },
        },
      })

      -- Regular buffer should use mapped_line
      local reg_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(reg_buf, vim.fn.getcwd() .. "/src/test.lua")
      vim.bo[reg_buf].buftype = ""
      diagnostics.refresh_buf(reg_buf)
      local reg_diags = vim.diagnostic.get(reg_buf, { namespace = diagnostics.namespace() })
      assert.are.equal(24, reg_diags[1].lnum) -- mapped_line 25, 0-indexed

      -- Commit buffer should use line
      local commit_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(commit_buf, "ghreview://commit/abc12345/src/test.lua")
      vim.bo[commit_buf].buftype = "nofile"
      diagnostics.refresh_buf(commit_buf)
      local commit_diags = vim.diagnostic.get(commit_buf, { namespace = diagnostics.namespace() })
      assert.are.equal(9, commit_diags[1].lnum) -- line 10, 0-indexed

      vim.api.nvim_buf_delete(reg_buf, { force = true })
      vim.api.nvim_buf_delete(commit_buf, { force = true })
    end)

    it("refresh_all includes ghreview://commit buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          line = 5,
          is_resolved = false,
          comments = { { author = "alice", body = "Check" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "ghreview://commit/abc12345/src/test.lua")
      vim.bo[buf].buftype = "nofile"

      diagnostics.refresh_all()

      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(1, #diags)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("refresh_all skips non-ghreview scratch buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_threads({
        {
          id = "t1",
          path = "src/test.lua",
          line = 5,
          mapped_line = 5,
          is_resolved = false,
          comments = { { author = "alice", body = "Skip me" } },
        },
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "some-random-scratch-buffer")
      vim.bo[buf].buftype = "nofile"

      diagnostics.refresh_all()

      local diags = vim.diagnostic.get(buf, { namespace = diagnostics.namespace() })
      assert.are.equal(0, #diags)

      vim.api.nvim_buf_delete(buf, { force = true })
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
