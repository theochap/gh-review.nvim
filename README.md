# gh-review.nvim

[![CI](https://github.com/theochap/gh-review.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/theochap/gh-review.nvim/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/theochap/gh-review.nvim/coverage-badge/coverage.json)](https://github.com/theochap/gh-review.nvim/actions/workflows/ci.yml)

Review GitHub Pull Requests without leaving Neovim.

Checkout a PR, browse changed files, navigate inline comment threads, reply, resolve, and create new threads — all from your editor. Filter your review to a single commit, navigate diff hunks across files, and get notified when your current branch has an open PR.

## Disclaimer

This plugin has been mostly generated using AI, I did that for a few reasons:

- I wanted to figure out how good AI was at writing lua (happens the answer is: pretty good)
- I felt that all the existing gh plugins that were missing features for my PR review workflows but I wasn't annoyed enough to dedicate hours on fixing that issue by myself.
- This is not critical enough to dedicate time handwriting the best implementation. A vibe-coded plugin mostly works for everyday use.

That being said, I spent some time reading, refactoring and adding tests to limit the amount of slop that is generated. Overall I am pretty satisfied with the result.

A few notes:

- It may not work. If you notice a bug, please open an issue AND try to fix it. Unless this is annoying to me too, I won't dedicate time to fix it
- I am not thinking of adding much more to what's already there.

## Requirements

- Neovim >= 0.10
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth login`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) — file/PR pickers

Works in plain git repos and in [jj](https://github.com/jj-vcs/jj) repos of any
layout — colocated, non-colocated, or a secondary `jj workspace add` workspace
(where there is no `.git` at all). PRs are found via jj bookmarks since jj keeps
git HEAD detached; see `:help gh-review-jj`.

**Optional integrations:**
[diffview.nvim](https://github.com/sindrets/diffview.nvim) |
[mini.diff](https://github.com/echasnovski/mini.diff) |
[trouble.nvim](https://github.com/folke/trouble.nvim) |
[which-key.nvim](https://github.com/folke/which-key.nvim) |
[lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)

Run `:checkhealth gh-review` to verify your setup.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "theochap/gh-review.nvim",
  config = function()
    require("gh-review").setup()
  end,
  dependencies = {
    "folke/snacks.nvim",       -- required
    -- "echasnovski/mini.diff", -- optional
    -- "folke/trouble.nvim",    -- optional
    -- "sindrets/diffview.nvim", -- optional
  },
}
```

## Usage

The plugin auto-detects if your current branch has an open PR on startup and
notifies you with a hint to press `<leader>gpO`.

| Keymap | Command | Description |
|---|---|---|
| `<leader>gpo` | `:GHReview checkout [number]` | Checkout PR (fuzzy picker if no number) |
| `<leader>gpO` | `:GHReview current` | Review PR for current branch |
| `<leader>gpf` | `:GHReview files` | Toggle file tree sidebar |
| `<leader>gpC` | | Toggle commits sidebar (filter by commit) |
| `<leader>gpc` | `:GHReview comments` | Toggle comments panel (trouble.nvim) |
| `<leader>gpr` | | Reply to thread at cursor |
| `<leader>gpn` | | New inline comment thread (queued in your pending review) |
| `<leader>gpN` | | New inline comment, posted immediately |
| `<leader>gpp` | `:GHReview pending` | Review unsubmitted comments and submit them all |
| | `:GHReview submit [event]` | Submit pending review (`comment`/`approve`/`request-changes`) |
| `<leader>gpa` | `:GHReview review [event]` | Approve / comment / request changes on the whole PR |
| `<leader>gps` | `:GHReview stack-next` | Next commit in the jj stack (loads the next PR if needed) |
| `<leader>gpS` | `:GHReview stack-prev` | Previous commit in the jj stack |
| `<leader>gpk` | `:GHReview stack` | Toggle the jj stack picker (trunk..tip) |
| `<leader>gpt` | | Toggle resolve/unresolve |
| `<leader>gpv` | `:GHReview hover` | View comment at cursor |
| `<leader>gpd` | `:GHReview description` | PR description page |
| `<leader>gpD` | | Toggle mini.diff overlay |
| `<leader>gpe` | | Open file with diff overlay |
| `<leader>gpR` | `:GHReview refresh` | Refresh PR data |
| `<leader>gpq` | `:GHReview close` | Close review session |
| `]c` / `[c` | | Next/previous comment (cross-file) |
| `]d` / `[d` | | Next/previous diff hunk (cross-file, in sidebar order) |

**Buffer-local keymaps:**

- Comment thread: `r` reply, `t` resolve, `o` browser, `q` close
- Pending review panel: `<cr>` jump to comment, `s` submit as comment, `a` approve,
  `x` request changes, `q` close
- Trouble panel: `r` reply, `t` resolve, `v` view thread, `<cr>` jump to diff
- Commits panel: `<cr>` select/deselect commit, `x` clear filter
- Stack picker: `<cr>` move the review to the commit, `x` clear filter
- Description: `q` close, `o` open in browser, `n` new comment, `r` reply,
  `<cr>` select commit (on commit line), `x` clear filter
- Comment input: `<C-s>` submit, `<Esc><Esc>` cancel

## Configuration

All options with their defaults:

```lua
require("gh-review").setup({
  gh_cmd = "gh",
  keymaps = {
    prefix = "<leader>gp",
    checkout = "o",
    review_current = "O",
    files = "f",
    comments = "c",
    reply = "r",
    new_thread = "n",
    new_thread_direct = "N",
    pending_review = "p",
    review_pr = "a",
    toggle_resolve = "t",
    hover = "v",
    description = "d",
    toggle_overlay = "D",
    open_minidiff = "e",
    refresh = "R",
    close = "q",
    next_comment = "]c",
    prev_comment = "[c",
    commits = "C",
    next_diff = "]d",
    prev_diff = "[d",
    next_stack = "s",
    prev_stack = "S",
    stack = "k",
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
})
```

## Integrations

### Diff review

Comment navigation and the files picker open a native Neovim diff split: working file on the right (modifiable) and base version on the left (readonly). Comment threads are rendered as virtual lines (extmarks) below their lines. When filtering by commit, both sides are readonly showing the commit's parent vs commit version.

### Commit filtering

`<leader>gpC` opens the commits sidebar. Select a commit to filter the entire session — files, comments, diagnostics, and diffs all narrow to that commit's changes. Select again or press `x` to return to the full PR view. Commits are also selectable from the description page.

Everything is scoped against the commit's first parent (`<oid>~1`): the file tree, the split, the inline overlay and the unified buffer (`<leader>gpu`). Merge commits are shown against their first parent and root commits against the empty tree, so selecting either lists its files like any other commit.

While a filter is in place, both this picker and the stack picker open with the cursor on the selected commit and highlight the whole entry, so it is obvious which commit the session is scoped to. The highlights come from two `default`-linked groups you can override:

```lua
vim.api.nvim_set_hl(0, "GHReviewPickerActive", { link = "IncSearch" })      -- the `>` marker (default: CurSearch)
vim.api.nvim_set_hl(0, "GHReviewPickerActiveEntry", { link = "PmenuSel" }) -- the rest of the entry (default: Visual)
```

### Stacked PRs (jj)

`<leader>gps` moves the review to the direct descendant of the commit you are on, `<leader>gpS` to its ancestor. The starting point is the commit the review is filtered to, or the PR head when it isn't — so from an unfiltered review, `<leader>gps` walks into the next PR of the stack.

If the neighbour belongs to the PR already loaded, the session just re-filters to it. If it belongs to another PR, that PR is identified by the nearest jj bookmark at or below the commit, loaded, and then filtered to the commit. The working copy never moves, so nothing is checked out. Forked stacks prompt with `vim.ui.select`.

`<leader>gpk` previews the whole stack — every commit from `trunk()` to the tip of the branch you are on, so the PRs below the one under review *and* the ones stacked above it, tip first — in a floating picker (capped at 100 commits from the tip). Entries show the commit id, description, bookmarks, `#<pr>` when the commit is part of the PR under review, and the author; the commit you are on is marked `>`, highlighted across the entry, and is where the picker opens. Press `<cr>` to jump the review to a commit, following the same cross-PR rules. It works before any review is loaded, so you can use it to choose which PR of the stack to open.

Both the picker and the step keymaps anchor on the PR head **branch** as well as the head commit, and steps walk the change (`change_id`) rather than the commit id. The oid GitHub reports is the commit as pushed, so after a local rebase or amend nothing descends from it any more — anchoring on it alone would list the PRs below the review and none above it. For the same reason the `>` marker and the `#<pr>` badges match on change ids too, so they keep pointing at the right commit after a rewrite.

### Pending vs. immediate comments

`<leader>gpn` creates an inline thread the way GitHub's review flow does: it lands in your *pending* review and stays invisible to everyone until the review is submitted. `<leader>gpp` lists everything still pending (file, line range, body), lets you jump to each with `<cr>`, and publishes the whole batch with `s` (comment), `a` (approve) or `x` (request changes), after prompting for an optional summary.

`<leader>gpN` skips all that and posts the comment immediately as a standalone thread, leaving any pending review untouched.

### Approving the whole PR

`<leader>gpa` gives the PR a verdict, whether or not you wrote any inline comments: it asks approve / comment / request changes, then opens an input for the review body (optional for an approval — GitHub rejects a bodyless comment or request for changes). `:GHReview review approve` skips the prompt.

Pending comments, if you have any, are published together with the verdict and the input title says how many. GitHub only lets you have one review open at a time, so leaving them queued isn't possible.

### mini.diff

When installed, opening any PR file automatically sets the base version as reference text for gutter signs. `<leader>gpD` toggles an inline overlay. When filtering by commit, gutter signs reflect changes from that single commit.

### Trouble.nvim

`<leader>gpc` toggles a bottom panel listing all comment threads as diagnostics-style items. Buffer-local keymaps: `r` reply, `t` toggle resolve, `v` view thread, `<cr>` jump to diff location.

### Lualine

```lua
require("lualine").setup({
  sections = {
    lualine_b = {
      require("gh-review.integrations.lualine").spec(),
    },
  },
})
```

Shows PR number, head ref, and review status. When filtering by commit, appends the active commit SHA and message.

### Which-key

The `<leader>gp` group is automatically registered when which-key is installed.

## Tests

```sh
nvim -l tests/minit.lua --busted tests/
```

## License

MIT
