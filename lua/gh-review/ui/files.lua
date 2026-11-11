--- Changed files sidebar using snacks.nvim picker (hierarchical tree)
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Set up foreground-only highlight groups for file status
local function setup_highlights()
  local links = {
    GHReviewFileAdded = "Added",
    GHReviewFileModified = "Changed",
    GHReviewFileDeleted = "Removed",
    GHReviewFileRenamed = "Special",
  }
  for name, fallback in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = fallback, default = true })
  end
end

--- Get the display icon/letter for a file status
---@param status string
---@return string icon, string hl_group
local function status_display(status)
  local icons = config.get().icons
  local map = {
    added = { icons.added, "GHReviewFileAdded" },
    modified = { icons.modified, "GHReviewFileModified" },
    deleted = { icons.deleted, "GHReviewFileDeleted" },
    renamed = { icons.renamed, "GHReviewFileRenamed" },
  }
  local entry = map[status] or { "?", "Normal" }
  return entry[1], entry[2]
end

--- Whether renames show full paths; nil until the sidebar first asks, then
--- it follows `config.full_rename_paths` and the toggle key.
---@type boolean?
M._full_rename_paths = nil

---@return boolean
local function full_rename_paths()
  if M._full_rename_paths == nil then M._full_rename_paths = config.get().full_rename_paths ~= false end
  return M._full_rename_paths
end

--- Text of a renamed file in the sidebar: the full path change
--- ("lua/old/a.lua → lua/new/a.lua"), or file names only ("a.lua → b.lua").
---@param file GHReviewFile
---@param full boolean
---@return string
function M.rename_label(file, full)
  if full then return file.old_path .. " → " .. file.path end
  local old_name = file.old_path:match("[^/]+$") or file.old_path
  local new_name = file.path:match("[^/]+$") or file.path
  return old_name .. " → " .. new_name
end

--- Build the directory tree for a PR file list, collapsing single-child
--- directory chains (e.g. a/b/c → "a/b/c"). Directory nodes have `children`,
--- file nodes have `file`.
---@param files table[]
---@return table root
local function build_tree(files)
  -- First pass: build raw tree
  local root = { children = {} }
  for _, file in ipairs(files) do
    local parts = {}
    for part in file.path:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    local node = root
    for i, part in ipairs(parts) do
      if i == #parts then
        table.insert(node.children, { name = part, file = file })
      else
        local found
        for _, child in ipairs(node.children) do
          if child.name == part and child.children then
            found = child
            break
          end
        end
        if not found then
          found = { name = part, children = {} }
          table.insert(node.children, found)
        end
        node = found
      end
    end
  end

  -- Collapse single-child directory chains
  local function collapse(node)
    if not node.children then return end
    for _, child in ipairs(node.children) do
      if child.children then
        while #child.children == 1 and child.children[1].children do
          local gc = child.children[1]
          child.name = child.name .. "/" .. gc.name
          child.children = gc.children
        end
        collapse(child)
      end
    end
  end
  collapse(root)

  return root
end

--- Children of a tree node in display order: directories first, then files,
--- each group sorted by name.
---@param node table
---@return table[] children
local function sorted_children(node)
  local sorted = {}
  for _, child in ipairs(node.children or {}) do
    table.insert(sorted, child)
  end
  table.sort(sorted, function(a, b)
    local a_dir = a.children and 0 or 1
    local b_dir = b.children and 0 or 1
    if a_dir ~= b_dir then return a_dir < b_dir end
    return a.name < b.name
  end)
  return sorted
end

--- Flatten a PR file list into the top-to-bottom order the sidebar renders
--- it in. Cross-file motions (`]d`/`[d`, `]f`/`[f`) walk this order so they
--- visit files in the same sequence the user sees in the picker rather than
--- the order the API happened to return them in.
---@param files table[]
---@return table[] files in display order
function M.display_order(files)
  local ordered = {}
  local function walk(node)
    for _, child in ipairs(sorted_children(node)) do
      if child.children then
        walk(child)
      else
        table.insert(ordered, child.file)
      end
    end
  end
  walk(build_tree(files))
  return ordered
end

--- Build picker items with parent references for snacks tree rendering.
---@param files table[]
---@param cwd string
---@return table[] items
local function build_items(files, cwd)
  local root = build_tree(files)

  -- Flatten into items with parent references
  local items = {}

  local function walk(node, parent_item)
    if not node.children then return end
    local sorted = sorted_children(node)

    for idx, child in ipairs(sorted) do
      local is_dir = child.children ~= nil
      local file = not is_dir and child.file or nil
      local icon, hl
      if file then icon, hl = status_display(file.status) end

      local item = {
        -- A rename is also found by its old path.
        text = is_dir and child.name or (file.path .. (file.old_path and (" " .. file.old_path) or "")),
        file = not is_dir and (cwd .. "/" .. file.path) or nil,
        parent = parent_item,
        last = idx == #sorted,
        _is_dir = is_dir,
        _name = child.name,
        _file_data = file,
        _icon = icon,
        _hl = hl,
      }
      items[#items + 1] = item
      if is_dir then walk(child, item) end
    end
  end

  walk(root, nil)
  return items
end

--- Derive the PR-relative path of a buffer, if it has one. Handles regular
--- working-tree buffers and all ghreview:// scratch buffer names.
---@param cwd string
---@param bufnr? number defaults to the current buffer
---@return string?
local function current_pr_rel_path(cwd, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then return nil end
  local review = name:match("^ghreview://base/(.+)$")
    or name:match("^ghreview://commit/[^/]+/(.+)$")
    or name:match("^ghreview://unified/(.+)$")
  if review then return review end
  if name:sub(1, #cwd) == cwd then
    return name:sub(#cwd + 2)
  end
  return nil
end

--- Look up the active files picker, if any.
--- Silent: every caller that needs to complain about a missing snacks.nvim goes
--- on to call `M.show`, which reports it, and `M.sync_current` runs on every
--- buffer switch — it must not notify at all.
---@return table? picker
local function get_picker()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then return nil end
  local pickers = Snacks.picker.get({ source = "gh_review_files" })
  return pickers[1]
end

--- Move the picker cursor to the item matching a given PR-relative file path.
--- No-op if the picker is not open or the path is not found.
---@param rel_path string PR-relative file path
function M.sync_selection(rel_path)
  local picker = get_picker()
  if not picker then return end
  local target = vim.fn.getcwd() .. "/" .. rel_path
  -- Walk the picker's own index space rather than `list.items`: the index
  -- `list:move` expects is the one `list:get(i)` resolves, and that reads the
  -- matcher's top-k results before the raw item table. Once a query is typed
  -- the two disagree, and we would scroll to the wrong row or to none at all.
  for item, idx in picker:iter() do
    if item.file == target then
      pcall(function()
        picker.list:move(idx, true)
      end)
      return
    end
  end
end

--- Sync the sidebar to the file a buffer is showing.
--- Used by the buffer-switch hook so the sidebar follows every way of changing
--- file — `:e`, `<C-o>`, `:bnext`, another picker, a window jump — and not just
--- the plugin's own navigation, which goes through `_open_file`.
---@param bufnr? number defaults to the current buffer
function M.sync_current(bufnr)
  -- Cheap bail-out before touching the picker at all: most buffer switches in a
  -- session are to something that isn't a PR file.
  local rel_path = current_pr_rel_path(vim.fn.getcwd(), bufnr)
  if rel_path then M.sync_selection(rel_path) end
end

--- Whether the file tree sidebar is open.
---@return boolean
function M.is_open()
  return get_picker() ~= nil
end

--- Toggle the file tree sidebar strictly open/close — no intermediate focus step.
--- Close always wins when the picker is open, regardless of which window is current.
function M.open_or_close()
  local picker = get_picker()
  if picker then
    picker:close()
    return
  end
  M.show()
end

--- Focus the file tree sidebar, opening it if it isn't already.
--- Complement to `open_or_close` so focus and close are separate actions.
function M.focus()
  local picker = get_picker()
  if picker then
    picker:focus()
    return
  end
  M.show()
end

--- Show the changed files sidebar. `opts.focus = false` opens it without
--- moving the cursor into it (a reload while you look at a file).
---@param opts? { focus?: false }
function M.show(opts)
  -- Already open (a load opened it before a deferred reopen): keep that one.
  if get_picker() then return end
  local files = state.get_effective_files()
  if #files == 0 then
    vim.notify("No changed files", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for file picker", vim.log.levels.ERROR)
    return
  end

  setup_highlights()

  local fmt = require("snacks.picker.format")
  local cwd = vim.fn.getcwd()
  local items = build_items(files, cwd)

  local title = "PR Changed Files"
  local active_commit = state.get_active_commit()
  if active_commit then
    title = title .. " (" .. active_commit.sha .. ")"
  end

  -- Locate the item matching the current buffer so the picker opens with
  -- the cursor already on it. Fall back to whatever snacks picks otherwise.
  local current_rel = current_pr_rel_path(cwd)
  local initial_idx
  if current_rel then
    local target = cwd .. "/" .. current_rel
    for i, item in ipairs(items) do
      if item.file == target then
        initial_idx = i
        break
      end
    end
  end

  Snacks.picker.pick({
    source = "gh_review_files",
    focus = opts and opts.focus,
    title = title,
    items = items,
    tree = true,
    layout = { preset = "sidebar", preview = false, layout = { position = "right" } },
    auto_close = false,
    jump = { close = false },
    on_show = initial_idx and function(picker)
      pcall(function() picker.list:move(initial_idx, true) end)
    end or nil,
    format = function(item, picker)
      local ret = fmt.tree(item, picker)
      if item._is_dir then
        ret[#ret + 1] = { item._name .. "/", "Directory" }
      else
        local file = item._file_data
        ret[#ret + 1] = { item._icon .. " ", item._hl }
        if state.is_reviewed(file.path) then
          local icon = config.get().icons.reviewed or "✓"
          ret[#ret + 1] = { icon .. " ", "DiagnosticOk" }
        end
        if file.status == "renamed" and file.old_path then
          ret[#ret + 1] = { M.rename_label(file, full_rename_paths()), item._hl }
        else
          ret[#ret + 1] = { item._name }
        end
        ret[#ret + 1] = { "  +" .. (file.additions or 0), "GHReviewFileAdded", virtual = true }
        ret[#ret + 1] = { " -" .. (file.deletions or 0), "GHReviewFileDeleted", virtual = true }
      end
      return ret
    end,
    actions = {
      -- Toggle reviewed mark on the currently-selected file without leaving
      -- the picker. Re-render in place so the ✓ appears immediately and
      -- the cursor stays on the same file (picker:find resets to the top,
      -- list:update({force=true}) + set_target preserves position).
      gh_review_toggle_reviewed = function(picker)
        local item = picker:current()
        if not item or item._is_dir then return end
        local file = item._file_data
        if not file then return end
        state.toggle_reviewed(file.path)
        pcall(function()
          picker.list:set_target(picker.list.cursor, picker.list.top, { force = true })
          picker.list:update({ force = true })
        end)
      end,
      -- Switch renames between the full path change and file names only.
      gh_review_toggle_rename_paths = function(picker)
        M._full_rename_paths = not full_rename_paths()
        pcall(function()
          picker.list:set_target(picker.list.cursor, picker.list.top, { force = true })
          picker.list:update({ force = true })
        end)
      end,
    },
    win = {
      list = {
        keys = {
          ["m"] = { "gh_review_toggle_reviewed", desc = "Toggle reviewed" },
          ["p"] = { "gh_review_toggle_rename_paths", desc = "Toggle full paths of renames" },
        },
      },
      input = {
        keys = {
          ["<a-m>"] = { "gh_review_toggle_reviewed", mode = { "n", "i" }, desc = "Toggle reviewed" },
          ["<a-p>"] = { "gh_review_toggle_rename_paths", mode = { "n", "i" }, desc = "Toggle full paths of renames" },
        },
      },
    },
    confirm = function(picker, item)
      if not item or item._is_dir then return end
      local file = item._file_data
      if file then
        vim.cmd("wincmd l")
        require("gh-review")._open_file(file.path)
      end
    end,
  })
end

M._build_items = build_items
M._status_display = status_display

return M
