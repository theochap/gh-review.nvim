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

--- Build picker items with parent references for snacks tree rendering.
--- Collapses single-child directory chains (e.g. a/b/c → "a/b/c").
---@param files table[]
---@param cwd string
---@return table[] items
local function build_items(files, cwd)
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

  -- Flatten into items with parent references
  local items = {}

  local function walk(node, parent_item)
    if not node.children then return end
    -- Sort: directories first, then files
    local sorted = {}
    for _, child in ipairs(node.children) do
      table.insert(sorted, child)
    end
    table.sort(sorted, function(a, b)
      local a_dir = a.children and 0 or 1
      local b_dir = b.children and 0 or 1
      if a_dir ~= b_dir then return a_dir < b_dir end
      return a.name < b.name
    end)

    for idx, child in ipairs(sorted) do
      local is_dir = child.children ~= nil
      local file = not is_dir and child.file or nil
      local icon, hl
      if file then icon, hl = status_display(file.status) end

      local item = {
        text = is_dir and child.name or file.path,
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

--- Look up the active files picker, if any.
---@return table? picker
local function get_picker()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for file picker", vim.log.levels.ERROR)
    return nil
  end
  local pickers = Snacks.picker.get({ source = "gh_review_files" })
  return pickers[1]
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

--- Derive the PR-relative path of the current buffer, if any. Handles
--- regular working-tree buffers and all ghreview:// scratch buffer names.
---@param cwd string
---@return string?
local function current_pr_rel_path(cwd)
  local name = vim.api.nvim_buf_get_name(0)
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

--- Show the changed files sidebar
function M.show()
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
    title = title,
    items = items,
    tree = true,
    layout = { preset = "sidebar", preview = false },
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
          local old_name = file.old_path:match("[^/]+$") or file.old_path
          ret[#ret + 1] = { old_name .. " → " .. item._name, item._hl }
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
    },
    win = {
      list = {
        keys = {
          ["m"] = { "gh_review_toggle_reviewed", desc = "Toggle reviewed" },
        },
      },
      input = {
        keys = {
          ["<a-m>"] = { "gh_review_toggle_reviewed", mode = { "n", "i" }, desc = "Toggle reviewed" },
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
