--- Configuration for gh-review.nvim
local M = {}

---@class GHReviewConfig
---@field gh_cmd string Path to gh CLI
---@field default_view_mode "split"|"inline" Initial diff view mode per session
---@field default_ignore_whitespace boolean Hide whitespace-only hunks by default
---@field full_rename_paths boolean Files sidebar: show renames as the full path change (`p` toggles)
---@field open_files_on_load boolean Open the files sidebar when a review loads
---@field open_first_file boolean Open the first file of the diff list after checking out a PR
---@field title_max_length number Crop PR titles in pickers to this many characters (0: no limit)
---@field export_gh_repo boolean Set $GH_REPO in jj workspaces without a git worktree, so other plugins' `gh` calls work
---@field keymaps GHReviewKeymaps
---@field icons GHReviewIcons
---@field float GHReviewFloat
---@field diagnostics GHReviewDiagnostics
---@field picker_keys GHReviewPickerKeys
---@field viewer_review_tags table<string, string> PR picker tag per state of your own latest review ("" hides it)
---@field input_keys GHReviewInputKeys

---@class GHReviewKeymaps
---@field prefix string
---@field checkout string
---@field files string
---@field files_focus string
---@field comments string
---@field comments_focus string
---@field reply string
---@field new_thread string
---@field new_thread_direct string
---@field pending_review string
---@field review_pr string
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
---@field next_stack string
---@field prev_stack string
---@field stack string
---@field pr_list string
---@field gh_stacks string
---@field gh_stack string
---@field diffview string
---@field unified string
---@field ignore_whitespace string
---@field toggle_linematch string
---@field toggle_reviewed string
---@field local_diff string
---@field suggest_change string
---@field suggest_change_direct string

---@class GHReviewInputKeys Keys inside the comment input window
---@field suggestion string Insert a suggestion block of the commented lines
---@field cancel string Close the input without submitting (normal mode)

---@class GHReviewPickerKeys Keys inside the PR, stack list and stack panel pickers
---@field scope_all string
---@field scope_mine string
---@field scope_review string
---@field scope_author string
---@field filter string
---@field clear_filters string
---@field checkout string
---@field merge string
---@field refresh string
---@field details string
---@field first_mine string Review the first (lowest) open PR of yours in the stack
---@field last_mine string Review the last (highest) open PR of yours in the stack

---@class GHReviewIcons
---@field added string
---@field modified string
---@field deleted string
---@field renamed string
---@field approved string
---@field changes_requested string
---@field review_required string
---@field branch string
---@field reviewed string

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
  full_rename_paths = true,
  open_files_on_load = true,
  open_first_file = true,
  title_max_length = 30,
  export_gh_repo = true,
  keymaps = {
    prefix = "<leader>gp",
    checkout = "o",
    files = "f",
    files_focus = "F",
    comments = "c",
    comments_focus = "Y",
    reply = "r",
    new_thread = "n",
    new_thread_direct = "N",
    pending_review = "p",
    review_pr = "a",
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
    next_stack = "s",
    prev_stack = "S",
    stack = "k",
    pr_list = "l",
    gh_stacks = "K",
    gh_stack = "M",
    diffview = "w",
    unified = "u",
    ignore_whitespace = "W",
    toggle_linematch = "L",
    toggle_reviewed = "m",
    local_diff = "J",
    suggest_change = "g",
    suggest_change_direct = "G",
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
    reviewed = "✓",
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
  viewer_review_tags = {
    APPROVED = "[Approved]",
    CHANGES_REQUESTED = "[Request Changes]",
    COMMENTED = "[Reviewed]",
  },
  input_keys = {
    suggestion = "<C-g>",
    cancel = "<leader>wd",
  },
  picker_keys = {
    scope_all = "<a-a>",
    scope_mine = "<a-m>",
    scope_review = "<a-r>",
    scope_author = "<a-u>",
    filter = "<a-s>",
    clear_filters = "<a-x>",
    checkout = "<c-o>",
    merge = "M",
    refresh = "R",
    details = "d",
    first_mine = "<a-f>",
    last_mine = "<a-l>",
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
