-- gh-review.nvim entry point
if vim.g.loaded_gh_review then
  return
end
vim.g.loaded_gh_review = true

vim.api.nvim_create_user_command("GHReview", function(opts)
  local args = opts.fargs
  local cmd = args[1]
  local gh_review = require("gh-review")

  if cmd == "checkout" then
    local pr_num = tonumber(args[2])
    if not pr_num then
      vim.ui.input({ prompt = "PR number: " }, function(input)
        local n = tonumber(input)
        if n then
          gh_review.checkout(n)
        end
      end)
    else
      gh_review.checkout(pr_num)
    end
  elseif cmd == "files" then
    gh_review.files()
  elseif cmd == "comments" then
    gh_review.comments()
  elseif cmd == "hover" then
    gh_review.show_hover()
  elseif cmd == "description" then
    gh_review.description()
  elseif cmd == "refresh" then
    gh_review.refresh()
  elseif cmd == "close" then
    gh_review.close()
  else
    vim.notify("GHReview: unknown command '" .. (cmd or "") .. "'", vim.log.levels.ERROR)
    vim.notify("Usage: GHReview checkout|files|comments|hover|description|refresh|close", vim.log.levels.INFO)
  end
end, {
  nargs = "*",
  complete = function(_, line)
    local subcmds = { "checkout", "files", "comments", "hover", "description", "refresh", "close" }
    local args = vim.split(line, "%s+")
    if #args <= 2 then
      return vim.tbl_filter(function(s)
        return s:find(args[2] or "", 1, true) == 1
      end, subcmds)
    end
    return {}
  end,
})
