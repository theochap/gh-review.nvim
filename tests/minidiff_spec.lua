---@module 'luassert'

local state = require("gh-review.state")

-- Stub MiniDiff so tests work without the real plugin
local minidiff_calls = {}
local minidiff_enabled = {}
local minidiff_overlay = {} -- buf → bool

package.loaded["mini.diff"] = {
  enable = function(buf)
    minidiff_enabled[buf] = true
    table.insert(minidiff_calls, { fn = "enable", buf = buf })
  end,
  disable = function(buf)
    minidiff_enabled[buf] = nil
    minidiff_overlay[buf] = nil
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
    minidiff_overlay[buf] = not (minidiff_overlay[buf] == true)
    table.insert(minidiff_calls, { fn = "toggle_overlay", buf = buf })
  end,
  get_buf_data = function(buf)
    if not minidiff_enabled[buf] then return nil end
    return { overlay = minidiff_overlay[buf] == true }
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
    minidiff_overlay = {}
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

    it("uses base_sha (merge base) instead of base_ref when available", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main", base_sha = "abc123sha" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local show_ref = nil
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          show_ref = cmd[3]
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)

      assert.are.equal("abc123sha:src/file.lua", show_ref)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("falls back to base_ref when base_sha is absent", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local show_ref = nil
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          show_ref = cmd[3]
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)

      assert.are.equal("main:src/file.lua", show_ref)

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

  describe("attach with opts.rel_path", function()
    it("accepts an explicit rel_path for scratch buffers", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main", base_sha = "deadbeef" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      -- Scratch buffer with a ghreview:// name — NOT on disk
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "ghreview://commit/abc12345/src/file.lua")

      local show_ref = nil
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          show_ref = cmd[3]
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf, { rel_path = "src/file.lua" })

      -- Ref must use the PR base SHA + the rel_path we passed in, NOT the scratch name
      assert.are.equal("deadbeef:src/file.lua", show_ref)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("still falls back to buf name when rel_path not given", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local show_ref = nil
      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          show_ref = cmd[3]
          return { wait = function() return { code = 0, stdout = "content\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)  -- no opts

      assert.are.equal("main:src/file.lua", show_ref)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("set_overlay", function()
    it("turns overlay on when requested and currently off", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf) -- enables buffer, overlay off
      minidiff_calls = {}

      minidiff.set_overlay(buf, true)

      local toggled = false
      for _, c in ipairs(minidiff_calls) do
        if c.fn == "toggle_overlay" and c.buf == buf then toggled = true end
      end
      assert.is_true(toggled)

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("is a no-op when overlay is already in the requested state", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      minidiff.set_overlay(buf, true)  -- overlay now on
      minidiff_calls = {}

      minidiff.set_overlay(buf, true)  -- already on; should do nothing

      for _, c in ipairs(minidiff_calls) do
        assert.are_not.equal("toggle_overlay", c.fn)
      end

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("turns overlay off when requested and currently on", function()
      state.set_pr({ number = 1, title = "test", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      minidiff.set_overlay(buf, true)
      minidiff_calls = {}

      minidiff.set_overlay(buf, false)

      local toggled = false
      for _, c in ipairs(minidiff_calls) do
        if c.fn == "toggle_overlay" then toggled = true end
      end
      assert.is_true(toggled)

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

  describe("overlay preference tracking", function()
    it("set_overlay records the preference", function()
      state.set_pr({ number = 1, title = "t", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      minidiff.set_overlay(buf, true)
      assert.is_true(minidiff.get_overlay_preference())
      minidiff.set_overlay(buf, false)
      assert.is_false(minidiff.get_overlay_preference())

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("toggle_overlay flips the preference on success", function()
      state.set_pr({ number = 1, title = "t", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      minidiff.set_overlay(buf, false)
      assert.is_false(minidiff.get_overlay_preference())
      vim.api.nvim_set_current_buf(buf)
      minidiff.toggle_overlay()
      assert.is_true(minidiff.get_overlay_preference())
      minidiff.toggle_overlay()
      assert.is_false(minidiff.get_overlay_preference())

      vim.system = orig_system
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("detach_all resets the preference", function()
      state.set_pr({ number = 1, title = "t", base_ref = "main" })
      state.set_files({ { path = "src/file.lua", status = "modified" } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/src/file.lua")

      local orig_system = vim.system
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "show" then
          return { wait = function() return { code = 0, stdout = "x\n" } end }
        end
        return orig_system(cmd, opts)
      end

      minidiff.attach(buf)
      minidiff.set_overlay(buf, true)
      assert.is_true(minidiff.get_overlay_preference())
      minidiff.detach_all()
      assert.is_false(minidiff.get_overlay_preference())

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
