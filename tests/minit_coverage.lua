#!/usr/bin/env -S nvim -l

-- Disable JIT before anything else so debug.sethook (used by luacov) works on all code paths.
-- LuaJIT skips hooks for JIT-compiled traces, which causes missing coverage data.
jit.off()
jit.flush()

vim.env.LAZY_STDPATH = ".tests"

-- Add hererocks Lua paths so require("luacov") works inside Neovim's embedded LuaJIT.
local rocks = ".tests/data/nvim/lazy-rocks/hererocks"
package.path = rocks .. "/share/lua/5.1/?.lua;" .. rocks .. "/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = rocks .. "/lib/lua/5.1/?.so;" .. package.cpath

load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"), "bootstrap.lua")()

-- Start luacov before loading any project code
require("luacov")

-- Wrap os.exit so luacov stats are saved when busted calls os.exit(1) on failure.
local real_exit = os.exit
os.exit = function(code, ...)
  require("luacov.runner").shutdown()
  return real_exit(code, ...)
end

require("lazy.minit").setup({
  spec = {
    { dir = vim.uv.cwd() },
  },
})

-- If we get here, tests passed (busted returned without os.exit).
require("luacov.runner").shutdown()
