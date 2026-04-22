--- Configuration for gh-review.nvim
local M = {}

---@class GHReviewConfig
---@field gh_cmd string Path to gh CLI
---@field default_view_mode "split"|"inline" Initial diff view mode per session
---@field default_ignore_whitespace boolean Hide whitespace-only hunks by default
---@field keymaps GHReviewKeymaps
---@field icons GHReviewIcons
---@field float GHReviewFloat
---@field diagnostics GHReviewDiagnostics

---@class GHReviewKeymaps
---@field prefix string
---@field checkout string
---@field files string
---@field files_focus string
---@field comments string
---@field reply string
---@field new_thread string
---@field toggle_resolve string
---@field refresh string
---@field close string
---@field hover string
---@field description string
---@field toggle_overlay string
---@field open_minidiff string
---@field toggle_view string
---@field review_current string
---@field next_comment string
---@field prev_comment string
---@field commits string
---@field next_diff string
---@field prev_diff string
---@field next_file string
---@field prev_file string
---@field diffview string
---@field unified string
---@field ignore_whitespace string
---@field toggle_linematch string

---@class GHReviewIcons
---@field added string
---@field modified string
---@field deleted string
---@field renamed string
---@field approved string
---@field changes_requested string
---@field review_required string
---@field branch string

---@class GHReviewFloat
---@field border string
---@field max_width number
---@field max_height number

---@class GHReviewDiagnostics
---@field severity number vim.diagnostic.severity
---@field virtual_text boolean

---@type GHReviewConfig
M.defaults = {
  gh_cmd = "gh",
  default_view_mode = "inline",
  default_ignore_whitespace = true,
  keymaps = {
    prefix = "<leader>gp",
    checkout = "o",
    files = "f",
    files_focus = "F",
    comments = "c",
    reply = "r",
    new_thread = "n",
    toggle_resolve = "t",
    refresh = "R",
    close = "q",
    hover = "v",
    description = "d",
    toggle_overlay = "D",
    open_minidiff = "e",
    toggle_view = "V",
    review_current = "O",
    commits = "C",
    next_comment = "]c",
    prev_comment = "[c",
    next_diff = "]d",
    prev_diff = "[d",
    next_file = "<leader>gN",
    prev_file = "<leader>gP",
    diffview = "w",
    unified = "u",
    ignore_whitespace = "W",
    toggle_linematch = "L",
  },
  icons = {
    added = "A",
    modified = "M",
    deleted = "D",
    renamed = "R",
    approved = "✓",
    changes_requested = "✗",
    review_required = "◔",
    branch = "⎇",
  },
  float = {
    border = "rounded",
    max_width = 100,
    max_height = 30,
  },
  diagnostics = {
    severity = vim.diagnostic.severity.INFO,
    virtual_text = true,
  },
}

---@type GHReviewConfig
M.values = vim.deepcopy(M.defaults)

--- Deep merge user config with defaults
---@param user_config? table
function M.setup(user_config)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_config or {})
end

--- Get current config
---@return GHReviewConfig
function M.get()
  return M.values
end

return M
