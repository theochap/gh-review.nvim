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
    gh_review.checkout_or_pick(pr_num)
  elseif cmd == "current" then
    gh_review.review_current()
  elseif cmd == "files" then
    gh_review.files()
  elseif cmd == "comments" then
    gh_review.comments()
  elseif cmd == "hover" then
    gh_review.show_hover()
  elseif cmd == "description" then
    gh_review.description()
  elseif cmd == "pending" then
    gh_review.pending_review()
  elseif cmd == "submit" then
    gh_review.submit_review(args[2])
  elseif cmd == "review" then
    gh_review.review_pr(args[2])
  elseif cmd == "stack" then
    gh_review.stack_panel()
  elseif cmd == "stack-next" then
    gh_review.next_stack_commit()
  elseif cmd == "stack-prev" then
    gh_review.prev_stack_commit()
  elseif cmd == "prs" or cmd == "stacks" then
    local scope, err = require("gh-review.scope").parse(#args > 1 and { unpack(args, 2) } or nil)
    if not scope then
      vim.notify("GHReview: " .. err, vim.log.levels.ERROR)
    elseif cmd == "prs" then
      gh_review.pr_list(scope)
    else
      gh_review.gh_stacks(scope)
    end
  elseif cmd == "gh-stack" then
    gh_review.gh_stack_panel(tonumber(args[2]))
  elseif cmd == "suggest" or cmd == "suggest-direct" then
    local fn = cmd == "suggest" and gh_review.suggest_change or gh_review.suggest_change_direct
    if opts.range > 0 then
      fn(opts.line1, opts.line2)
    else
      fn()
    end
  elseif cmd == "local" then
    gh_review.toggle_local_diff()
  elseif cmd == "cache-clear" then
    gh_review.clear_cache()
  elseif cmd == "refresh" then
    gh_review.refresh()
  elseif cmd == "close" then
    gh_review.close()
  else
    vim.notify("GHReview: unknown command '" .. (cmd or "") .. "'", vim.log.levels.ERROR)
    vim.notify(
      "Usage: GHReview checkout|current|files|comments|hover|description|pending|submit|review|"
        .. "suggest|suggest-direct|stack|stack-next|stack-prev|prs|stacks|gh-stack|local|cache-clear|refresh|close",
      vim.log.levels.INFO
    )
  end
end, {
  nargs = "*",
  range = true,
  complete = function(_, line)
    local args = vim.split(line, "%s+")
    if (args[2] == "submit" or args[2] == "review") and #args == 3 then
      return vim.tbl_filter(function(s)
        return s:find(args[3] or "", 1, true) == 1
      end, { "comment", "approve", "request-changes" })
    end
    if (args[2] == "prs" or args[2] == "stacks") and #args >= 3 then
      local scope_mod = require("gh-review.scope")
      local candidates = {}
      if #args == 3 then vim.list_extend(candidates, scope_mod.KINDS) end
      for _, def in ipairs(scope_mod.FILTERS) do
        for _, choice in ipairs(def.choices or {}) do table.insert(candidates, choice[2]) end
        if def.kind ~= "custom" and def.qualifier then
          table.insert(candidates, (def.qualifier("x"):gsub("x$", "")))
        end
      end
      local typed = args[#args] or ""
      return vim.tbl_filter(function(s) return s:find(typed, 1, true) == 1 end, candidates)
    end
    local subcmds = {
      "checkout", "current", "files", "comments", "hover", "description",
      "pending", "submit", "review", "suggest", "suggest-direct", "stack", "stack-next", "stack-prev",
      "prs", "stacks", "gh-stack", "local", "cache-clear", "refresh", "close",
    }
    if #args <= 2 then
      return vim.tbl_filter(function(s)
        return s:find(args[2] or "", 1, true) == 1
      end, subcmds)
    end
    return {}
  end,
})
