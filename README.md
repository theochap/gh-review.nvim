# gh-review.nvim

Review GitHub Pull Requests without leaving Neovim.

Checkout a PR, browse changed files, navigate inline comment threads, reply, resolve, and create new threads — all from your editor.

## Requirements

- Neovim >= 0.10
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth login`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) — file/PR pickers

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
    "sindrets/diffview.nvim",  -- optional
  },
}
```

## Usage

| Keymap | Command | Description |
|---|---|---|
| `<leader>gpo` | `:GHReview checkout [number]` | Checkout PR (fuzzy picker if no number) |
| `<leader>gpO` | `:GHReview current` | Review PR for current branch |
| `<leader>gpf` | `:GHReview files` | Toggle file tree sidebar |
| `<leader>gpc` | `:GHReview comments` | Toggle comments panel |
| `<leader>gpr` | | Reply to thread at cursor |
| `<leader>gpn` | | New inline comment thread |
| `<leader>gpt` | | Toggle resolve/unresolve |
| `<leader>gpv` | `:GHReview hover` | View comment at cursor |
| `<leader>gpd` | `:GHReview description` | PR description page |
| `<leader>gpD` | | Toggle mini.diff overlay |
| `<leader>gpe` | | Open file with diff overlay |
| `<leader>gpR` | `:GHReview refresh` | Refresh PR data |
| `<leader>gpq` | `:GHReview close` | Close review session |
| `]c` / `[c` | | Next/previous comment |

**Buffer-local keymaps:**
- Comment thread: `r` reply, `t` resolve, `o` browser, `q` close
- Trouble panel: `r` reply, `t` resolve, `<cr>` jump to diff
- Description: `q` close, `o` open PR URL
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
    toggle_resolve = "t",
    hover = "v",
    description = "d",
    toggle_overlay = "D",
    open_minidiff = "e",
    refresh = "R",
    close = "q",
    next_comment = "]c",
    prev_comment = "[c",
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

Comment navigation and the files picker open a native Neovim diff split: working file on the right (modifiable) and base version on the left (readonly). Comment threads are rendered as virtual lines (extmarks) below their lines.

### mini.diff

When installed, opening any PR file automatically sets the base version as reference text for gutter signs. `<leader>gpD` toggles an inline overlay.

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

### Which-key

The `<leader>gp` group is automatically registered when which-key is installed.

## Tests

```sh
nvim -l tests/minit.lua --busted tests/
```

## License

MIT
