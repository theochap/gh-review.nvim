--- Native diff split for PR file review
local M = {}

local state = require("gh-review.state")

---@class GHDiffReviewState
---@field file_path? string
---@field base_buf? number
---@field base_win? number
---@field work_buf? number
---@field work_win? number
local current = { file_path = nil, base_buf = nil, base_win = nil, work_buf = nil, work_win = nil }

--- Check if a window is valid
---@param win? number
---@return boolean
local function win_valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Check if a buffer is valid
---@param buf? number
---@return boolean
local function buf_valid(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Open native diff split for a file
---@param file_path string Relative file path
---@param target_line? number Line to position cursor at
function M.open(file_path, target_line)
	-- If same file already open and windows valid, just reposition
	if current.file_path == file_path and win_valid(current.base_win) and win_valid(current.work_win) then
		vim.api.nvim_set_current_win(current.work_win)
		if target_line then
			local line_count = vim.api.nvim_buf_line_count(current.work_buf)
			local target = math.min(target_line, line_count)
			vim.api.nvim_win_set_cursor(current.work_win, { target, 0 })
			vim.cmd("normal! zz")
		end
		return
	end

	-- Close any existing diff review
	M.close()

	local pr = state.get_pr()
	if not pr then
		return
	end

	local cwd = vim.fn.getcwd()
	local base_ref = pr.base_ref

	-- Get base content from git
	local result = vim.system({ "git", "show", base_ref .. ":" .. file_path }, { text = true, cwd = cwd }):wait()
	local base_lines = {}
	if result.code == 0 and result.stdout then
		base_lines = vim.split(result.stdout, "\n")
		-- git output ends with \n, producing a trailing empty element
		if #base_lines > 0 and base_lines[#base_lines] == "" then
			table.remove(base_lines)
		end
	end

	-- Open the working file on the right
	vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. file_path))
	current.work_buf = vim.api.nvim_get_current_buf()
	current.work_win = vim.api.nvim_get_current_win()

	-- Create base buffer on the left
	vim.cmd("leftabove vsplit")
	local base_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, base_buf)
	vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_lines)
	vim.api.nvim_buf_set_name(base_buf, "ghreview://base/" .. file_path)
	vim.bo[base_buf].buftype = "nofile"
	vim.bo[base_buf].modifiable = false
	vim.bo[base_buf].bufhidden = "wipe"

	-- Try to set filetype based on extension for syntax highlighting
	local ft = vim.filetype.match({ filename = file_path })
	if ft then
		vim.bo[base_buf].filetype = ft
	end

	current.base_buf = base_buf
	current.base_win = vim.api.nvim_get_current_win()

	-- Enable diff mode on both windows, disable folding
	vim.api.nvim_win_call(current.base_win, function()
		vim.cmd("diffthis")
		vim.wo[0].foldenable = false
	end)
	vim.api.nvim_win_call(current.work_win, function()
		vim.cmd("diffthis")
		vim.wo[0].foldenable = false
	end)

	-- Move cursor to right window at target line
	vim.api.nvim_set_current_win(current.work_win)
	if target_line then
		local line_count = vim.api.nvim_buf_line_count(current.work_buf)
		local target = math.min(target_line, line_count)
		vim.api.nvim_win_set_cursor(current.work_win, { target, 0 })
		vim.cmd("normal! zz")
	end

	current.file_path = file_path
end

--- Close the diff review split
function M.close()
	-- Close base window
	if win_valid(current.base_win) then
		vim.api.nvim_win_close(current.base_win, true)
	end

	-- Delete base buffer
	if buf_valid(current.base_buf) then
		vim.api.nvim_buf_delete(current.base_buf, { force = true })
	end

	-- Turn off diff mode on work window
	if win_valid(current.work_win) and buf_valid(current.work_buf) then
		vim.api.nvim_win_call(current.work_win, function()
			vim.cmd("diffoff")
		end)
	end

	current.file_path = nil
	current.base_buf = nil
	current.base_win = nil
	current.work_buf = nil
	current.work_win = nil
end

--- Get the file path if we're in a diff review window
---@return string?
function M.get_file_path()
	if not current.file_path then
		return nil
	end

	local cur_win = vim.api.nvim_get_current_win()
	if cur_win == current.base_win or cur_win == current.work_win then
		return current.file_path
	end

	return nil
end

return M
