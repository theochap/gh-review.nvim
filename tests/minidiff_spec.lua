---@module 'luassert'

local state = require("gh-review.state")

-- Stub MiniDiff so tests work without the real plugin
local minidiff_calls = {}
local minidiff_enabled = {}

package.loaded["mini.diff"] = {
  enable = function(buf)
    minidiff_enabled[buf] = true
    table.insert(minidiff_calls, { fn = "enable", buf = buf })
  end,
  disable = function(buf)
    minidiff_enabled[buf] = nil
    table.insert(minidiff_calls, { fn = "disable", buf = buf })
  end,
  set_ref_text = function(buf, lines)
    if not minidiff_enabled[buf] then
      -- Mimic real behavior: auto-enable
      minidiff_enabled[buf] = true
    end
    table.insert(minidiff_calls, { fn = "set_ref_text", buf = buf, lines = lines })
  end,
  toggle_overlay = function(buf)
    if not minidiff_enabled[buf] then
      error(string.format("(mini.diff) Buffer %d is not enabled.", buf))
    end
    table.insert(minidiff_calls, { fn = "toggle_overlay", buf = buf })
  end,
}

-- Now require minidiff module (after stub is in place)
package.loaded["gh-review.ui.minidiff"] = nil
local minidiff = require("gh-review.ui.minidiff")

describe("minidiff", function()
  before_each(function()
    state.clear()
    minidiff_calls = {}
    minidiff_enabled = {}
    minidiff.detach_all()
  end)

  describe("attach", function()
    it("does nothing when no active PR", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      minidiff.attach(buf)
      assert.are.equal(0, #minidiff_calls)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does nothing for files not in the PR", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/other.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      minidiff.attach(buf)
      assert.are.equal(0, #minidiff_calls)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("sets buffer-local minidiff_config with gh-review source", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      -- Mock vim.system to avoid actual git call
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "line1\nline2\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)

      local cfg = vim.b[buf].minidiff_config
      assert.is_not_nil(cfg)
      assert.is_not_nil(cfg.source)
      assert.are.equal("gh-review", cfg.source.name)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("calls set_ref_text with base content", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "base_line1\nbase_line2\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)

      -- Find the set_ref_text call
      local found = false
      for _, call in ipairs(minidiff_calls) do
        if call.fn == "set_ref_text" and call.buf == buf then
          found = true
          assert.are.same({ "base_line1", "base_line2" }, call.lines)
        end
      end
      assert.is_true(found, "set_ref_text was not called")

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("caches git show result across multiple calls", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local git_call_count = 0
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          git_call_count = git_call_count + 1
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      assert.are.equal(1, git_call_count)

      -- Second call should use cache
      minidiff_calls = {}
      minidiff.attach(buf)
      assert.are.equal(1, git_call_count) -- still 1, not 2

      -- set_ref_text should still be called (re-asserts ref text)
      local ref_call = false
      for _, call in ipairs(minidiff_calls) do
        if call.fn == "set_ref_text" then ref_call = true end
      end
      assert.is_true(ref_call)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("skips when git show fails", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/new.lua", status = "added" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/new.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 128, stdout = "" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      -- No set_ref_text call since git show failed
      local ref_call = false
      for _, call in ipairs(minidiff_calls) do
        if call.fn == "set_ref_text" then ref_call = true end
      end
      assert.is_false(ref_call)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("toggle_overlay", function()
    it("calls attach then toggle_overlay", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")
      vim.api.nvim_set_current_buf(buf)

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.toggle_overlay()

      local toggle_call = false
      for _, call in ipairs(minidiff_calls) do
        if call.fn == "toggle_overlay" and call.buf == buf then
          toggle_call = true
        end
      end
      assert.is_true(toggle_call)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("detach_all", function()
    it("calls disable and clears buffer config", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      assert.is_not_nil(vim.b[buf].minidiff_config)

      minidiff_calls = {}
      minidiff.detach_all()

      local disable_call = false
      for _, call in ipairs(minidiff_calls) do
        if call.fn == "disable" and call.buf == buf then disable_call = true end
      end
      assert.is_true(disable_call)
      assert.is_nil(vim.b[buf].minidiff_config)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
