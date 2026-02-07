--- Changed files picker using snacks.nvim
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

--- Show the changed files picker
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

  local pr = state.get_pr()
  local cwd = vim.fn.getcwd()

  local items = {}
  for _, file in ipairs(files) do
    local icon, hl = status_display(file.status)
    local display = file.path
    if file.old_path then
      display = file.old_path .. " -> " .. file.path
    end
    table.insert(items, {
      text = display,
      file = cwd .. "/" .. file.path,
      _file_data = file,
      _icon = icon,
      _hl = hl,
    })
  end

  Snacks.picker.pick({
    title = "PR Changed Files",
    items = items,
    format = function(item, picker)
      local file = item._file_data
      local stats = string.format("+%d -%d", file.additions or 0, file.deletions or 0)
      return {
        { item._icon .. " ", item._hl },
        { item.text },
        { "  " .. stats, "Comment", virtual = true },
      }
    end,
    preview = "file",
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      local file = item._file_data
      if file and pr then
        local dv_ok = pcall(require, "diffview")
        if dv_ok then
          vim.cmd("DiffviewOpen " .. pr.base_ref .. "...HEAD -- " .. file.path)
        else
          vim.cmd("edit " .. vim.fn.fnameescape(file.path))
        end
      end
    end,
  })
end

return M
