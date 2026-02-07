--- Changed files sidebar using snacks.nvim picker (hierarchical tree)
local M = {}

local state = require("gh-review.state")
local config = require("gh-review.config")

--- Get the display icon/letter for a file status
---@param status string
---@return string icon, string hl_group
local function status_display(status)
  local icons = config.get().icons
  local map = {
    added = { icons.added, "DiffAdd" },
    modified = { icons.modified, "DiffChange" },
    deleted = { icons.deleted, "DiffDelete" },
    renamed = { icons.renamed, "DiffText" },
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

--- Toggle the file tree sidebar (open / focus / close cycle)
function M.toggle()
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for file picker", vim.log.levels.ERROR)
    return
  end

  local pickers = Snacks.picker.get({ source = "gh_review_files" })
  if #pickers > 0 then
    local picker = pickers[1]
    local cur_win = vim.api.nvim_get_current_win()
    local list_win = picker.list and picker.list.win
    local win_id = type(list_win) == "table" and list_win.win or list_win
    if win_id == cur_win then
      picker:close()
    else
      picker:focus()
    end
    return
  end
  M.show()
end

--- Show the changed files sidebar
function M.show()
  local files = state.get_files()
  if #files == 0 then
    vim.notify("No changed files", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("GHReview: snacks.nvim required for file picker", vim.log.levels.ERROR)
    return
  end

  local fmt = require("snacks.picker.format")
  local cwd = vim.fn.getcwd()
  local items = build_items(files, cwd)

  Snacks.picker.pick({
    source = "gh_review_files",
    title = "PR Changed Files",
    items = items,
    tree = true,
    layout = { preset = "sidebar", preview = false },
    auto_close = false,
    jump = { close = false },
    format = function(item, picker)
      local ret = fmt.tree(item, picker)
      if item._is_dir then
        ret[#ret + 1] = { item._name .. "/", "Directory" }
      else
        local file = item._file_data
        ret[#ret + 1] = { item._icon .. " ", item._hl }
        ret[#ret + 1] = { item._name }
        ret[#ret + 1] = { "  +" .. (file.additions or 0), "DiffAdd", virtual = true }
        ret[#ret + 1] = { " -" .. (file.deletions or 0), "DiffDelete", virtual = true }
      end
      return ret
    end,
    confirm = function(picker, item)
      if not item or item._is_dir then return end
      local file = item._file_data
      if file then
        vim.cmd("wincmd l")
        require("gh-review.ui.diff_review").open(file.path)
      end
    end,
  })
end

return M
