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
  local last_child = {} -- tracks last child per parent for `last` flag

  local function walk(node, parent_item)
    if not node.children then return end
    local dirs, leaves = {}, {}
    for _, child in ipairs(node.children) do
      if child.children then
        table.insert(dirs, child)
      else
        table.insert(leaves, child)
      end
    end
    table.sort(dirs, function(a, b) return a.name < b.name end)
    table.sort(leaves, function(a, b) return a.name < b.name end)

    local all = {}
    for _, d in ipairs(dirs) do table.insert(all, d) end
    for _, f in ipairs(leaves) do table.insert(all, f) end

    for idx, child in ipairs(all) do
      if child.children then
        -- Directory item
        local item = {
          text = child.name,
          parent = parent_item,
          last = idx == #all,
          _is_dir = true,
          _name = child.name,
        }
        -- Unset previous last sibling
        if last_child[parent_item] then
          last_child[parent_item].last = false
        end
        last_child[parent_item] = item
        table.insert(items, item)
        walk(child, item)
      else
        -- File item
        local file = child.file
        local icon, hl = status_display(file.status)
        local item = {
          text = file.path,
          file = cwd .. "/" .. file.path,
          parent = parent_item,
          last = idx == #all,
          _file_data = file,
          _is_dir = false,
          _name = child.name,
          _icon = icon,
          _hl = hl,
        }
        if last_child[parent_item] then
          last_child[parent_item].last = false
        end
        last_child[parent_item] = item
        table.insert(items, item)
      end
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
