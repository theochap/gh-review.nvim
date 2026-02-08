# gh-review.nvim

Neovim plugin for reviewing GitHub PRs. Written in Lua, uses the `gh` CLI and GitHub GraphQL API.

## Project structure

```
lua/gh-review/
  init.lua          -- Public API: setup, keymaps, all user-facing functions
  config.lua        -- Configuration defaults and merging
  state.lua         -- Central state store (PR metadata, files, threads, diff)
  gh.lua            -- Async gh CLI wrapper (vim.system)
  graphql.lua       -- GraphQL queries (threads, replies, resolve)
  diff.lua          -- Unified diff parser and thread line mapping
  health.lua        -- :checkhealth gh-review
  ui/
    comments.lua    -- Floating comment thread popup
    comment_input.lua -- Floating input window for replies/new threads
    description.lua -- PR description page
    diagnostics.lua -- vim.diagnostic integration for comment threads
    diff_review.lua -- Native Neovim diff split (base vs working)
    files.lua       -- File tree sidebar (snacks.nvim picker)
    minidiff.lua    -- mini.diff integration (gutter signs + overlay)
    pr_picker.lua   -- PR selection picker (snacks.nvim)
  integrations/
    diffview.lua    -- diffview.nvim integration
    lualine.lua     -- Statusline component
    which_key.lua   -- which-key.nvim group registration
plugin/
  gh-review.lua     -- :GHReview command definition
doc/
  gh-review.txt     -- Vim help documentation
tests/
  minit.lua         -- Test bootstrap (lazy.minit + busted)
  *_spec.lua        -- Test files
```

## Key patterns

- **Async-first**: All `gh` CLI calls go through `gh.lua:M.run()` which uses `vim.system` with callbacks. Results are dispatched via `vim.schedule`.
- **Central state**: `state.lua` holds all PR data. `state.is_active()` gates most operations.
- **Parallel loading**: `_load_pr_data()` in `init.lua` fires 4 async operations in parallel (metadata chain, files, diff, comments) and uses a countdown latch (`pending`) to join.
- **GraphQL for threads**: Review threads (inline comments) use the GraphQL API because the REST API doesn't expose them properly. Simple operations (PR view, diff, files) use `gh pr` commands.

## Running tests

```sh
nvim -l tests/minit.lua --busted tests/
```

Uses [busted](https://github.com/lunarmodules/busted) via lazy.minit. Tests stub external dependencies (mini.diff, vim.system, gh module functions) at the `package.loaded` level. Test data lives in `.tests/` (gitignored).

## Adding a new feature

1. If it needs a new `gh` or GraphQL call, add it to `gh.lua` or `graphql.lua`.
2. Public functions go in `init.lua`. Gate with `state.is_active()` where appropriate.
3. Add keymap to `config.lua` (type annotation + defaults), wire in `init.lua:_setup_keymaps()`.
4. Add `:GHReview` subcommand in `plugin/gh-review.lua` (handler, completion list, usage string).
5. Add which-key entry in `integrations/which_key.lua`.
6. Document in `doc/gh-review.txt` (commands section, keybindings section, config block).
7. Add tests in `tests/` following existing `*_spec.lua` patterns.

## Conventions

- Notification prefix: `"GHReview: "` with appropriate `vim.log.levels`.
- Keymaps: single lowercase letter for common actions, uppercase for variants (e.g., `o` checkout, `O` review current).
- All keymaps use the configurable prefix (default `<leader>gp`).
- Config fields use `snake_case`. Keymap suffixes are single characters.
- Tests use busted `describe/it` BDD style. Stub external plugins before requiring the module under test.
