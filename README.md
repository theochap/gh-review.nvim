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
(a git worktree with jj >= 0.34 in a colocated repo, otherwise no `.git` at all). PRs are found via jj bookmarks since jj keeps
git HEAD detached; see `:help gh-review-jj`.

In a jj workspace with no git worktree, plain `gh` fails with "not a git repository". The plugin then sets `$GH_REPO` for the Neovim session, so other tools that call `gh` work too: snacks.nvim's `gh_pr`/`gh_issue` pickers, terminals, other plugins. It never overrides a `$GH_REPO` you set, and removes its own value when you `:cd` elsewhere. Turn it off with `export_gh_repo = false`.

Checking out a PR under jj skips the fetch when jj already has the PR's head commit (fetched before, or pushed from this machine): the working copy goes straight onto it with `jj new <head>`. This holds in every jj workspace, also one that is a git worktree: `gh pr checkout` is only the fallback there (for example for a PR from a fork). Only a missing commit triggers `jj git fetch -b <branch>`, announced with a "fetching" message. A fetch walks every ref in the store, so in a repo with many refs (jj's `refs/jj/keep/*`) it can take minutes.

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
| `<leader>gpg` | `:[range]GHReview suggest` | Suggest a change to the line or selection (pending review) |
| `<leader>gpG` | `:[range]GHReview suggest-direct` | Suggest a change, posted immediately |
| `<leader>gpp` | `:GHReview pending` | Review unsubmitted comments and submit them all |
| | `:GHReview submit [event]` | Submit pending review (`comment`/`approve`/`request-changes`) |
| `<leader>gpa` | `:GHReview review [event]` | Approve / comment / request changes on the whole PR |
| `<leader>gps` | `:GHReview stack-next` | Next commit in the jj stack, checked out (loads the next PR if needed) |
| `<leader>gpS` | `:GHReview stack-prev` | Previous commit in the jj stack |
| `<leader>gpk` | `:GHReview stack` | Toggle the jj stack picker (trunk..tip); `<cr>` reviews and checks out the commit |
| `<leader>gpJ` | `:GHReview local` | Toggle the local jj diff of the PR (unpushed edits included) |
| `<leader>gpl` | `:GHReview prs [all\|mine\|review\|author <login>] [qualifiers…]` | List PRs in a scope, optionally filtered |
| `<leader>gpK` | `:GHReview stacks [scope]` | List native GitHub PR stacks |
| `<leader>gpM` | `:GHReview gh-stack [number]` | Toggle the GitHub stack panel (merge status, merge, checkout) |
| | `:GHReview cache-clear` | Delete the commit-keyed cache |
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
- Files sidebar: `<cr>` open file, `m` toggle reviewed, `p` toggle full paths of renames (`old/dir/a.lua → new/dir/a.lua` or `a.lua → b.lua`)
- Commits panel: `<cr>` select/deselect commit, `x` clear filter
- Stack picker: `<cr>` move the review to the commit, `x` clear filter
- Description: `q` close, `o` open in browser, `n` new comment, `r` reply,
  `<cr>` select commit (on commit line), `x` clear filter
- Comment input: `<C-s>` submit, `<leader>wd` cancel (normal mode), `<C-g>` insert a suggestion block (new comments)
- PR list: `<cr>` checkout and review, `<c-o>` checkout only, `<a-a>` all,
  `<a-m>` mine, `<a-r>` review, `<a-u>` author, `<a-s>` filters, `<a-x>` clear filters,
  `<a-f>` / `<a-l>` review the first / last PR of mine in the PR's stack
- Stack list: `<cr>` open stack panel, `<c-o>` checkout stack, `<a-f>` / `<a-l>` first / last PR of mine, same scope keys
- Filters: `<Tab>` select, `<cr>` toggle the selected filters, `<a-x>` clear all
- Stack panel: `<cr>` checkout and review PR, `M` merge up to this PR,
  `o` checkout stack, `d` checks of this PR, `R` refresh (skips the cache),
  `<a-f>` / `<a-l>` first / last PR of mine
- Checks window: `<cr>`/`o` open the job in the browser, `R` refresh, `q` close

## Configuration

All options with their defaults:

```lua
require("gh-review").setup({
  gh_cmd = "gh",
  full_rename_paths = true, -- files sidebar: renames show the full path change (`p` toggles)
  open_files_on_load = true, -- open the files sidebar when a review loads
  open_first_file = true, -- open the first file of the diff list when a review loads or moves (o, O, l, k, s, S)
  title_max_length = 30, -- crop PR titles in pickers to this many characters (0: no limit)
  export_gh_repo = true, -- set $GH_REPO in jj workspaces without a git worktree (see below)
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
    pr_list = "l",
    gh_stacks = "K",
    gh_stack = "M",
    local_diff = "J",
    suggest_change = "g",
    suggest_change_direct = "G",
  },
  -- Keys inside the comment input window
  input_keys = {
    suggestion = "<C-g>",
    cancel = "<leader>wd",
  },
  -- Keys inside the PR list, stack list and stack panel pickers
  viewer_review_tags = {
    APPROVED = "[Approved]",
    CHANGES_REQUESTED = "[Request Changes]",
    COMMENTED = "[Reviewed]",
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

### The sidebar follows the current file

When another PR is loaded (a checkout from a picker, a stack step, `<leader>gpR`), an open file sidebar and commits panel are rebuilt for it. The diff split and unified view of the previous PR are closed. A closed sidebar stays closed.

While the file tree is open, it points at whatever PR file you are looking at. It opens on the current buffer and then re-syncs on every buffer switch, so `:e`, `<C-o>`, `:bnext`, a jump into another window and any other picker keep it in step — not just `<cr>` from the sidebar itself. `ghreview://` scratch buffers (base, per-commit, unified) count as their PR file; buffers outside the PR leave the cursor untouched. With a query typed in the picker, the sync lands on the matching row among the filtered results.

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

If the neighbour belongs to the PR already loaded, the session just re-filters to it. If it belongs to another PR, that PR is identified by the nearest jj bookmark at or below the commit, loaded, and then filtered to the commit. Each step also checks the commit out with `jj new <commit>`, unless the working copy is already on it. The files on disk are then the commit's, so the diff views open them editable against the commit's parent; edits land in the working-copy change on top (`jj squash` moves them into the commit). Forked stacks prompt with `vim.ui.select`.

`<leader>gpk` previews the whole stack — every commit from `trunk()` to the tip of the branch you are on, so the PRs below the one under review *and* the ones stacked above it, tip first — in a floating picker (capped at 100 commits from the tip). Entries read like the PR list: the PR number of the commit (from its nearest head bookmark at or above it), the PR's place in the stack (`3/5`, from the native GitHub stack or else the jj stack), then the commit id, the description cropped to `title_max_length`, bookmarks and author; the commit you are on is marked `>`, highlighted across the entry, and is where the picker opens. Press `<cr>` to jump the review to a commit, following the same cross-PR rules. It works before any review is loaded, so you can use it to choose which PR of the stack to open.

Both the picker and the step keymaps anchor on the PR head **branch** as well as the head commit, and steps walk the change (`change_id`) rather than the commit id. The oid GitHub reports is the commit as pushed, so after a local rebase or amend nothing descends from it any more — anchoring on it alone would list the PRs below the review and none above it. For the same reason the `>` marker and the `#<pr>` badges match on change ids too, so they keep pointing at the right commit after a rewrite.

### PR list

`<leader>gpl` lists open PRs in a scope: all, mine, review (your review is requested, you already reviewed it, or it is assigned to you; never your own PRs), or one author. In the picker, `<a-a>`, `<a-m>`, `<a-r>` and `<a-u>` switch the scope (`<a-u>` asks for a login). `<leader>gpl` reopens on the last scope. `<cr>` checks out and reviews the PR. `<c-o>` only checks it out.

Type a PR number (`123` or `#123`) to find a PR by number: only PR numbers match, not digits in titles or bodies. If no PR in the list matches, `<cr>` opens that PR anyway, so PRs older than the newest 50 are one number away. In the stack list, a number finds the stacks that hold that PR.

A stacked PR shows its position in its native GitHub stack after the title: `⧉ 10/12` is the 10th PR of 12, counted from the base. `<a-f>` / `<a-l>` check out and review the first / last open PR you authored in that stack. The same keys work in the stack list (`<leader>gpK`) and the stack panel (`<leader>gpM`).

Filters narrow any scope further, in the PR list and the stack list alike. The picker title shows the keys. `<a-s>` opens the filter manager: active filters come first, marked `✓`, then every other choice. `<cr>` toggles the entry under the cursor. To add and remove several at once, select them with `<Tab>`, then `<cr>`. `<a-x>` clears all filters. The filters:

| Filter | Choices |
|---|---|
| Author | a login |
| Status | ready for review, draft |
| Review decision | review required, approved, changes requested, no review yet |
| My review | not reviewed by me, reviewed by me, my review requested |
| Checks | passing, failing, pending |
| Label / Base branch | a name |
| Search qualifier… | any [GitHub search qualifier](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests) |

Each filter adds a search qualifier, ANDed with the scope: review scope + author `alice` + "review required" lists the PRs waiting for your review that Alice opened and nobody has approved yet. A new value of the same kind replaces the old one. The title lists the active filters, scope keys keep them, and `<leader>gpl` reopens with them. From the command line, add qualifiers after the scope: `:GHReview prs review author:alice draft:false`.

Each PR also shows your own latest review as a tag before its title: `[Approved]`, `[Request Changes]`, or `[Reviewed]` (comments only). Tags arrive with the review badges, a moment after the list opens, and are searchable. Change or hide them with `viewer_review_tags` (`""` hides one).

`<a-m>` and `<a-r>` shadow the snacks.nvim defaults (maximize, regex) in this picker only. Change them with `picker_keys`.

### Native GitHub stacks

GitHub stacks group PRs that build on each other. Merging a PR of a stack also merges every open PR below it, in one atomic operation.

- `<leader>gpK` lists the stacks that hold a PR in a scope. It uses the same scope keys as the PR list. `<cr>` opens the stack panel. `<c-o>` checks out the stack.
- `<leader>gpM` opens the panel over the stack of the PR under review (or of the current branch). Each PR shows `✓ merged`, `● mergeable`, `● ready, waits on PRs below`, or `✗` with its blockers: draft, conflicts, review, checks, or GitHub's merge state.
- `M` in the panel merges up to the PR under the cursor. It asks for the merge method (unless the repo uses a merge queue), confirms, then calls the async merge API and polls the result.
- `o` in the panel checks out the stack. Under jj it fetches every open branch of the stack and runs `jj new <top>@origin`, so `<leader>gps`/`<leader>gpS` work across the PRs. Under git it checks out the topmost open PR.
- `d` in the panel opens the checks of the PR under the cursor: failing jobs first (required ones on top), then pending, passed and skipped. Each line names the workflow and the job. `<cr>` opens the job on GitHub.

Native stacks need github.com. On hosts without them, the stack commands say so.

### Loading speed

The pickers open on cheap metadata and fill in the expensive data afterwards:

- The PR list leaves out review decisions (they cost GitHub more than every other field together). The ✓/✗/◔ badges appear a moment after the list opens.
- The stack list and the stack panel open with `…` on PRs whose merge status is still loading. The status arrives in small parallel batches and the picker redraws in place.
- The checks of a PR load only when you open its checks window.

Data that cannot change while the commits stay the same is cached on disk (`stdpath("cache")/gh-review`), keyed by commit hashes:

- Merge status, keyed by the PR's head and base commits. Only settled states are cached: no pending checks, known mergeability, and no verdict a review can still flip (review required, changes requested, blocked). `R` in the panel skips the cache.
- Checks, keyed by the head commit, once none is pending.
- PR files, diff and commits, keyed by the head and base commits.

When the PR's head and base commits are in your local git or jj store (for example after a stack checkout or a `jj git fetch`), the files, diff and commits come from local `git` instead of GitHub: about 0.1 s instead of 1.3 s. The diff is taken from the merge base of the two commits, the same diff GitHub shows. This works even after you amend locally, because jj keeps the pushed commit. The "loaded" message says when the diff came from `local` or `cache`.

When the commits are not local, the file list from GitHub already carries each file's hunks, so the diff comes with it: no separate diff download. Opening a file reads the base and head versions from your local git objects.

Loading a review (`<leader>gpO`, or any PR load) makes as few GitHub round trips as it can:

- The repository name is looked up once per directory, while the PR is being found, and then remembered.
- The metadata `<leader>gpO` used to find the PR is reused, not fetched again. The PR found for the working copy (by startup detection or the last `<leader>gpO`) is kept for the session: while the working copy stays on the same commit, `<leader>gpO` loads it at once and checks it against GitHub in the background. If the PR's head or base commit moved, the review reloads; if only the title or description changed, those update in place.
- Threads, comments, the PR id and the diff all start at once, in parallel.

On a 15-file PR this takes `<leader>gpO` from 3–5 s to about 1.8 s, or 0.9 s right after startup detection.

`:GHReview cache-clear` deletes the cache. Entries unread for 30 days are deleted at startup.

### Pending vs. immediate comments

`<leader>gpn` creates an inline thread the way GitHub's review flow does: it lands in your *pending* review and stays invisible to everyone until the review is submitted. `<leader>gpp` lists everything still pending (file, line range, body), lets you jump to each with `<cr>`, and publishes the whole batch with `s` (comment), `a` (approve) or `x` (request changes), after prompting for an optional summary.

`<leader>gpN` skips all that and posts the comment immediately as a standalone thread, leaving any pending review untouched.

### Suggesting a change

`<leader>gpg` (normal or visual mode) opens a pending thread whose input starts as a GitHub ```` ```suggestion ```` block of the commented lines. Edit the code in the block and submit with `<C-s>`. GitHub then lets the PR author apply it in one click. `<leader>gpG` does the same but posts the suggestion immediately, outside the pending review. Inside the input of `<leader>gpn` / `<leader>gpN`, `<C-g>` inserts the same block below the cursor. Use it from the new side of the diff (split right side or inline view).

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
