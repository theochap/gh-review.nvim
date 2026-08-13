--- :checkhealth gh-review
local M = {}

function M.check()
  vim.health.start("gh-review.nvim")

  -- Check gh CLI
  local gh_cmd = require("gh-review.config").get().gh_cmd
  if vim.fn.executable(gh_cmd) == 1 then
    local output = vim.fn.system({ gh_cmd, "--version" })
    vim.health.ok("gh CLI found: " .. vim.trim(output:match("[^\n]+") or output))
  else
    vim.health.error("gh CLI not found", { "Install gh: https://cli.github.com/" })
    return
  end

  -- Check gh auth
  local result = vim.system({ gh_cmd, "auth", "status" }, { text = true }):wait()
  if result.code == 0 then
    vim.health.ok("gh authenticated")
  else
    vim.health.error("gh not authenticated", { "Run: gh auth login" })
  end

  -- Report the detected VCS layout. jj repositories need extra handling (see
  -- vcs.lua), so surfacing what was detected is the fastest way to diagnose
  -- "no PR found for current branch" or empty base-side diffs.
  local vcs = require("gh-review.vcs")
  local ctx = vcs.context()
  local info = vcs.describe()
  if ctx.kind == "none" then
    vim.health.warn("no git or jj repository found in the current directory")
  elseif ctx.kind == "jj" and not ctx.git_dir then
    vim.health.error("jj workspace found but its backing git repository could not be resolved", {
      "gh-review needs a git-backed jj repo (jj git init / jj git clone)",
    })
  else
    vim.health.ok(table.concat(info, ", "))
  end
  if ctx.jj_root then
    if vim.fn.executable("jj") == 1 then
      local jj_version = vim.fn.system({ "jj", "--version" })
      vim.health.ok("jj found: " .. vim.trim(jj_version:match("[^\n]+") or jj_version))
    else
      vim.health.error("jj repository detected but jj executable not found", {
        "Install jj: https://github.com/jj-vcs/jj",
      })
    end
    local candidates = vcs.pr_branch_candidates()
    if #candidates > 0 then
      vim.health.info("PR lookup bookmarks: " .. table.concat(candidates, ", "))
    end
  end

  -- Check neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required")
  end

  -- Check optional deps
  local deps = {
    { name = "diffview.nvim", module = "diffview" },
    { name = "lualine.nvim", module = "lualine" },
    { name = "which-key.nvim", module = "which-key" },
    { name = "trouble.nvim", module = "trouble" },
    { name = "mini.diff", module = "mini.diff" },
  }
  for _, dep in ipairs(deps) do
    local ok, _ = pcall(require, dep.module)
    if ok then
      vim.health.ok(dep.name .. " found")
    else
      vim.health.info(dep.name .. " not found (optional)")
    end
  end
end

return M
