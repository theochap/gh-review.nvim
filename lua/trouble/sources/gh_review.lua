--- Trouble.nvim custom source for gh-review comment threads
local Item = require("trouble.item")
local M = {}

M.config = {
  modes = {
    gh_review = {
      desc = "PR Review Comments",
      source = "gh_review",
      groups = {
        { "filename", format = "{file_icon} {basename} {count}" },
      },
      sort = { "filename", "pos" },
      format = "{severity_icon} {message:md} {pos}",
      auto_preview = false,
      keys = {
        ["<cr>"] = function(self)
          local node = self:at()
          if not node or not node.item then return end
          local thread = node.item.item and node.item.item.thread
          if not thread then return end
          -- Focus the previous (main) window, then open diff there
          vim.cmd("wincmd p")
          require("gh-review.ui.diff_review").open(
            thread.path,
            thread.mapped_line or thread.line
          )
        end,
      },
    },
  },
}

function M.get(cb, ctx)
  local ok, state = pcall(require, "gh-review.state")
  if not ok or not state.is_active() then
    cb({})
    return
  end

  local items = {}
  local cwd = vim.fn.getcwd()
  for _, thread in ipairs(state.get_threads()) do
    local line = thread.mapped_line or thread.line or 1
    local first = thread.comments[1]
    local author = first and first.author or "unknown"
    local body = first and first.body:match("^([^\n]+)") or ""
    local resolved = thread.is_resolved and "[resolved] " or ""
    local replies = #thread.comments > 1 and (" [+" .. (#thread.comments - 1) .. " replies]") or ""

    table.insert(items, Item.new({
      source = "gh_review",
      filename = cwd .. "/" .. thread.path,
      pos = { line, 0 },
      end_pos = { line, 0 },
      severity = thread.is_resolved and vim.diagnostic.severity.HINT or vim.diagnostic.severity.INFO,
      message = resolved .. "@" .. author .. ": " .. body .. replies,
      item = { thread = thread },
    }))
  end

  Item.add_id(items, { "message" })
  cb(items)
end

return M
