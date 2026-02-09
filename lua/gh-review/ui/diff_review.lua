--- Native diff split for PR file review
local M = {}

local state = require("gh-review.state")
local util = require("gh-review.util")

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

--- Enable diff mode on both windows, disable folding, position cursor
---@param target_line? number
local function setup_diff_windows(target_line)
	vim.api.nvim_win_call(current.base_win, function()
		vim.cmd("diffthis")
		vim.wo[0].foldenable = false
	end)
	vim.api.nvim_win_call(current.work_win, function()
		vim.cmd("diffthis")
		vim.wo[0].foldenable = false
	end)

	vim.api.nvim_set_current_win(current.work_win)
	if target_line then
		local line_count = vim.api.nvim_buf_line_count(current.work_buf)
		local target = math.min(target_line, line_count)
		vim.api.nvim_win_set_cursor(current.work_win, { target, 0 })
		vim.cmd("normal! zz")
	end
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
	local active_commit = state.get_active_commit()

	if active_commit then
		local oid = active_commit.oid
		local short_sha = oid:sub(1, 8)

		-- Right side: commit version of the file
		local right_lines = util.git_show_lines(oid .. ":" .. file_path, cwd)
		local work_buf = util.create_scratch_buf("ghreview://commit/" .. short_sha .. "/" .. file_path, right_lines, file_path)
		vim.api.nvim_win_set_buf(0, work_buf)
		current.work_buf = work_buf
		current.work_win = vim.api.nvim_get_current_win()

		-- Left side: parent commit version of the file
		local left_lines = util.git_show_lines(oid .. "~1:" .. file_path, cwd)
		vim.cmd("leftabove vsplit")
		local base_buf = util.create_scratch_buf("ghreview://base/" .. file_path, left_lines, file_path)
		vim.api.nvim_win_set_buf(0, base_buf)
		current.base_buf = base_buf
		current.base_win = vim.api.nvim_get_current_win()
	else
		local base_ref = pr.base_ref

		-- Get base content from git
		local base_lines = util.git_show_lines(base_ref .. ":" .. file_path, cwd)

		-- Open the working file on the right
		vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. file_path))
		current.work_buf = vim.api.nvim_get_current_buf()
		current.work_win = vim.api.nvim_get_current_win()

		-- Create base buffer on the left
		vim.cmd("leftabove vsplit")
		local base_buf = util.create_scratch_buf("ghreview://base/" .. file_path, base_lines, file_path)
		vim.api.nvim_win_set_buf(0, base_buf)
		current.base_buf = base_buf
		current.base_win = vim.api.nvim_get_current_win()
	end

	setup_diff_windows(target_line)
	current.file_path = file_path

	-- Set diagnostics on commit diff buffers (BufEnter fires before the name is set)
	if active_commit and current.work_buf then
		require("gh-review.ui.diagnostics").refresh_buf(current.work_buf)
	end
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

--- Check if a diff review is active with valid windows
---@return boolean
function M.is_diff_active()
	return current.file_path ~= nil and win_valid(current.base_win) and win_valid(current.work_win)
end

--- Get the work (right-side) window handle
---@return number?
function M.get_work_win()
	if win_valid(current.work_win) then
		return current.work_win
	end
	return nil
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
